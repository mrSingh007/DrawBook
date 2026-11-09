import XCTest
import PencilKit
import PDFKit
import UIKit
@testable import DrawBook

final class NotebookStoreTests: XCTestCase {
    @MainActor
    func testInkAndMetadataSurviveRelaunch() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = NotebookStore(rootURL: folder)
        let id = try XCTUnwrap(store.createNotebook(title: "Field notes", cover: .sage, paper: .dotted))
        let pageID = try XCTUnwrap(store.notebook(id: id)?.pages.first?.id)
        let ink = sampleDrawing()
        try store.saveDrawing(ink, notebookID: id, pageID: pageID)
        store.renameNotebook(id: id, title: "Garden sketches")

        let reopened = NotebookStore(rootURL: folder)
        XCTAssertNil(reopened.errorMessage)
        XCTAssertEqual(reopened.notebook(id: id)?.title, "Garden sketches")
        XCTAssertEqual(reopened.notebook(id: id)?.pages.first?.paper, .dotted)
        let restored = reopened.drawing(notebookID: id, pageID: pageID)
        XCTAssertEqual(restored.strokes.count, 1)
        XCTAssertEqual(restored.bounds, ink.bounds)
    }

    @MainActor
    func testCorruptedInkIsPreservedEvenIfSavingWithoutReading() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = NotebookStore(rootURL: folder)
        let id = try XCTUnwrap(store.createNotebook(title: "Keep me", cover: .blue, paper: .blank))
        let pageID = try XCTUnwrap(store.notebook(id: id)?.pages.first?.id)
        let inkURL = folder.appendingPathComponent(id.uuidString).appendingPathComponent("\(pageID.uuidString).drawing")
        let damaged = Data("damaged original ink".utf8)
        try damaged.write(to: inkURL)

        XCTAssertThrowsError(try store.saveDrawing(PKDrawing(), notebookID: id, pageID: pageID))
        XCTAssertFalse(store.hasUnsavedDrawing(notebookID: id, pageID: pageID))
        XCTAssertEqual(try Data(contentsOf: inkURL), damaged)
        _ = store.drawing(notebookID: id, pageID: pageID)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(try Data(contentsOf: inkURL), damaged)
    }

    @MainActor
    func testFailedWriteKeepsInkInMemoryUntilSuccessfulRetry() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = NotebookStore(rootURL: folder)
        let id = try XCTUnwrap(store.createNotebook(title: "Retry", cover: .sage, paper: .blank))
        let pageID = try XCTUnwrap(store.notebook(id: id)?.pages.first?.id)
        let notebookFolder = folder.appendingPathComponent(id.uuidString)
        let displaced = folder.appendingPathComponent(".displaced", isDirectory: true)
        // Replace the live notebook directory with a file to produce a real write
        // failure without relying on permissions or filling the device's disk.
        try FileManager.default.moveItem(at: notebookFolder, to: displaced)
        try Data("temporarily unavailable directory".utf8).write(to: notebookFolder)
        let ink = sampleDrawing()
        XCTAssertThrowsError(try store.saveDrawing(ink, notebookID: id, pageID: pageID))
        XCTAssertTrue(store.hasUnsavedDrawing(notebookID: id, pageID: pageID))
        XCTAssertEqual(store.drawing(notebookID: id, pageID: pageID).strokes.count, 1)
        XCTAssertEqual(try store.drawingForExport(notebookID: id, pageID: pageID).strokes.count, 1)

        try FileManager.default.removeItem(at: notebookFolder)
        try FileManager.default.moveItem(at: displaced, to: notebookFolder)
        try store.saveDrawing(store.drawing(notebookID: id, pageID: pageID), notebookID: id, pageID: pageID)
        XCTAssertFalse(store.hasUnsavedDrawing(notebookID: id, pageID: pageID))
        let reopened = NotebookStore(rootURL: folder)
        XCTAssertEqual(reopened.drawing(notebookID: id, pageID: pageID).strokes.count, 1)
    }

    @MainActor
    func testDrawingChecksumRejectsChangedPayloadWithoutOverwritingIt() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = NotebookStore(rootURL: folder)
        let id = try XCTUnwrap(store.createNotebook(title: "Integrity", cover: .sage, paper: .blank))
        let pageID = try XCTUnwrap(store.notebook(id: id)?.pages.first?.id)
        try store.saveDrawing(sampleDrawing(), notebookID: id, pageID: pageID)
        let inkURL = folder.appendingPathComponent(id.uuidString).appendingPathComponent("\(pageID.uuidString).drawing")
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: inkURL)) as? [String: Any])
        envelope["data"] = PKDrawing().dataRepresentation().base64EncodedString()
        let damaged = try JSONSerialization.data(withJSONObject: envelope)
        try damaged.write(to: inkURL)

        XCTAssertThrowsError(try store.drawingForExport(notebookID: id, pageID: pageID))
        XCTAssertThrowsError(try store.saveDrawing(PKDrawing(), notebookID: id, pageID: pageID))
        XCTAssertEqual(try Data(contentsOf: inkURL), damaged)
        XCTAssertFalse(store.hasUnsavedDrawing(notebookID: id, pageID: pageID))
    }

    @MainActor
    func testEditableBackupRestoresInkWithoutReplacingOriginal() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = NotebookStore(rootURL: folder)
        let originalID = try XCTUnwrap(store.createNotebook(title: "Journal", cover: .terracotta, paper: .ruled))
        let pageID = try XCTUnwrap(store.notebook(id: originalID)?.pages.first?.id)
        try store.saveDrawing(sampleDrawing(), notebookID: originalID, pageID: pageID)
        let backupURL = try store.exportBackup(notebookID: originalID)
        defer { try? FileManager.default.removeItem(at: backupURL) }
        let restoredID = try XCTUnwrap(store.importBackup(from: backupURL))

        XCTAssertNotEqual(originalID, restoredID)
        XCTAssertEqual(store.notebooks.count, 2)
        XCTAssertEqual(store.drawing(notebookID: restoredID, pageID: pageID).strokes.count, 1)
        XCTAssertEqual(store.drawing(notebookID: originalID, pageID: pageID).strokes.count, 1)
    }

    @MainActor
    func testLastPageCannotBeDeleted() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = NotebookStore(rootURL: folder)
        let id = try XCTUnwrap(store.createNotebook(title: "Pages", cover: .plum, paper: .grid))
        let first = try XCTUnwrap(store.notebook(id: id)?.pages.first?.id)
        store.deletePage(notebookID: id, pageID: first)
        XCTAssertEqual(store.notebook(id: id)?.pages.count, 1)
        let added = try XCTUnwrap(store.addPage(notebookID: id, paper: .blank))
        store.deletePage(notebookID: id, pageID: first)
        XCTAssertEqual(store.notebook(id: id)?.pages.map(\.id), [added])
    }

    @MainActor
    func testUnreadableManifestRemainsUntouched() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = NotebookStore(rootURL: folder)
        let id = try XCTUnwrap(store.createNotebook(title: "Preserve", cover: .gold, paper: .blank))
        let manifestURL = folder.appendingPathComponent(id.uuidString).appendingPathComponent("notebook.json")
        let originalBytes = Data("unreadable manifest".utf8)
        try originalBytes.write(to: manifestURL)

        let reopened = NotebookStore(rootURL: folder)
        XCTAssertTrue(reopened.notebooks.isEmpty)
        XCTAssertNotNil(reopened.errorMessage)
        XCTAssertEqual(try Data(contentsOf: manifestURL), originalBytes)
    }

    @MainActor
    func testDamagedPDFBackgroundCannotProduceAnUnrestorableBackup() throws {
        let folder = temporaryFolder()
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("Source-\(UUID()).pdf")
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: source)
        }
        try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
            .writePDF(to: source) { $0.beginPage() }
        let store = NotebookStore(rootURL: folder)
        let id = try XCTUnwrap(store.importPDF(from: source))
        let pageID = try XCTUnwrap(store.notebook(id: id)?.pages.first?.id)
        let background = try XCTUnwrap(store.backgroundURL(notebookID: id, pageID: pageID))
        let damaged = Data("unreadable original PDF".utf8)
        try damaged.write(to: background)

        XCTAssertThrowsError(try store.exportBackup(notebookID: id))
        XCTAssertEqual(try Data(contentsOf: background), damaged)
        XCTAssertEqual(store.notebooks.count, 1)
    }

    @MainActor
    func testImportRejectsDirectoriesAndRemoteURLsWithoutCreatingNotebooks() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = NotebookStore(rootURL: folder)
        XCTAssertNil(store.importBackup(from: folder))
        XCTAssertNil(store.importPDF(from: folder))
        let remote = try XCTUnwrap(URL(string: "https://example.invalid/document.pdf"))
        XCTAssertNil(store.importPDF(from: remote))
        XCTAssertNil(store.importBackup(from: remote))
        XCTAssertTrue(store.notebooks.isEmpty)
        XCTAssertNotNil(store.errorMessage)
    }

    @MainActor
    func testBackupRejectsPathTraversalWithoutChangingExistingNotebook() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = NotebookStore(rootURL: folder)
        let id = try XCTUnwrap(store.createNotebook(title: "Original", cover: .sage, paper: .blank))
        let backup = try store.exportBackup(notebookID: id)
        defer { try? FileManager.default.removeItem(at: backup) }
        var archive = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: backup)) as? [String: Any])
        var notebook = try XCTUnwrap(archive["notebook"] as? [String: Any])
        var pages = try XCTUnwrap(notebook["pages"] as? [[String: Any]])
        pages[0]["backgroundFile"] = "../outside.pdf"
        notebook["pages"] = pages
        archive["notebook"] = notebook
        try JSONSerialization.data(withJSONObject: archive).write(to: backup)

        XCTAssertNil(store.importBackup(from: backup))
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(store.notebooks.map(\.id), [id])
        XCTAssertEqual(store.notebook(id: id)?.title, "Original")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("outside.pdf").path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: folder.path).contains { $0.hasPrefix(".staging-") })
    }

    private func temporaryFolder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("DrawBookTests-\(UUID())", isDirectory: true)
    }

    private func sampleDrawing() -> PKDrawing {
        let points = [CGPoint(x: 20, y: 30), CGPoint(x: 75, y: 90)].enumerated().map { index, location in
            PKStrokePoint(location: location, timeOffset: Double(index) * 0.1,
                          size: CGSize(width: 3, height: 3), opacity: 1,
                          force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let path = PKStrokePath(controlPoints: points, creationDate: Date())
        return PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black), path: path)])
    }
}

final class PageRendererTests: XCTestCase {
    @MainActor
    func testPNGContainsOpaquePaperGuidesAndInkAtExportResolution() throws {
        let url = try PageRenderer.png(drawing: redDrawing(), paper: .grid, backgroundURL: nil)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let image = try XCTUnwrap(UIImage(contentsOfFile: url.path))
        let pixels = try XCTUnwrap(image.cgImage)
        XCTAssertEqual(pixels.width, 1536)
        XCTAssertEqual(pixels.height, 2048)

        let colors = try colorCounts(image)
        XCTAssertGreaterThan(colors.red, 500, "Handwriting must be composited into the PNG.")
        XCTAssertGreaterThan(colors.guides, 2_000, "The grid must be included with the handwriting.")
        XCTAssertEqual(colors.transparent, 0, "Exported pages must have an opaque white paper background.")
        XCTAssertGreaterThan(colors.white, 1_000_000)
    }

    @MainActor
    func testPDFKeepsPageCountPaperAndPerPageInk() throws {
        let folder = testFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = NotebookStore(rootURL: folder)
        let id = try XCTUnwrap(store.createNotebook(title: "Export pages", cover: .sage, paper: .ruled))
        let first = try XCTUnwrap(store.notebook(id: id)?.pages.first)
        try store.saveDrawing(redDrawing(), notebookID: id, pageID: first.id)
        _ = try XCTUnwrap(store.addPage(notebookID: id, paper: .blank))

        let url = try PageRenderer.pdf(notebook: XCTUnwrap(store.notebook(id: id)), store: store)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(document.pageCount, 2)
        let written = try XCTUnwrap(document.page(at: 0))
        let empty = try XCTUnwrap(document.page(at: 1))
        XCTAssertEqual(written.bounds(for: .mediaBox).size, CGSize(width: 768, height: 1024))
        let firstColors = try colorCounts(written.thumbnail(of: CGSize(width: 768, height: 1024), for: .mediaBox))
        let secondColors = try colorCounts(empty.thumbnail(of: CGSize(width: 768, height: 1024), for: .mediaBox))
        XCTAssertGreaterThan(firstColors.red, 100)
        XCTAssertGreaterThan(firstColors.guides, 500)
        XCTAssertEqual(secondColors.red, 0, "Ink from page one must not leak into page two.")
        XCTAssertEqual(secondColors.guides, 0, "A blank page must not inherit another page's paper guides.")
    }

    @MainActor
    func testImportedPDFAndInkSurviveEditableBackupAndReexport() throws {
        let folder = testFolder()
        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent("Source-\(UUID()).pdf")
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: sourceURL)
        }
        let sourceBounds = CGRect(x: 0, y: 0, width: 384, height: 512)
        try UIGraphicsPDFRenderer(bounds: sourceBounds).writePDF(to: sourceURL) { output in
            for color in [UIColor.blue, UIColor.green] {
                output.beginPage()
                color.setFill()
                output.cgContext.fill(CGRect(x: 40, y: 40, width: 200, height: 80))
            }
        }
        let store = NotebookStore(rootURL: folder)
        let originalID = try XCTUnwrap(store.importPDF(from: sourceURL))
        let original = try XCTUnwrap(store.notebook(id: originalID))
        XCTAssertEqual(original.pages.count, 2)
        try store.saveDrawing(redDrawing(), notebookID: originalID, pageID: original.pages[0].id)
        let backup = try store.exportBackup(notebookID: originalID)
        defer { try? FileManager.default.removeItem(at: backup) }
        let restoredID = try XCTUnwrap(store.importBackup(from: backup))
        let restored = try XCTUnwrap(store.notebook(id: restoredID))
        XCTAssertNotEqual(restored.id, original.id)
        XCTAssertEqual(restored.pages.count, 2)
        XCTAssertEqual(try store.drawingForExport(notebookID: restoredID, pageID: restored.pages[0].id).strokes.count, 1)
        for index in original.pages.indices {
            let before = try XCTUnwrap(store.backgroundURL(notebookID: originalID, pageID: original.pages[index].id))
            let after = try XCTUnwrap(store.backgroundURL(notebookID: restoredID, pageID: restored.pages[index].id))
            XCTAssertEqual(try Data(contentsOf: before), try Data(contentsOf: after))
        }
        let output = try PageRenderer.pdf(notebook: restored, store: store)
        defer { try? FileManager.default.removeItem(at: output.deletingLastPathComponent()) }
        let document = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(document.pageCount, 2)
        let first = try XCTUnwrap(document.page(at: 0))
        let second = try XCTUnwrap(document.page(at: 1))
        let firstColors = try colorCounts(first.thumbnail(of: CGSize(width: 768, height: 1024), for: .mediaBox))
        let secondColors = try colorCounts(second.thumbnail(of: CGSize(width: 768, height: 1024), for: .mediaBox))
        XCTAssertGreaterThan(firstColors.blue, 500, "Imported PDF artwork must remain visible after backup and export.")
        XCTAssertGreaterThan(firstColors.red, 100, "Editable handwriting must remain over the PDF background.")
        XCTAssertGreaterThan(secondColors.green, 500)
        XCTAssertEqual(secondColors.red, 0)
    }

    @MainActor
    private func redDrawing() -> PKDrawing {
        let points = [CGPoint(x: 150, y: 400), CGPoint(x: 350, y: 400), CGPoint(x: 600, y: 400)]
            .enumerated().map { index, point in
                PKStrokePoint(location: point, timeOffset: Double(index) * 0.1,
                              size: CGSize(width: 16, height: 16), opacity: 1,
                              force: 1, azimuth: 0, altitude: .pi / 2)
            }
        let path = PKStrokePath(controlPoints: points, creationDate: Date())
        return PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .red), path: path)])
    }

    private func testFolder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("DrawBookRendererTests-\(UUID())", isDirectory: true)
    }

    private struct ColorCounts {
        var red = 0
        var blue = 0
        var green = 0
        var guides = 0
        var white = 0
        var transparent = 0
    }

    /// Normalize to a known RGBA layout rather than assuming a platform image's
    /// byte ordering. Counts avoid brittle single-pixel antialiasing assertions.
    @MainActor
    private func colorCounts(_ image: UIImage) throws -> ColorCounts {
        let source = try XCTUnwrap(image.cgImage)
        let width = source.width
        let height = source.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { memory in
            let context = try XCTUnwrap(CGContext(data: memory.baseAddress, width: width, height: height,
                                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                                  space: CGColorSpaceCreateDeviceRGB(),
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(source, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        }
        var result = ColorCounts()
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let red = Int(bytes[index]), green = Int(bytes[index + 1]), blue = Int(bytes[index + 2])
            if bytes[index + 3] < 255 { result.transparent += 1 }
            if red > 200 && green < 80 && blue < 80 { result.red += 1 }
            if blue > 200 && red < 80 && green < 80 { result.blue += 1 }
            if green > 200 && red < 80 && blue < 80 { result.green += 1 }
            if red > 250 && green > 250 && blue > 250 { result.white += 1 }
            if red > 150 && green > 150 && blue > 150 && red < 250 && green < 250 && blue < 250 {
                result.guides += 1
            }
        }
        return result
    }
}

final class DrawingCanvasTests: XCTestCase {
    @MainActor
    func testClearingInkCanBeUndoneAndRedone() throws {
        let ink = sampleInk()
        let host = PaperCanvasHost(pageID: UUID(), drawing: ink, paper: .ruled, backgroundURL: nil)
        let history = try XCTUnwrap(host.canvas.undoManager)
        history.removeAllActions()
        history.groupsByEvent = false
        var reportedStrokeCounts: [Int] = []
        host.onChange = { reportedStrokeCounts.append($0.strokes.count) }

        history.beginUndoGrouping()
        host.clearPage()
        history.endUndoGrouping()
        XCTAssertTrue(host.canvas.drawing.strokes.isEmpty)
        XCTAssertEqual(reportedStrokeCounts.last, 0)
        XCTAssertTrue(history.canUndo)

        history.undo()
        XCTAssertEqual(host.canvas.drawing.strokes.count, 1)
        XCTAssertEqual(host.canvas.drawing.bounds, ink.bounds)
        XCTAssertEqual(reportedStrokeCounts.last, 1, "Undo must notify autosave of the restored ink.")
        XCTAssertTrue(history.canRedo)
        history.redo()
        XCTAssertTrue(host.canvas.drawing.strokes.isEmpty)
        XCTAssertEqual(reportedStrokeCounts.last, 0)
    }

    @MainActor
    func testClearingPageRemovesTextAndShapesWithOneUndo() throws {
        let host = PaperCanvasHost(pageID: UUID(), drawing: sampleInk(), paper: .ruled, backgroundURL: nil)
        let shapes = [NoteShape(kind: .rectangle, frame: CGRect(x: 20, y: 30, width: 100, height: 80)),
                      NoteShape(kind: .text, frame: CGRect(x: 20, y: 200, width: 200, height: 30), text: "Title")]
        host.setShapes(shapes)
        let history = try XCTUnwrap(host.canvas.undoManager)
        history.removeAllActions()
        history.groupsByEvent = false
        var reportedShapes: [[NoteShape]] = []
        host.onShapesChange = { reportedShapes.append($0) }

        history.beginUndoGrouping()
        host.clearPage()
        history.endUndoGrouping()
        XCTAssertTrue(host.canvas.drawing.strokes.isEmpty)
        XCTAssertTrue(host.shapes.isEmpty)
        XCTAssertEqual(reportedShapes.last, [], "Clearing must notify autosave of the removed shapes.")

        history.undo()
        XCTAssertEqual(host.canvas.drawing.strokes.count, 1)
        XCTAssertEqual(host.shapes, shapes)
        XCTAssertFalse(history.canUndo, "Ink and shapes come back with a single undo.")

        // A page with only text or shapes (no ink) still clears.
        let textOnly = PaperCanvasHost(pageID: UUID(), drawing: PKDrawing(), paper: .ruled, backgroundURL: nil)
        textOnly.setShapes(shapes)
        textOnly.clearPage()
        XCTAssertTrue(textOnly.shapes.isEmpty)
    }

    @MainActor
    func testUndoHistoryDoesNotAffectAnotherPage() throws {
        let first = PaperCanvasHost(pageID: UUID(), drawing: sampleInk(), paper: .grid, backgroundURL: nil)
        let second = PaperCanvasHost(pageID: UUID(), drawing: sampleInk(), paper: .blank, backgroundURL: nil)
        let firstHistory = try XCTUnwrap(first.canvas.undoManager)
        let secondHistory = try XCTUnwrap(second.canvas.undoManager)
        XCTAssertFalse(firstHistory === secondHistory)
        for (host, history) in [(first, firstHistory), (second, secondHistory)] {
            history.removeAllActions()
            history.groupsByEvent = false
            history.beginUndoGrouping()
            host.clearPage()
            history.endUndoGrouping()
        }
        XCTAssertTrue(first.canvas.drawing.strokes.isEmpty)
        XCTAssertTrue(second.canvas.drawing.strokes.isEmpty)

        firstHistory.undo()
        XCTAssertEqual(first.canvas.drawing.strokes.count, 1)
        XCTAssertTrue(second.canvas.drawing.strokes.isEmpty, "Undo on page one must leave page two unchanged.")
        XCTAssertTrue(secondHistory.canUndo)
        secondHistory.undo()
        XCTAssertEqual(second.canvas.drawing.strokes.count, 1)
        XCTAssertEqual(first.canvas.drawing.strokes.count, 1)
    }

    @MainActor
    func testChangingPaperPreservesLiveInkAndUndoHistory() throws {
        let ink = sampleInk()
        let host = PaperCanvasHost(pageID: UUID(), drawing: ink, paper: .blank, backgroundURL: nil)
        let history = try XCTUnwrap(host.canvas.undoManager)
        history.removeAllActions()
        history.groupsByEvent = false
        history.beginUndoGrouping()
        host.clearPage()
        history.endUndoGrouping()

        host.setPaper(.dotted, backgroundURL: nil)
        XCTAssertTrue(host.canvas.drawing.strokes.isEmpty)
        XCTAssertTrue(history.canUndo, "Changing paper must retain the page's editing history.")
        history.undo()
        XCTAssertEqual(host.canvas.drawing.strokes.count, 1)
        XCTAssertEqual(host.canvas.drawing.bounds, ink.bounds)

        host.setPaper(.grid, backgroundURL: nil)
        XCTAssertEqual(host.canvas.drawing.strokes.count, 1)
        XCTAssertEqual(host.canvas.drawing.bounds, ink.bounds, "Paper changes must not reposition handwriting.")
    }

    @MainActor
    private func sampleInk() -> PKDrawing {
        let points = [CGPoint(x: 90, y: 110), CGPoint(x: 210, y: 230)].enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: Double(index) * 0.1,
                          size: CGSize(width: 8, height: 8), opacity: 1,
                          force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black),
                                           path: PKStrokePath(controlPoints: points, creationDate: Date()))])
    }
}
