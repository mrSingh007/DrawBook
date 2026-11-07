import Foundation
import Combine
import CryptoKit
import PDFKit
import PencilKit

/// Each notebook owns a manifest, one PencilKit file per page, and optional PDF backgrounds.
/// The app has no cloud container. Its private directory is also excluded from device backups.
@MainActor
final class NotebookStore: ObservableObject {
    @Published private(set) var notebooks: [Notebook] = []
    @Published var errorMessage: String?

    private let rootURL: URL
    private let fileManager = FileManager.default
    private var unreadableDrawings = Set<String>()
    // Keep failed writes alive across editor navigation. This cache is intentionally
    // temporary; the UI must keep showing an unsaved warning until retry succeeds.
    private var unsavedDrawings: [String: PKDrawing] = [:]
    private var unsavedShapes: [String: [NoteShape]] = [:]
    private var available = false
    private static let maximumBackupBytes = 500 * 1_024 * 1_024

    private struct Manifest: Codable {
        var version = 1
        var notebook: Notebook
    }

    private struct Backup: Codable {
        var version = 1
        var notebook: Notebook
        var drawings: [String: Data]
        var backgrounds: [String: Data]
    }

    /// PencilKit may accept arbitrary bytes as an empty drawing without throwing.
    /// An app-owned envelope checks our file format and integrity before decoding ink.
    private struct DrawingEnvelope: Codable {
        var version = 1
        var data: Data
        var checksum: Data
    }

    enum StoreError: LocalizedError {
        case unavailable, missingNotebook, missingPage, invalidDocument(String), damagedDrawing, oversized(String)

        var errorDescription: String? {
            switch self {
            case .unavailable: "The local notebook folder is unavailable. Your existing files have not been changed."
            case .missingNotebook: "This notebook could not be found."
            case .missingPage: "This page could not be found."
            case .invalidDocument(let reason): "The document could not be opened: \(reason)"
            case .damagedDrawing: "This page’s drawing could not be read. The original file has been preserved and will not be overwritten. Restore an editable backup or create a new page."
            case .oversized(let reason): reason
            }
        }
    }

    /// An alternate root makes persistence tests independent of the user's real library.
    init(rootURL: URL? = nil) {
        self.rootURL = rootURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PaperNest", isDirectory: true)
        do {
            try prepareDirectory(self.rootURL)
            available = true
            try loadLibrary()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func notebook(id: UUID) -> Notebook? { notebooks.first { $0.id == id } }

    @discardableResult
    func createNotebook(title: String, cover: CoverColor, paper: PaperStyle) -> UUID? {
        perform {
            let notebook = Notebook(title: cleanTitle(title), cover: cover, pages: [NotePage(paper: paper)])
            try install(notebook: notebook) { _ in }
            return notebook.id
        }
    }

    func renameNotebook(id: UUID, title: String) {
        _ = perform { try update(id) { $0.title = cleanTitle(title) } }
    }

    func deleteNotebook(id: UUID) {
        _ = perform {
            _ = try requireNotebook(id)
            try fileManager.removeItem(at: directory(id))
            notebooks.removeAll { $0.id == id }
            unsavedDrawings = unsavedDrawings.filter { !$0.key.hasPrefix("\(id)/") }
            unsavedShapes = unsavedShapes.filter { !$0.key.hasPrefix("\(id)/") }
        }
    }

    @discardableResult
    func duplicateNotebook(id: UUID) -> UUID? {
        perform {
            let original = try effectiveNotebook(id)
            var copy = original
            copy.id = UUID()
            copy.title = original.title + " copy"
            copy.createdAt = Date()
            copy.updatedAt = Date()
            try install(notebook: copy) { staging in
                for page in original.pages {
                    let drawing = try drawingForExport(notebookID: id, pageID: page.id)
                    try write(encodeDrawing(drawing), to: drawingURL(in: staging, pageID: page.id))
                    if let filename = page.backgroundFile {
                        let data = try Data(contentsOf: safeFile(filename, in: directory(id)))
                        try write(data, to: safeFile(filename, in: staging))
                    }
                }
            }
            return copy.id
        }
    }

    @discardableResult
    func addPage(notebookID: UUID, paper: PaperStyle) -> UUID? {
        perform {
            let page = NotePage(paper: paper)
            try update(notebookID) { $0.pages.append(page) }
            return page.id
        }
    }

    func deletePage(notebookID: UUID, pageID: UUID) {
        _ = perform {
            let notebook = try requireNotebook(notebookID)
            guard notebook.pages.count > 1 else { return }
            guard let page = notebook.pages.first(where: { $0.id == pageID }) else { throw StoreError.missingPage }
            // Save the new manifest first; an interrupted cleanup can only leave unused files.
            try update(notebookID) { $0.pages.removeAll { $0.id == pageID } }
            unsavedDrawings.removeValue(forKey: drawingKey(notebookID, pageID))
            unsavedShapes.removeValue(forKey: drawingKey(notebookID, pageID))
            let ink = drawingURL(in: directory(notebookID), pageID: pageID)
            if fileManager.fileExists(atPath: ink.path) { try fileManager.removeItem(at: ink) }
            if let filename = page.backgroundFile {
                try fileManager.removeItem(at: safeFile(filename, in: directory(notebookID)))
            }
        }
    }

    func setPaper(notebookID: UUID, pageID: UUID, paper: PaperStyle) {
        _ = perform {
            try update(notebookID) { notebook in
                guard let index = notebook.pages.firstIndex(where: { $0.id == pageID }) else { throw StoreError.missingPage }
                notebook.pages[index].paper = paper
            }
        }
    }

    func drawing(notebookID: UUID, pageID: UUID) -> PKDrawing {
        do { return try drawingForExport(notebookID: notebookID, pageID: pageID) }
        catch {
            unreadableDrawings.insert(drawingKey(notebookID, pageID))
            errorMessage = error.localizedDescription
            return PKDrawing()
        }
    }

    /// Exports must fail visibly rather than replacing unreadable ink with a blank page.
    func drawingForExport(notebookID: UUID, pageID: UUID) throws -> PKDrawing {
        // Validate the original file even when a failed-write snapshot is available.
        let persisted = try readDrawing(notebookID: notebookID, pageID: pageID)
        return unsavedDrawings[drawingKey(notebookID, pageID)] ?? persisted
    }

    func hasUnsavedDrawing(notebookID: UUID, pageID: UUID) -> Bool {
        unsavedDrawings[drawingKey(notebookID, pageID)] != nil
    }

    func shapes(notebookID: UUID, pageID: UUID) throws -> [NoteShape] {
        let notebook = try requireNotebook(notebookID)
        guard let page = notebook.pages.first(where: { $0.id == pageID }) else { throw StoreError.missingPage }
        return unsavedShapes[drawingKey(notebookID, pageID)] ?? page.shapes
    }

    func hasUnsavedShapes(notebookID: UUID, pageID: UUID) -> Bool {
        unsavedShapes[drawingKey(notebookID, pageID)] != nil
    }

    func saveShapes(_ shapes: [NoteShape], notebookID: UUID, pageID: UUID) throws {
        let notebook = try requireNotebook(notebookID)
        guard notebook.pages.contains(where: { $0.id == pageID }) else { throw StoreError.missingPage }
        try validateShapes(shapes)
        let key = drawingKey(notebookID, pageID)
        do {
            try update(notebookID) { changed in
                guard let index = changed.pages.firstIndex(where: { $0.id == pageID }) else { throw StoreError.missingPage }
                changed.pages[index].shapes = shapes
            }
            unsavedShapes.removeValue(forKey: key)
        } catch {
            unsavedShapes[key] = shapes
            throw error
        }
    }

    /// The caller can present a save error and retain the in-memory drawing for retry.
    func saveDrawing(_ drawing: PKDrawing, notebookID: UUID, pageID: UUID) throws {
        let notebook = try requireNotebook(notebookID)
        guard notebook.pages.contains(where: { $0.id == pageID }) else { throw StoreError.missingPage }
        guard !unreadableDrawings.contains(drawingKey(notebookID, pageID)) else { throw StoreError.damagedDrawing }
        let destination = drawingURL(in: directory(notebookID), pageID: pageID)
        // Check existing ink even if no read occurred yet, so a failed read cannot be bypassed.
        if fileManager.fileExists(atPath: destination.path) {
            do { _ = try decodeDrawing(Data(contentsOf: destination)) }
            catch {
                unreadableDrawings.insert(drawingKey(notebookID, pageID))
                throw StoreError.damagedDrawing
            }
        }
        let key = drawingKey(notebookID, pageID)
        do {
            try write(encodeDrawing(drawing), to: destination)
            try update(notebookID) { _ in }
            unsavedDrawings.removeValue(forKey: key)
        } catch {
            unsavedDrawings[key] = drawing
            throw error
        }
    }

    func backgroundURL(notebookID: UUID, pageID: UUID) -> URL? {
        guard let filename = notebook(id: notebookID)?.pages.first(where: { $0.id == pageID })?.backgroundFile else { return nil }
        return try? safeFile(filename, in: directory(notebookID))
    }

    @discardableResult
    func importPDF(from url: URL) -> UUID? {
        perform {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            try checkSize(url, maximum: 250 * 1_024 * 1_024, description: "PDFs larger than 250 MB cannot be imported. Split the document into smaller files first.")
            guard let document = PDFDocument(url: url), !document.isLocked, document.pageCount > 0 else {
                throw StoreError.invalidDocument("choose a readable, unlocked PDF.")
            }
            guard document.pageCount <= 200 else {
                throw StoreError.oversized("Import up to 200 PDF pages at a time. Split this document into smaller PDFs first.")
            }
            let pages = (0..<document.pageCount).map { _ in NotePage(paper: .blank) }
            var notebook = Notebook(title: cleanTitle(url.deletingPathExtension().lastPathComponent), cover: .blue, pages: pages)
            for index in notebook.pages.indices { notebook.pages[index].backgroundFile = "\(notebook.pages[index].id.uuidString).pdf" }
            try install(notebook: notebook) { staging in
                for index in notebook.pages.indices {
                    guard let page = document.page(at: index) else { throw StoreError.invalidDocument("a PDF page is unreadable.") }
                    let singlePage = PDFDocument()
                    singlePage.insert(page, at: 0)
                    guard let data = singlePage.dataRepresentation(), let filename = notebook.pages[index].backgroundFile else {
                        throw StoreError.invalidDocument("a PDF page could not be copied.")
                    }
                    try write(data, to: safeFile(filename, in: staging))
                }
            }
            return notebook.id
        }
    }

    /// A self-contained editable JSON archive; PNG/PDF exports alone cannot restore PencilKit strokes.
    func exportBackup(notebookID: UUID) throws -> URL {
        let notebook = try effectiveNotebook(notebookID)
        var drawings: [String: Data] = [:]
        var backgrounds: [String: Data] = [:]
        for page in notebook.pages {
            drawings[page.id.uuidString] = try encodeDrawing(drawingForExport(notebookID: notebookID, pageID: page.id))
            if let filename = page.backgroundFile {
                let data = try Data(contentsOf: safeFile(filename, in: directory(notebookID)))
                // Do not offer a successful backup that this same app cannot restore.
                // A damaged background must fail visibly, just like damaged ink.
                try validateBackupBackground(data)
                backgrounds[filename] = data
            }
        }
        let archive = Backup(notebook: notebook, drawings: drawings, backgrounds: backgrounds)
        let encoded = try JSONEncoder().encode(archive)
        guard encoded.count <= Self.maximumBackupBytes else {
            throw StoreError.oversized("This notebook is too large for a restorable editable backup (500 MB maximum). Duplicate the notebook and divide its pages into smaller notebooks before exporting backups.")
        }
        let folder = fileManager.temporaryDirectory.appendingPathComponent("DrawBookExports", isDirectory: true)
        try prepareDirectory(folder)
        let output = folder.appendingPathComponent("\(safeExportName(notebook.title))-\(UUID().uuidString.prefix(8)).papernest")
        try write(encoded, to: output)
        return output
    }

    @discardableResult
    func importBackup(from url: URL) -> UUID? {
        perform {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            try checkSize(url, maximum: Self.maximumBackupBytes, description: "Editable backups larger than 500 MB cannot be imported.")
            let archive = try JSONDecoder().decode(Backup.self, from: Data(contentsOf: url))
            guard archive.version == 1 else { throw StoreError.invalidDocument("this backup version is not supported.") }
            try validate(archive.notebook)
            var notebook = archive.notebook
            notebook.id = UUID() // Restore a separate notebook without overwriting any existing work.
            notebook.updatedAt = Date()
            try install(notebook: notebook) { staging in
                for page in notebook.pages {
                    guard let ink = archive.drawings[page.id.uuidString] else {
                        throw StoreError.invalidDocument("the backup is missing a drawing.")
                    }
                    _ = try decodeDrawing(ink)
                    try write(ink, to: drawingURL(in: staging, pageID: page.id))
                    if let filename = page.backgroundFile {
                        guard let data = archive.backgrounds[filename] else {
                            throw StoreError.invalidDocument("the backup is missing a valid PDF page.")
                        }
                        try validateBackupBackground(data)
                        try write(data, to: safeFile(filename, in: staging))
                    }
                }
            }
            return notebook.id
        }
    }

    private func loadLibrary() throws {
        let children = try fileManager.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        var failures = 0
        for child in children where (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            guard UUID(uuidString: child.lastPathComponent) != nil else { continue }
            do {
                let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: child.appendingPathComponent("notebook.json")))
                guard manifest.version == 1, manifest.notebook.id.uuidString == child.lastPathComponent else {
                    throw StoreError.invalidDocument("unsupported notebook format.")
                }
                try validate(manifest.notebook)
                notebooks.append(manifest.notebook)
            } catch { failures += 1 }
        }
        sortLibrary()
        if failures > 0 {
            errorMessage = "\(failures) notebook(s) could not be read. Their original files have been preserved. Restore an editable backup to recover your notes."
        }
    }

    private func validate(_ notebook: Notebook) throws {
        guard !notebook.pages.isEmpty, notebook.pages.count <= 10_000,
              Set(notebook.pages.map(\.id)).count == notebook.pages.count else {
            throw StoreError.invalidDocument("the page list is invalid.")
        }
        for page in notebook.pages {
            try validateShapes(page.shapes)
            if let filename = page.backgroundFile {
                guard filename == "\(page.id.uuidString).pdf" else { throw StoreError.invalidDocument("the PDF filename is invalid.") }
            }
        }
    }

    private func validateShapes(_ shapes: [NoteShape]) throws {
        guard shapes.count <= 10_000, Set(shapes.map(\.id)).count == shapes.count else {
            throw StoreError.invalidDocument("the shape list is invalid.")
        }
        var maskPointCount = 0
        for shape in shapes {
            guard shape.erasureMasks.count <= 100_000 else {
                throw StoreError.invalidDocument("a shape has too many erased areas.")
            }
            for mask in shape.erasureMasks {
                maskPointCount += mask.points.count
                guard (3...256).contains(mask.points.count), maskPointCount <= 2_000_000,
                      mask.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && abs($0.x) <= 1_000_000 && abs($0.y) <= 1_000_000 }) else {
                    throw StoreError.invalidDocument("a shape has an invalid erased area.")
                }
            }
            // CGRect.width/height can standardize negative extents. Validate the
            // stored signed size so malformed files cannot slip through as valid.
            let width = shape.frame.size.width
            let height = shape.frame.size.height
            let dimensions = [shape.frame.origin.x, shape.frame.origin.y, width, height]
            let components = [shape.color.red, shape.color.green, shape.color.blue, shape.color.alpha]
            let validSize = shape.kind == .line || shape.kind == .arrow
                ? width >= 0 && height >= 0 && width + height > 0
                : width > 0 && height > 0
            guard dimensions.allSatisfy({ $0.isFinite && abs($0) <= 100_000 }), validSize,
                  shape.lineWidth.isFinite, shape.lineWidth > 0, shape.lineWidth <= 100,
                  shape.rotation.isFinite, abs(shape.rotation) <= 1_000_000,
                  components.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
                throw StoreError.invalidDocument("a shape has invalid geometry or styling.")
            }
        }
    }

    private func effectiveNotebook(_ id: UUID) throws -> Notebook {
        var result = try requireNotebook(id)
        for index in result.pages.indices {
            if let cached = unsavedShapes[drawingKey(id, result.pages[index].id)] {
                result.pages[index].shapes = cached
            }
        }
        return result
    }

    private func readDrawing(notebookID: UUID, pageID: UUID) throws -> PKDrawing {
        let notebook = try requireNotebook(notebookID)
        guard notebook.pages.contains(where: { $0.id == pageID }) else { throw StoreError.missingPage }
        let url = drawingURL(in: directory(notebookID), pageID: pageID)
        guard fileManager.fileExists(atPath: url.path) else { return PKDrawing() }
        do { return try decodeDrawing(Data(contentsOf: url)) }
        catch { throw StoreError.damagedDrawing }
    }

    private func encodeDrawing(_ drawing: PKDrawing) throws -> Data {
        let data = drawing.dataRepresentation()
        let envelope = DrawingEnvelope(data: data, checksum: Data(SHA256.hash(data: data)))
        return try JSONEncoder().encode(envelope)
    }

    private func decodeDrawing(_ data: Data) throws -> PKDrawing {
        do {
            let envelope = try JSONDecoder().decode(DrawingEnvelope.self, from: data)
            guard envelope.version == 1, !envelope.data.isEmpty,
                  envelope.checksum == Data(SHA256.hash(data: envelope.data)) else {
                throw StoreError.damagedDrawing
            }
            return try PKDrawing(data: envelope.data)
        } catch { throw StoreError.damagedDrawing }
    }

    private func requireNotebook(_ id: UUID) throws -> Notebook {
        guard available else { throw StoreError.unavailable }
        guard let notebook = notebook(id: id) else { throw StoreError.missingNotebook }
        return notebook
    }

    private func update(_ id: UUID, mutation: (inout Notebook) throws -> Void) throws {
        var changed = try requireNotebook(id)
        try mutation(&changed)
        changed.updatedAt = Date()
        try validate(changed)
        try writeManifest(changed, in: directory(id))
        if let index = notebooks.firstIndex(where: { $0.id == id }) { notebooks[index] = changed }
        sortLibrary()
    }

    private func install(notebook: Notebook, populate: (URL) throws -> Void) throws {
        guard available else { throw StoreError.unavailable }
        try validate(notebook)
        let staging = rootURL.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try prepareDirectory(staging)
        defer { try? fileManager.removeItem(at: staging) }
        try populate(staging)
        try writeManifest(notebook, in: staging)
        try fileManager.moveItem(at: staging, to: directory(notebook.id))
        notebooks.append(notebook)
        sortLibrary()
    }

    private func writeManifest(_ notebook: Notebook, in folder: URL) throws {
        try write(JSONEncoder().encode(Manifest(notebook: notebook)), to: folder.appendingPathComponent("notebook.json"))
    }

    private func prepareDirectory(_ url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true,
                                        attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var excludedURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excludedURL.setResourceValues(values)
    }

    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func directory(_ id: UUID) -> URL { rootURL.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func drawingURL(in folder: URL, pageID: UUID) -> URL { folder.appendingPathComponent("\(pageID.uuidString).drawing") }
    private func drawingKey(_ notebookID: UUID, _ pageID: UUID) -> String { "\(notebookID)/\(pageID)" }
    private func sortLibrary() { notebooks.sort { $0.updatedAt > $1.updatedAt } }

    private func safeFile(_ filename: String, in folder: URL) throws -> URL {
        guard !filename.isEmpty, filename != ".", filename != "..", !filename.contains("/"), !filename.contains("\\") else {
            throw StoreError.invalidDocument("an unsafe filename was found.")
        }
        return folder.appendingPathComponent(filename)
    }

    private func cleanTitle(_ title: String) -> String {
        let trimmed = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        return trimmed.isEmpty ? "Untitled notebook" : trimmed
    }

    private func safeExportName(_ title: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let result = String(title.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" }.prefix(64))
        return result.isEmpty ? "Notebook" : result
    }

    private func checkSize(_ url: URL, maximum: Int, description: String) throws {
        guard url.isFileURL else {
            throw StoreError.invalidDocument("choose a local file or a file from a document provider.")
        }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else {
            throw StoreError.invalidDocument("choose a regular document file.")
        }
        guard let size = values.fileSize, size >= 0, size <= maximum else { throw StoreError.oversized(description) }
    }

    private func validateBackupBackground(_ data: Data) throws {
        guard let pdf = PDFDocument(data: data), !pdf.isLocked, pdf.pageCount == 1 else {
            throw StoreError.invalidDocument("the backup is missing a valid PDF page.")
        }
    }

    private func perform<T>(_ action: () throws -> T) -> T? {
        do { return try action() }
        catch { errorMessage = error.localizedDescription; return nil }
    }
}
