import SwiftUI
import PencilKit

struct NotebookEditor: View {
    @EnvironmentObject private var store: NotebookStore
    @EnvironmentObject private var aiSettings: AISettings
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @AppStorage("fingerDrawing") private var fingerDrawing = false
    @StateObject private var canvasController = CanvasController()
    @State private var currentPageID: UUID?
    @State private var pageEntryPosition: PageEntryPosition = .top
    @State private var drawing = PKDrawing()
    @State private var shapes: [NoteShape] = []
    @State private var pendingShapes: [NoteShape]?
    @State private var mode: CanvasMode = .ink
    @State private var pendingDrawing: PKDrawing?
    @State private var saveTask: Task<Void, Never>?
    @State private var inkSaveFailed = false
    @State private var shapeSaveFailed = false
    @State private var pageLoadError: String?
    @State private var showPages = false
    @State private var shareFile: ShareFile?
    @State private var confirmingClear = false
    @State private var confirmingDelete = false
    @State private var rename = false
    @State private var title = ""
    @StateObject private var aiChat = DrawingAIChat()
    @State private var showAIChat = false
    /// Bumped when a page's saved content changes, so only that page's thumbnail re-renders.
    @State private var pageRevisions: [UUID: Int] = [:]
    @State private var thumbnails = ThumbnailCache()
    let notebookID: UUID

    private var notebook: Notebook? { store.notebook(id: notebookID) }
    private var page: NotePage? { notebook?.pages.first { $0.id == currentPageID } }
    private var pageIndex: Int { notebook?.pages.firstIndex { $0.id == currentPageID } ?? 0 }
    private var saveFailed: Bool { inkSaveFailed || shapeSaveFailed }

    var body: some View {
        VStack(spacing: 0) {
            ToolControls(mode: $mode, showPages: $showPages, controller: canvasController)
                .disabled(pageLoadError != nil)
            Divider()
            HStack(spacing: 0) {
                if showPages { pageRail.frame(width: sizeClass == .compact ? 105 : 140) }
                if let pageLoadError {
                    ContentUnavailableView {
                        Label("This page needs attention", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(pageLoadError + " This page has not been changed. You can open another page or import an editable backup from the library.")
                    }
                } else if let page {
                    DrawingCanvas(
                        pageID: page.id,
                        drawing: drawing,
                        paper: page.paper,
                        backgroundURL: store.backgroundURL(notebookID: notebookID, pageID: page.id),
                        fingerDrawing: fingerDrawing,
                        controller: canvasController,
                        onChange: { changed in drawingChanged(changed, pageID: page.id) },
                        shapes: shapes,
                        mode: mode,
                        onShapesChange: { changed in shapesChanged(changed, pageID: page.id) },
                        canGoPrevious: pageIndex > 0,
                        // Swiping past the last page's bottom edge adds a new page.
                        canGoNext: true,
                        entryPosition: pageEntryPosition,
                        onPageTurn: { direction in turnPage(direction, from: page.id) }
                    )
                    .id(page.id)
                    .accessibilityLabel("Drawing page \(pageIndex + 1)")
                    .overlay(alignment: .bottomTrailing) {
                        if aiSettings.isConfigured { aiButton(pageID: page.id) }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .background(Theme.background)
        .navigationTitle(notebook?.title ?? "Notebook")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Button("Page as PNG image", systemImage: "photo") { export(.png) }
                    Button("Entire notebook as PDF", systemImage: "doc.richtext") { export(.pdf) }
                    Button("Editable notebook backup", systemImage: "externaldrive") { export(.backup) }
                } label: { Label("Share or export", systemImage: "square.and.arrow.up") }
                .disabled(pageLoadError != nil)
                Menu {
                    Toggle("Touch drawing", isOn: $fingerDrawing)
                    Button("Add page", systemImage: "plus.rectangle.on.rectangle") { addPage() }
                    Menu("Paper", systemImage: page?.paper.symbol ?? "rectangle") {
                        ForEach(PaperStyle.allCases) { style in
                            Button {
                                if let page { store.setPaper(notebookID: notebookID, pageID: page.id, paper: style) }
                            } label: {
                                Label(style.title, systemImage: page?.paper == style ? "checkmark" : style.symbol)
                            }
                        }
                    }
                    .disabled(page?.backgroundFile != nil || pageLoadError != nil)
                    Button("Rename notebook", systemImage: "pencil") { title = notebook?.title ?? ""; rename = true }
                    Button("Clear page", systemImage: "eraser", role: .destructive) { confirmingClear = true }
                        .disabled(pageLoadError != nil)
                    Button("Delete page", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                        .disabled((notebook?.pages.count ?? 0) <= 1)
                } label: { Label("Page options", systemImage: "ellipsis.circle") }
            }
        }
        .onAppear {
            if currentPageID == nil, let first = notebook?.pages.first { loadPage(first.id) }
        }
        .onDisappear { aiChat.cancel(); _ = flush() }
        .onChange(of: aiSettings.provider) { _, _ in
            showAIChat = false
            aiChat.newThread()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                canvasController.discardTransientMarks()
                _ = flush()
            }
        }
        .sheet(item: $shareFile, onDismiss: { canvasController.focus() }) { item in ShareSheet(urls: item.urls) }
        .onChange(of: rename) { _, isPresented in
            if !isPresented { canvasController.focus() }
        }
        .alert("Clear this page?", isPresented: $confirmingClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear page", role: .destructive) { canvasController.clear() }
        } message: { Text("Removes all handwriting, drawings, text, and shapes. The paper and imported PDF stay in place. You can undo this while the page is open.") }
        .alert("Delete this page?", isPresented: $confirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete page", role: .destructive) { deleteCurrentPage() }
        } message: { Text("The page and its handwriting will be permanently removed. Export an editable backup first to keep a copy.") }
        .alert("Rename notebook", isPresented: $rename) {
            TextField("Notebook title", text: $title)
            Button("Cancel", role: .cancel) {}
            Button("Save") { store.renameNotebook(id: notebookID, title: title) }
        }
    }

    private func aiButton(pageID: UUID) -> some View {
        Button {
            showAIChat = true
        } label: {
            Image(systemName: "sparkles")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 44, height: 44)
                .background(.regularMaterial, in: Circle())
                .overlay { Circle().strokeBorder(Theme.accent.opacity(0.2)) }
                .shadow(color: .black.opacity(0.09), radius: 5, y: 2)
        }
        .buttonStyle(.plain)
        .padding(14)
        .accessibilityLabel("Drawing AI")
        .popover(isPresented: $showAIChat, arrowEdge: .bottom) {
            DrawingAIChatView(chat: aiChat, provider: aiSettings.provider,
                              model: aiSettings.model, imageInput: aiSettings.imageInput,
                              pageNumber: pageIndex + 1, pageCount: notebook?.pages.count ?? 1) {
                guard currentPageID == pageID, pageLoadError == nil else { return }
                guard flush() else {
                    aiChat.errorMessage = "Retry saving the page before asking AI to edit it."
                    return
                }
                let original = AIPageContent(drawing: drawing, shapes: shapes)
                let info = AIPageState.PageInfo(number: pageIndex + 1, count: notebook?.pages.count ?? 1,
                                                paper: page?.paper ?? .ruled,
                                                hasPDFBackground: page?.backgroundFile != nil,
                                                pen: canvasController.currentInk,
                                                backgroundURL: store.backgroundURL(notebookID: notebookID, pageID: pageID))
                aiChat.send(provider: aiSettings.provider, apiKey: aiSettings.apiKey,
                            model: aiSettings.model, page: original, info: info,
                            imageInput: aiSettings.imageInput,
                            selectedObjectID: canvasController.selectedShape?.id) { changed in
                    guard currentPageID == pageID,
                          canvasController.applyAIPage(changed, replacing: original, pageID: pageID) else {
                        return .pageChanged
                    }
                    // Both layers are saved by flush; report a failure of either so the chat
                    // doesn't present a half-saved edit as done.
                    guard changed == original || flush() else { return .saveFailed }
                    return .applied
                }
            } onClose: {
                showAIChat = false
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button { previousPage() } label: { Image(systemName: "chevron.left") }
                .disabled(pageIndex == 0).accessibilityLabel("Previous page")
            Text("\(pageIndex + 1) / \(notebook?.pages.count ?? 1)")
                .font(.caption.monospacedDigit()).foregroundStyle(Theme.ink)
            Button { nextPage() } label: { Image(systemName: "chevron.right") }
                .disabled(pageIndex >= (notebook?.pages.count ?? 1) - 1).accessibilityLabel("Next page")
            Spacer()
            if pageLoadError != nil {
                Label("Page unavailable", systemImage: "exclamationmark.triangle").foregroundStyle(Theme.secondary)
            } else if saveFailed {
                Button("Retry save", systemImage: "exclamationmark.arrow.circlepath") { _ = flush() }
                    .foregroundStyle(.red)
            } else {
                Label(pendingDrawing == nil && pendingShapes == nil ? "Saved locally" : "Saving…", systemImage: pendingDrawing == nil && pendingShapes == nil ? "checkmark.circle" : "circle.dotted")
                    .foregroundStyle(Theme.secondary)
            }
            if sizeClass != .compact {
                Divider().frame(height: 12)
                Label(fingerDrawing ? "Touch drawing on" : "Pencil mode", systemImage: fingerDrawing ? "hand.draw" : "pencil.tip")
                    .foregroundStyle(Theme.secondary)
            }
        }
        .font(.caption2)
        .imageScale(.small)
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(.white.opacity(0.85))
    }

    private var pageRail: some View {
        ScrollView {
            LazyVStack(spacing: 18) {
                HStack {
                    Text("PAGES").font(.system(size: 10, weight: .semibold)).tracking(1.5)
                    Spacer()
                    Text("\(notebook?.pages.count ?? 0)").font(.caption)
                }
                .foregroundStyle(Theme.secondary)
                ForEach(Array((notebook?.pages ?? []).enumerated()), id: \.element.id) { index, item in
                    Button { switchPage(item.id) } label: {
                        VStack(spacing: 7) {
                            PagePreview(
                                notebookID: notebookID,
                                page: item,
                                revision: pageRevisions[item.id, default: 0],
                                cache: thumbnails,
                                activeDrawing: item.id == currentPageID ? drawing : nil,
                                activeShapes: item.id == currentPageID ? shapes : nil
                            )
                            .aspectRatio(0.75, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                            .overlay { RoundedRectangle(cornerRadius: 3).stroke(item.id == currentPageID ? Theme.accent : Theme.secondary.opacity(0.25), lineWidth: item.id == currentPageID ? 2 : 1) }
                            Text("\(index + 1)").font(.caption.monospacedDigit())
                                .foregroundStyle(item.id == currentPageID ? Theme.accent : Theme.secondary)
                        }
                        .padding(.horizontal, 4)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Page \(index + 1)")
                    .accessibilityAddTraits(item.id == currentPageID ? .isSelected : [])
                }
                Button("Add page", systemImage: "plus") { addPage() }.font(.caption)
            }
            .padding(16)
        }
        .background(Theme.sidebar.opacity(0.8))
    }

    private func drawingChanged(_ changed: PKDrawing, pageID: UUID) {
        guard currentPageID == pageID else { return }
        drawing = changed
        pendingDrawing = changed
        inkSaveFailed = false
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(400)) }
            catch { return }
            persist(changed, pageID: pageID)
        }
    }

    private func persist(_ changed: PKDrawing, pageID: UUID) {
        do {
            try store.saveDrawing(changed, notebookID: notebookID, pageID: pageID)
            pendingDrawing = nil
            inkSaveFailed = false
            pageRevisions[pageID, default: 0] += 1
        } catch {
            inkSaveFailed = true
            store.errorMessage = error.localizedDescription
        }
    }

    private func shapesChanged(_ changed: [NoteShape], pageID: UUID) {
        guard currentPageID == pageID else { return }
        shapes = changed
        pendingShapes = changed
        persistShapes(changed, pageID: pageID)
    }

    private func persistShapes(_ changed: [NoteShape], pageID: UUID) {
        do {
            try store.saveShapes(changed, notebookID: notebookID, pageID: pageID)
            pendingShapes = nil
            shapeSaveFailed = false
            pageRevisions[pageID, default: 0] += 1
        } catch {
            shapeSaveFailed = true
            store.errorMessage = error.localizedDescription
        }
    }

    /// Flush before page changes, exports, and backgrounding to preserve the most recent stroke.
    @discardableResult
    private func flush() -> Bool {
        saveTask?.cancel()
        guard let id = currentPageID, pageLoadError == nil else { return true }
        let latest = canvasController.finishEditing(pageID: id) ?? pendingDrawing ?? drawing
        if pendingDrawing != nil || latest.dataRepresentation() != drawing.dataRepresentation() {
            drawing = latest
            persist(latest, pageID: id)
        }
        let latestShapes = canvasController.finishShapes(pageID: id) ?? pendingShapes ?? shapes
        if pendingShapes != nil || latestShapes != shapes {
            shapes = latestShapes
            persistShapes(latestShapes, pageID: id)
        }
        return !saveFailed
    }

    private func loadPage(_ id: UUID, entryPosition: PageEntryPosition = .top) {
        showAIChat = false
        aiChat.newThread()
        pageEntryPosition = entryPosition
        currentPageID = id
        do {
            try PageRenderer.validateBackground(store.backgroundURL(notebookID: notebookID, pageID: id))
            drawing = try store.drawingForExport(notebookID: notebookID, pageID: id)
            shapes = try store.shapes(notebookID: notebookID, pageID: id)
            pageLoadError = nil
            inkSaveFailed = store.hasUnsavedDrawing(notebookID: notebookID, pageID: id)
            shapeSaveFailed = store.hasUnsavedShapes(notebookID: notebookID, pageID: id)
            pendingDrawing = inkSaveFailed ? drawing : nil
            pendingShapes = shapeSaveFailed ? shapes : nil
        } catch {
            drawing = PKDrawing()
            shapes = []
            pageLoadError = error.localizedDescription
            pendingDrawing = nil
            pendingShapes = nil
            inkSaveFailed = false
            shapeSaveFailed = false
        }
    }

    private func switchPage(_ id: UUID, entryPosition: PageEntryPosition = .top) {
        guard id != currentPageID, flush() else { return }
        loadPage(id, entryPosition: entryPosition)
    }

    private func turnPage(_ direction: PageTurnDirection, from sourcePageID: UUID) {
        guard currentPageID == sourcePageID, let pages = notebook?.pages else { return }
        let target = pageIndex + (direction == .next ? 1 : -1)
        if direction == .next && target == pages.count { addPage(); return }
        guard pages.indices.contains(target) else { return }
        switchPage(pages[target].id, entryPosition: direction == .previous ? .bottom : .top)
    }

    private func addPage() {
        guard flush() else { return }
        if let id = store.addPage(notebookID: notebookID, paper: page?.paper ?? .ruled) { loadPage(id) }
    }

    private func previousPage() {
        guard let pages = notebook?.pages, pageIndex > 0 else { return }
        switchPage(pages[pageIndex - 1].id)
    }

    private func nextPage() {
        guard let pages = notebook?.pages, pageIndex + 1 < pages.count else { return }
        switchPage(pages[pageIndex + 1].id)
    }

    private func deleteCurrentPage() {
        guard let id = currentPageID, let pages = notebook?.pages, pages.count > 1, flush() else { return }
        let replacement = pages[pageIndex == 0 ? 1 : pageIndex - 1].id
        store.deletePage(notebookID: notebookID, pageID: id)
        if notebook?.pages.contains(where: { $0.id == id }) == false { loadPage(replacement) }
    }

    private enum ExportKind { case png, pdf, backup }

    private func export(_ kind: ExportKind) {
        guard flush(), pageLoadError == nil, let notebook, let page else { return }
        do {
            let url: URL
            switch kind {
            case .png:
                let savedDrawing = try store.drawingForExport(notebookID: notebookID, pageID: page.id)
                url = try PageRenderer.png(drawing: savedDrawing, paper: page.paper, backgroundURL: store.backgroundURL(notebookID: notebookID, pageID: page.id), shapes: shapes)
            case .pdf:
                url = try PageRenderer.pdf(notebook: notebook, store: store)
            case .backup:
                url = try store.exportBackup(notebookID: notebookID)
            }
            shareFile = ShareFile(urls: [url])
        } catch { store.errorMessage = error.localizedDescription }
    }
}

/// Rendered thumbnails by page, so scrolling the lazy rail doesn't re-read and re-render pages.
private final class ThumbnailCache {
    struct Key: Hashable { let page: UUID; let revision: Int; let paper: PaperStyle; let background: String? }
    private var images: [UUID: (key: Key, image: UIImage)] = [:]

    func image(for key: Key) -> UIImage? {
        images[key.page].flatMap { $0.key == key ? $0.image : nil }
    }
    func store(_ image: UIImage, for key: Key) { images[key.page] = (key, image) }
}

private struct PagePreview: View {
    @EnvironmentObject private var store: NotebookStore
    let notebookID: UUID
    let page: NotePage
    let revision: Int
    let cache: ThumbnailCache
    let activeDrawing: PKDrawing?
    let activeShapes: [NoteShape]?
    @State private var image: UIImage?

    private var key: ThumbnailCache.Key {
        .init(page: page.id, revision: revision, paper: page.paper, background: page.backgroundFile)
    }

    var body: some View {
        Group {
            if let image = image ?? cache.image(for: key) { Image(uiImage: image).resizable().scaledToFit() }
            else { Rectangle().fill(.white) }
        }
        .task(id: key) {
            let key = key
            if let cached = cache.image(for: key) { image = cached; return }
            let ink = activeDrawing ?? store.drawing(notebookID: notebookID, pageID: page.id)
            let pageShapes = activeShapes ?? (try? store.shapes(notebookID: notebookID, pageID: page.id)) ?? []
            let rendered = PageRenderer.thumbnail(drawing: ink, paper: page.paper, backgroundURL: store.backgroundURL(notebookID: notebookID, pageID: page.id), shapes: pageShapes)
            cache.store(rendered, for: key)
            image = rendered
        }
    }
}
