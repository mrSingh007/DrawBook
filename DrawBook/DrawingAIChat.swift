import SwiftUI
import PencilKit

@MainActor
final class DrawingAIChat: ObservableObject {
    struct Bubble: Equatable {
        let text: String
        let fromUser: Bool
    }

    @Published var draft = ""
    @Published var errorMessage: String?
    @Published private(set) var bubbles: [Bubble] = []
    @Published private(set) var pendingPrompt: String?
    @Published private(set) var activity: [String] = []
    /// Completed turns, compacted.
    private var history: [[AIChatMessage]] = []
    private var keys = AIPageKeys()
    private var request: Task<Void, Never>?

    var canSend: Bool {
        pendingPrompt == nil && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    enum ApplyResult { case applied, saveFailed, pageChanged }

    /// Runs one agent turn against a working copy of the page. `apply` commits the final
    /// page as a single undoable edit and reports whether it was saved.
    func send(provider: AIProvider, apiKey: String, model: String, page: AIPageContent,
              info: AIPageState.PageInfo, imageInput: Bool, selectedObjectID: UUID?,
              apply: @escaping (AIPageContent) -> ApplyResult) {
        guard canSend, !apiKey.isEmpty else { return }
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        errorMessage = nil
        pendingPrompt = prompt
        activity = []
        // Key changes stay provisional until the canvas accepts the edit.
        let keys = keys.copy()
        let history = history.flatMap { $0 }
        request = Task {
            do {
                var handwriting: [HandwritingLine] = []
                if !page.drawing.strokes.isEmpty {
                    activity = ["Reading handwriting on this device…"]
                    handwriting = await HandwritingRecognizer.recognize(page.drawing)
                    try Task.checkCancellation()
                    activity = [handwriting.isEmpty ? "No handwriting recognized" : "Recognized \(handwriting.count) handwritten line\(handwriting.count == 1 ? "" : "s")"]
                }
                let state = AIPageState(content: page, handwriting: handwriting, info: info,
                                        keys: keys, selectedShapeID: selectedObjectID, imageInput: imageInput)
                let system = state.systemPrompt()
                let result = try await AIClient.runAgent(
                    provider: provider, apiKey: apiKey, model: model, system: system,
                    history: history, prompt: prompt, tools: AIPageState.tools(imageInput: imageInput),
                    onEvent: { [weak self] event in
                        if case let .toolStarted(name) = event {
                            let label = switch name {
                            case "apply_patch": "Editing the page…"
                            case "clear_page": "Clearing the page…"
                            case "view_page": "Looking at the page…"
                            default: "Reading the page…"
                            }
                            self?.activity.append(label)
                        }
                    },
                    execute: { [weak self] call in
                        let outcome = state.execute(call)
                        if let self, !self.activity.isEmpty { self.activity[self.activity.count - 1] = outcome.summary }
                        return outcome
                    }
                )
                try Task.checkCancellation()
                var saveFailed = false
                if state.revision > 0 {
                    let changed = state.content
                    switch apply(changed) {
                    case .applied: break
                    case .saveFailed: saveFailed = true
                    case .pageChanged:
                        finishWithError("The page changed while AI was working. Send again to use the latest page.")
                        return
                    }
                }
                self.keys = keys
                self.history.append(AIClient.compacted(result.newMessages))
                bubbles.append(Bubble(text: prompt, fromUser: true))
                bubbles.append(Bubble(text: result.reply, fromUser: false))
                if saveFailed {
                    errorMessage = "The edit is on the page but hasn’t been saved yet. Tap Retry save before closing the notebook."
                }
                pendingPrompt = nil
                activity = []
                request = nil
            } catch {
                guard !Task.isCancelled else { return }
                finishWithError(error.localizedDescription)
            }
        }
    }

    func cancel() {
        request?.cancel()
        request = nil
        if let pendingPrompt { draft = pendingPrompt }
        pendingPrompt = nil
        activity = []
    }

    func newThread() {
        cancel()
        bubbles = []
        history = []
        keys = AIPageKeys()
        draft = ""
        errorMessage = nil
    }

    private func finishWithError(_ message: String) {
        if let pendingPrompt { draft = pendingPrompt }
        pendingPrompt = nil
        activity = []
        request = nil
        errorMessage = message
    }
}

struct DrawingAIChatView: View {
    @ObservedObject var chat: DrawingAIChat
    let provider: AIProvider
    let model: String
    let imageInput: Bool
    let pageNumber: Int
    let pageCount: Int
    let onSend: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Drawing AI", systemImage: "sparkles")
                        .font(.headline)
                    Text("Sees page \(pageNumber) of \(pageCount) only")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("New thread", systemImage: "plus.bubble") { chat.newThread() }
                    .font(.subheadline)
                Button("Close", systemImage: "xmark") { onClose() }
                    .labelStyle(.iconOnly)
                    .padding(.leading, 6)
            }
            .padding(16)
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if chat.bubbles.isEmpty && chat.pendingPrompt == nil {
                            Text("Try “What did I write?”, “Erase the second line,” “Write ‘Project plan’ at the top,” or “Draw an airplane in the top right.”")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(chat.bubbles.indices, id: \.self) { index in
                            bubble(chat.bubbles[index].text, fromUser: chat.bubbles[index].fromUser)
                        }
                        if let pendingPrompt = chat.pendingPrompt {
                            bubble(pendingPrompt, fromUser: true)
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Waiting for \(provider.title)…").foregroundStyle(.secondary)
                                Spacer()
                                Button("Cancel") { chat.cancel() }
                            }
                            .font(.subheadline)
                            ForEach(chat.activity.indices, id: \.self) { index in
                                Label(chat.activity[index], systemImage: index == chat.activity.count - 1 ? "circle.dotted" : "checkmark")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let error = chat.errorMessage {
                            Text(verbatim: error)
                                .font(.subheadline)
                                .foregroundStyle(.red)
                                .accessibilityLabel("Drawing AI error: \(error)")
                        }
                        Color.clear.frame(height: 1).id("chat-bottom")
                    }
                    .padding(16)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: chat.bubbles.count) { _, _ in proxy.scrollTo("chat-bottom", anchor: .bottom) }
                .onChange(of: chat.pendingPrompt) { _, _ in proxy.scrollTo("chat-bottom", anchor: .bottom) }
                .onChange(of: chat.activity) { _, _ in proxy.scrollTo("chat-bottom", anchor: .bottom) }
            }
            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .bottom, spacing: 10) {
                    TextField("Describe what to draw or change", text: $chat.draft, axis: .vertical)
                        .lineLimit(1...4)
                        .padding(10)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                        .disabled(chat.pendingPrompt != nil)
                    Button(action: onSend) {
                        Label("Send", systemImage: "arrow.up")
                            .labelStyle(.iconOnly)
                            .frame(minWidth: 24, minHeight: 24)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!chat.canSend)
                }
                Text(sharingSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
        }
        .frame(idealWidth: 410, idealHeight: 450)
    }

    private var sharingSummary: String {
        let destination = "\(provider.title) (\(model))"
        let images = imageInput ? " AI can also request images of this page." : " No images are sent."
        return "Handwriting is recognized on this device. AI reads this page when it needs to: chat, page objects, recognized text, and simplified strokes go to \(destination)." + images
    }

    private func bubble(_ text: String, fromUser: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(fromUser ? "You" : "Drawing AI")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Group {
                if fromUser { Text(verbatim: text) } else { ChatMarkdown(text: text) }
            }
            .textSelection(.enabled)
        }
        .padding(10)
        .background(fromUser ? Theme.accent.opacity(0.10) : Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: .infinity, alignment: fromUser ? .trailing : .leading)
    }
}

/// Renders the subset of Markdown chat models use: headings, bullet and numbered lists,
/// quotes, code blocks, rules, and inline bold, italic, code, and links.
struct ChatMarkdown: View {
    enum Block: Equatable {
        case heading(level: Int, text: String)
        case bullet(indent: Int, text: String)
        case numbered(indent: Int, number: String, text: String)
        case quote(String)
        case code(String)
        case rule
        case paragraph(String)
    }

    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case let .heading(level, text):
            Text(Self.inline(text))
                .font(level == 1 ? .title3.weight(.semibold) : level == 2 ? .headline : .subheadline.weight(.semibold))
                .padding(.top, 2)
        case let .bullet(indent, text):
            listItem(marker: indent == 0 ? "•" : "◦", text: text, indent: indent)
        case let .numbered(indent, number, text):
            listItem(marker: number + ".", text: text, indent: indent)
        case let .quote(text):
            Text(Self.inline(text))
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(.tertiary).frame(width: 3) }
        case let .code(code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(verbatim: code).font(.callout.monospaced()).padding(8)
            }
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        case .rule:
            Divider()
        case let .paragraph(text):
            Text(Self.inline(text))
        }
    }

    private func listItem(marker: String, text: String, indent: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: marker).monospacedDigit().foregroundStyle(.secondary)
            Text(Self.inline(text))
        }
        .padding(.leading, CGFloat(indent) * 16)
    }

    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    static func blocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String]?

        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }

        for rawLine in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let open = code {
                    blocks.append(.code(open.joined(separator: "\n")))
                    code = nil
                } else {
                    flushParagraph()
                    code = []
                }
                continue
            }
            if code != nil { code?.append(rawLine); continue }
            if line.isEmpty { flushParagraph(); continue }

            let indent = rawLine.prefix { $0 == " " || $0 == "\t" }
                .reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } / 2
            if let heading = headingBlock(line) {
                flushParagraph(); blocks.append(heading)
            } else if ["---", "***", "___"].contains(line.replacingOccurrences(of: " ", with: "")) {
                flushParagraph(); blocks.append(.rule)
            } else if let marker = line.first, "-*+".contains(marker), line.dropFirst().first == " " {
                flushParagraph()
                blocks.append(.bullet(indent: min(indent, 3), text: String(line.dropFirst(2))))
            } else if let item = numberedItem(line) {
                flushParagraph()
                blocks.append(.numbered(indent: min(indent, 3), number: item.number, text: item.text))
            } else if line.hasPrefix(">") {
                flushParagraph()
                let quoted = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                if case let .quote(previous)? = blocks.last {
                    blocks[blocks.count - 1] = .quote(previous + "\n" + quoted)
                } else {
                    blocks.append(.quote(quoted))
                }
            } else {
                paragraph.append(line)
            }
        }
        if let code { blocks.append(.code(code.joined(separator: "\n"))) }
        flushParagraph()
        return blocks
    }

    private static func headingBlock(_ line: String) -> Block? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        let text = line.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#")).trimmingCharacters(in: .whitespaces)
        return .heading(level: min(hashes, 3), text: text)
    }

    private static func numberedItem(_ line: String) -> (number: String, text: String)? {
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        guard (1...3).contains(digits.count) else { return nil }
        let rest = line.dropFirst(digits.count)
        guard let delimiter = rest.first, delimiter == "." || delimiter == ")", rest.dropFirst().first == " " else { return nil }
        return (String(digits), String(rest.dropFirst(2)))
    }
}
