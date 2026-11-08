import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var store: NotebookStore
    @EnvironmentObject private var aiSettings: AISettings
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var selection: UUID?
    @State private var compactColumn: NavigationSplitViewColumn = .detail
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var query = ""
    @State private var filter: LibraryFilter = .all
    @State private var creating = false
    @State private var importing = false
    @State private var showingHelp = false
    @State private var showingAISettings = false
    @State private var renameID: UUID?
    @State private var renameTitle = ""
    @State private var deleteID: UUID?
    @State private var shareFile: ShareFile?

    private var filteredNotebooks: [Notebook] {
        store.notebooks.filter { notebook in
            (query.isEmpty || notebook.title.localizedCaseInsensitiveContains(query)) &&
            (filter != .pdfs || notebook.pages.contains { $0.backgroundFile != nil })
        }.sorted { filter == .recent ? $0.updatedAt > $1.updatedAt : $0.createdAt > $1.createdAt }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $compactColumn) {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 10) {
                    Image(systemName: "leaf.fill").font(.title2)
                    Text("drawbook").font(.system(.title2, design: .serif, weight: .semibold))
                }
                .foregroundStyle(Theme.accent)
                .padding(.top, 24)

                Text("YOUR SPACE").font(.caption.weight(.semibold)).tracking(2).foregroundStyle(Theme.secondary)

                VStack(spacing: 6) {
                    ForEach(LibraryFilter.allCases) { item in
                        Button {
                            filter = item
                            selection = nil
                            compactColumn = .detail
                        } label: {
                            HStack {
                                Label(item.rawValue, systemImage: item.symbol)
                                Spacer()
                                if item == .all { Text("\(store.notebooks.count)").font(.caption) }
                            }
                            .font(.subheadline.weight(.medium))
                            .padding(13)
                            .foregroundStyle(filter == item ? Theme.accent : Theme.secondary)
                            .background(filter == item ? Color.white.opacity(0.8) : .clear, in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }
                }
                aiConfiguration
                Spacer()
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "internaldrive").font(.title2)
                    Text("A little space, just for you.").font(.system(.title3, design: .serif))
                    Text("Your notebooks are stored on this device. Writing and drawing work offline without a DrawBook account.")
                        .font(.caption).foregroundStyle(Theme.secondary)
                    Button("About & pencil help", systemImage: "questionmark.circle") { showingHelp = true }
                        .font(.caption.weight(.medium))
                }
                .foregroundStyle(Theme.accent)
                .padding(18)
                .background(.white.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
                .padding(.bottom, 20)
            }
            .padding(.horizontal, 20)
            .background(Theme.sidebar)
            .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 290)
            .toolbar(.hidden, for: .navigationBar)
            // SwiftUI only honours sidebar-toggle removal on the sidebar column. While a notebook
            // is open the editor supplies its own toggle so the leading buttons never reorder.
            .toolbar(removing: selection == nil ? nil : .sidebarToggle)
        } detail: {
            NavigationStack {
                Group {
                    if let selection, store.notebook(id: selection) != nil {
                        NotebookEditor(notebookID: selection)
                            .id(selection)
                            .toolbar {
                                // Fixed order in both states: [sidebar toggle] [← Back].
                                ToolbarItem(placement: .topBarLeading) {
                                    Button {
                                        withAnimation {
                                            columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
                                        }
                                    } label: {
                                        Label(columnVisibility == .detailOnly ? "Show Sidebar" : "Hide Sidebar",
                                              systemImage: "sidebar.left")
                                    }
                                }
                                ToolbarItem(placement: .topBarLeading) {
                                    Button { self.selection = nil } label: {
                                        Label("Back", systemImage: "arrow.left")
                                            .labelStyle(.titleAndIcon)
                                    }
                                    .accessibilityLabel("Back to Notebooks")
                                }
                            }
                    } else {
                        library
                    }
                }
            }
        }
        .onChange(of: selection) { _, notebookID in
            columnVisibility = notebookID == nil ? .all : .detailOnly
        }
        .sheet(isPresented: $creating) {
            NewNotebookSheet { title, color, paper in
                selection = store.createNotebook(title: title, cover: color, paper: paper)
            }
        }
        .sheet(isPresented: $showingHelp) { HelpSheet() }
        .sheet(isPresented: $showingAISettings) {
            AIConfigurationSheet(settings: aiSettings)
        }
        .sheet(item: $shareFile) { ShareSheet(urls: $0.urls) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf, UTType(exportedAs: "com.local.papernest.notebook")]) { result in
            switch result {
            case .success(let url): importFile(url)
            case .failure(let error): store.errorMessage = error.localizedDescription
            }
        }
        .onOpenURL { importFile($0) }
        .alert("Rename notebook", isPresented: Binding(get: { renameID != nil }, set: { if !$0 { renameID = nil } })) {
            TextField("Notebook title", text: $renameTitle)
            Button("Cancel", role: .cancel) { renameID = nil }
            Button("Save") {
                if let id = renameID { store.renameNotebook(id: id, title: renameTitle) }
                renameID = nil
            }
        }
        .alert("Delete this notebook?", isPresented: Binding(get: { deleteID != nil }, set: { if !$0 { deleteID = nil } })) {
            Button("Cancel", role: .cancel) { deleteID = nil }
            Button("Delete", role: .destructive) {
                if let id = deleteID { store.deleteNotebook(id: id) }
                deleteID = nil
            }
        } message: {
            Text("This removes every page from this device. Export an editable backup first if you want to keep it.")
        }
        .alert("Something needs attention", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }

    private var aiConfiguration: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("AI").font(.caption.weight(.semibold)).tracking(2).foregroundStyle(Theme.secondary)
            Button { showingAISettings = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("AI configuration").font(.subheadline.weight(.medium))
                        Text(aiSettings.isConfigured ? "\(aiSettings.provider.title) · \(aiSettings.model)" : "Choose an AI provider")
                            .font(.caption).foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .accessibilityHidden(true)
                }
                .foregroundStyle(Theme.accent)
                .padding(13)
                .background(.white.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
        }
    }

    private var library: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 24) {
                        libraryHeading.fixedSize(horizontal: true, vertical: false)
                        Spacer()
                        newNotebookButton.fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 20) {
                        libraryHeading
                        newNotebookButton
                    }
                }
                .padding(.top, 24)

                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondary)
                    TextField("Find a notebook", text: $query).autocorrectionDisabled()
                    if !query.isEmpty { Button("Clear", systemImage: "xmark.circle.fill") { query = "" }.labelStyle(.iconOnly) }
                }
                .padding(14)
                .background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))

                if filteredNotebooks.isEmpty {
                    VStack(spacing: 18) {
                        Image(systemName: !query.isEmpty ? "magnifyingglass" : filter == .pdfs ? "doc.richtext" : "book.closed")
                            .font(.system(size: 46, weight: .ultraLight)).foregroundStyle(Theme.accent)
                        Text(!query.isEmpty ? "No notebooks found" : filter == .pdfs ? "Bring your PDFs to life." : "Something good starts here.")
                            .font(.system(.title2, design: .serif))
                        Text(!query.isEmpty ? "Try a different title." : filter == .pdfs ? "Import a PDF to highlight, sketch, and write on its pages." : "Make a notebook for your thoughts, sketches, and everyday discoveries. Or bring a PDF to write on.")
                            .foregroundStyle(Theme.secondary).multilineTextAlignment(.center).frame(maxWidth: 390)
                        if query.isEmpty {
                            if filter == .pdfs {
                                Button("Import PDF or backup", systemImage: "square.and.arrow.down") { importing = true }
                                    .buttonStyle(.borderedProminent)
                            } else {
                                Button("Create your first notebook", systemImage: "plus") { creating = true }.buttonStyle(.borderedProminent)
                                Button("Import PDF or backup", systemImage: "square.and.arrow.down") { importing = true }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 70)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 280), spacing: 24)], alignment: .leading, spacing: 30) {
                        ForEach(filteredNotebooks) { notebook in
                            Button { selection = notebook.id } label: { NotebookCard(notebook: notebook) }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("Open", systemImage: "book") { selection = notebook.id }
                                    Button("Rename", systemImage: "pencil") { renameTitle = notebook.title; renameID = notebook.id }
                                    Button("Duplicate", systemImage: "plus.square.on.square") { _ = store.duplicateNotebook(id: notebook.id) }
                                    Button("Export editable backup", systemImage: "square.and.arrow.up") { backup(notebook.id) }
                                    Divider()
                                    Button("Delete", systemImage: "trash", role: .destructive) { deleteID = notebook.id }
                                }
                        }
                    }
                }
                HStack(spacing: 7) {
                    Image(systemName: "lock.shield")
                    Text("Saved on this device · Yours to keep")
                }
                .font(.caption).foregroundStyle(Theme.secondary).padding(.bottom, 24)
            }
            .padding(.horizontal, sizeClass == .compact ? 20 : 30)
        }
        .background(Theme.background)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Import PDF or backup", systemImage: "square.and.arrow.down") { importing = true }
                Button("About & pencil help", systemImage: "questionmark.circle") { showingHelp = true }
            }
        }
    }

    private var libraryHeading: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("ROOM FOR YOUR IDEAS").font(.caption.weight(.semibold)).tracking(2).foregroundStyle(Theme.secondary)
            Text(filter.rawValue).font(.system(.largeTitle, design: .serif)).foregroundStyle(Theme.ink)
            Text("A fresh page. A clearer mind.").foregroundStyle(Theme.secondary)
        }
    }

    private var newNotebookButton: some View {
        Button { creating = true } label: {
            Label("New notebook", systemImage: "plus").fontWeight(.semibold).padding(.vertical, 7)
        }
        .buttonStyle(.borderedProminent)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func importFile(_ url: URL) {
        if url.pathExtension.lowercased() == "pdf" { selection = store.importPDF(from: url) }
        else { selection = store.importBackup(from: url) }
    }

    private func backup(_ id: UUID) {
        do { shareFile = ShareFile(urls: [try store.exportBackup(notebookID: id)]) }
        catch { store.errorMessage = error.localizedDescription }
    }
}

private struct AIConfigurationSheet: View {
    @Environment(\.dismiss) private var dismiss
    let settings: AISettings
    @State private var provider: AIProvider
    @State private var apiKey: String
    @State private var model: String
    @State private var imageInput: Bool
    @State private var saveError: String?

    init(settings: AISettings) {
        self.settings = settings
        _provider = State(initialValue: settings.provider)
        _apiKey = State(initialValue: settings.apiKey)
        _model = State(initialValue: settings.model)
        _imageInput = State(initialValue: settings.imageInput)
    }

    private var providerSelection: Binding<AIProvider> {
        Binding(get: { provider }, set: { selected in
            guard provider != selected else { return }
            let configuration = settings.configuration(for: selected)
            apiKey = configuration.apiKey
            model = configuration.model
            imageInput = configuration.imageInput
            saveError = nil
            provider = selected
        })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Provider", selection: providerSelection) {
                        ForEach(AIProvider.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section {
                    SecureField("API key", text: $apiKey, prompt: Text("Enter your \(provider.title) API key"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("\(provider.title) API key")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Drawing AI uses your provider account and may incur provider charges. Your key is stored in Keychain. Clear it and save to turn off AI chat.")
                        Link("Get a \(provider.title) API key", destination: provider.keyURL)
                    }
                }

                Section {
                    TextField("Model ID", text: $model, prompt: Text(provider.defaultModel))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if model != provider.defaultModel {
                        Button("Use default model") { model = provider.defaultModel }
                    }
                } header: {
                    Text("\(provider.title) model")
                } footer: {
                    Text("Default model: \(provider.defaultModel). You can enter another model ID supported by this provider.")
                }

                Section {
                    Toggle(isOn: $imageInput) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Send Page as Image to AI")
                            Text("Make sure your model supports image input (vision).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("Drawing AI can request an image of the current page, including the paper and any imported PDF. Your handwriting and sketches appear in the image only when Include handwriting and sketches is on.")
                }

                if let saveError {
                    Text(saveError).font(.callout).foregroundStyle(.red)
                }
            }
            .navigationTitle("AI configuration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            try settings.save(provider: provider, apiKey: apiKey, model: model, imageInput: imageInput)
                            dismiss()
                        } catch {
                            saveError = error.localizedDescription
                        }
                    }
                }
            }
        }
    }
}

private enum LibraryFilter: String, CaseIterable, Identifiable {
    case all = "My notebooks", recent = "Recently edited", pdfs = "PDF notebooks"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .all: return "square.grid.2x2"; case .recent: return "clock"; case .pdfs: return "doc.richtext" }
    }
}

private struct NotebookCard: View {
    let notebook: Notebook

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 10).fill(notebook.cover.color.gradient)
                Rectangle().fill(.black.opacity(0.10)).frame(width: 13).padding(.leading, 9)
                VStack(alignment: .leading, spacing: 14) {
                    Image(systemName: notebook.pages.contains { $0.backgroundFile != nil } ? "doc.richtext" : "leaf")
                        .font(.title2.weight(.light))
                    Spacer()
                    Text(notebook.title).font(.system(.title2, design: .serif, weight: .medium)).lineLimit(3)
                    Rectangle().fill(.white.opacity(0.45)).frame(width: 35, height: 1)
                    Text("DRAWBOOK").font(.system(size: 8, weight: .medium)).tracking(3)
                }
                .foregroundStyle(.white).padding(.leading, 36).padding(.trailing, 20).padding(.vertical, 24)
            }
            .frame(height: 245)
            .shadow(color: Theme.ink.opacity(0.12), radius: 10, x: 3, y: 7)
            Text(notebook.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink).lineLimit(1)
            HStack {
                Text("\(notebook.pages.count) \(notebook.pages.count == 1 ? "page" : "pages")")
                Spacer()
                Text(notebook.updatedAt, format: .dateTime.month(.abbreviated).day())
            }
            .font(.caption).foregroundStyle(Theme.secondary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct NewNotebookSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var color: CoverColor = .sage
    @State private var paper: PaperStyle = .ruled
    let create: (String, CoverColor, PaperStyle) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Give your ideas a home") {
                    TextField("Notebook title", text: $title)
                        .onSubmit { finish() }
                }
                Section("Cover") {
                    HStack(spacing: 18) {
                        ForEach(CoverColor.allCases) { item in
                            Button { color = item } label: {
                                Circle().fill(item.color).frame(width: 38, height: 38)
                                    .overlay { if color == item { Image(systemName: "checkmark").foregroundStyle(.white).fontWeight(.bold) } }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(item.title)
                            .accessibilityAddTraits(color == item ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 8)
                }
                Section("Paper") {
                    Picker("Paper style", selection: $paper) {
                        ForEach(PaperStyle.allCases) { item in Label(item.title, systemImage: item.symbol).tag(item) }
                    }
                    .pickerStyle(.inline).labelsHidden()
                }
                Section { Text("You can change the paper and add more pages anytime.").foregroundStyle(Theme.secondary) }
            }
            .navigationTitle("New notebook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Create") { finish() }.fontWeight(.semibold) }
            }
        }
        .presentationDetents([.large])
    }

    private func finish() {
        create(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled notebook" : title, color, paper)
        dismiss()
    }
}

struct HelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Privacy") {
                    Link(destination: URL(string: "https://github.com/mrSingh007/DrawBook/blob/main/docs/PRIVACY.md")!) {
                        Label("Privacy Policy", systemImage: "hand.raised")
                    }
                }
                Section("Make yourself at home") {
                    Label("Handwrite, sketch, and annotate PDFs.", systemImage: "pencil.tip")
                    Label("Choose an illustrated pen nib for ballpoint, monoline, highlighter, fountain pen, pencil, watercolor, or crayon. Reed pen is available on iPadOS 26 or later. Tap the color circle or size button to adjust the selected tool.", systemImage: "paintpalette")
                    Label("Pinch to zoom. Pan with two fingers.", systemImage: "hand.draw")
                }
                Section("Shapes") {
                    Text("Tap the Shapes tool to open its popup and add a rectangle, ellipse, triangle, line, or arrow. Tap a shape to select it, drag its body to move it, and drag the blue corner handle to resize it.")
                    Text("The color circle and size button style the selected shape. Tap the trash button to delete it. Open the Shapes popup to change type, fill, and rotation or duplicate it. Choose Eraser and adjust its diameter with the size button to rub out parts of ink or shapes. Erasing can be undone while the page is open and stays saved in notebook backups.")
                    Text("Shape selection and dragging follow the same pencil/touch setting as drawing. Enable Touch drawing to manipulate shapes with a finger.")
                }
                Section("Temporary red laser") {
                    Text("Choose Laser to point or draw a glowing red trail. It fades and disappears three seconds after you lift the pen. Laser marks are never saved, included in backups, or added to PNG/PDF exports.")
                }
                Section("Metapen & other styluses") {
                    Text("Turn on your compatible stylus and write directly on a page. iPad-compatible active Metapen models use the system’s pencil input; no in-app pairing is needed.")
                    Text("If your pen does not leave a mark, enable Touch drawing in the page menu. Touch drawing also accepts fingers and capacitive styluses; palm rejection is less effective in that mode.")
                    Text("Pressure, tilt, palm rejection, and buttons depend on your iPad and pen. A stylus without pressure sensing cannot provide pressure-sensitive strokes.")
                }
                Section("Storage and sharing") {
                    Text("Notebooks are stored inside this app and excluded from automatic device backup. You choose when to export and share a notebook.")
                    Text("Optional Drawing AI sends your chat and editable content from the current page directly to your chosen provider. With handwriting sharing on, this includes recognized text and simplified strokes. With page images on, it can include a rendered image of an imported PDF page. Your provider’s data handling and retention settings apply.")
                    Text("Use Export editable backup to keep handwriting editable. PNG and PDF are for sharing and are flattened. Keep backups in On My iPad, an external drive, or another location you choose.")
                    Text("Deleting the app deletes its local notebooks. Export backups before deleting, changing signing identity, or reinstalling as a different app.")
                }
                Section("Built for a quieter kind of note-taking") {
                    Text("DrawBook is an independent notebook inspired by paper and simple tools. Writing and drawing work offline.")
                    Label("Free and open source under the MIT License.", systemImage: "curlybraces")
                }
            }
            .navigationTitle("About DrawBook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
