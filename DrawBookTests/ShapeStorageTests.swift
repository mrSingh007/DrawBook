import XCTest
import UIKit
import PencilKit
import PDFKit
@testable import DrawBook

final class ShapeStorageTests: XCTestCase {
    func testPageFromEarlierVersionDefaultsToNoShapes() throws {
        let page = NotePage(paper: .grid)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(page)) as? [String: Any])
        json.removeValue(forKey: "shapes")
        let decoded = try JSONDecoder().decode(NotePage.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.id, page.id)
        XCTAssertEqual(decoded.paper, .grid)
        XCTAssertTrue(decoded.shapes.isEmpty)
    }

    @MainActor
    func testEditedShapesSurviveRelaunchBackupAndDuplication() throws {
        let root = testRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NotebookStore(rootURL: root)
        let id = try XCTUnwrap(store.createNotebook(title: "Geometry", cover: .sage, paper: .blank))
        let page = try XCTUnwrap(store.notebook(id: id)?.pages.first)
        var shape = NoteShape(kind: .rectangle, frame: CGRect(x: 120, y: 160, width: 200, height: 100))
        try store.saveShapes([shape], notebookID: id, pageID: page.id)
        shape.kind = .ellipse
        shape.frame.origin.x = 180
        shape.color = .red
        shape.lineWidth = 7
        shape.filled = true
        shape.rotation = 30
        shape = ShapeRenderer.erasing(shape, from: CGPoint(x: shape.frame.midX, y: shape.frame.midY),
                                      to: CGPoint(x: shape.frame.midX + 20, y: shape.frame.midY), width: 20)
        XCTAssertFalse(shape.erasureMasks.isEmpty)
        try store.saveShapes([shape], notebookID: id, pageID: page.id)

        let reopened = NotebookStore(rootURL: root)
        XCTAssertEqual(try reopened.shapes(notebookID: id, pageID: page.id), [shape])
        XCTAssertEqual(reopened.notebook(id: id)?.pages.first?.shapes, [shape])
        let duplicate = try XCTUnwrap(reopened.duplicateNotebook(id: id))
        XCTAssertEqual(try reopened.shapes(notebookID: duplicate, pageID: page.id), [shape])
        let backup = try reopened.exportBackup(notebookID: id)
        defer { try? FileManager.default.removeItem(at: backup) }
        let restored = try XCTUnwrap(reopened.importBackup(from: backup))
        XCTAssertNotEqual(restored, id)
        XCTAssertEqual(try reopened.shapes(notebookID: restored, pageID: page.id), [shape])
        XCTAssertEqual(try reopened.shapes(notebookID: id, pageID: page.id), [shape])
    }

    @MainActor
    func testFailedShapeSaveIsRetainedAndCanBeRetried() throws {
        let root = testRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NotebookStore(rootURL: root)
        let id = try XCTUnwrap(store.createNotebook(title: "Recover", cover: .blue, paper: .blank))
        let pageID = try XCTUnwrap(store.notebook(id: id)?.pages.first?.id)
        let folder = root.appendingPathComponent(id.uuidString)
        let movedFolder = root.appendingPathComponent("temporarily-moved")
        try FileManager.default.moveItem(at: folder, to: movedFolder)
        try Data("block writes".utf8).write(to: folder)
        let shape = NoteShape(kind: .arrow, frame: CGRect(x: 50, y: 70, width: 120, height: 0), color: .red)
        XCTAssertThrowsError(try store.saveShapes([shape], notebookID: id, pageID: pageID))
        XCTAssertTrue(store.hasUnsavedShapes(notebookID: id, pageID: pageID))
        XCTAssertEqual(try store.shapes(notebookID: id, pageID: pageID), [shape])
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.moveItem(at: movedFolder, to: folder)
        try store.saveShapes([shape], notebookID: id, pageID: pageID)
        XCTAssertFalse(store.hasUnsavedShapes(notebookID: id, pageID: pageID))
        XCTAssertEqual(try NotebookStore(rootURL: root).shapes(notebookID: id, pageID: pageID), [shape])
    }

    @MainActor
    func testInvalidShapeDoesNotReplacePreviouslySavedObjects() throws {
        let root = testRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NotebookStore(rootURL: root)
        let id = try XCTUnwrap(store.createNotebook(title: "Safe geometry", cover: .plum, paper: .blank))
        let pageID = try XCTUnwrap(store.notebook(id: id)?.pages.first?.id)
        let original = NoteShape(kind: .triangle, frame: CGRect(x: 50, y: 50, width: 80, height: 90))
        try store.saveShapes([original], notebookID: id, pageID: pageID)
        var invalid = original
        invalid.frame.origin.x = .nan
        XCTAssertThrowsError(try store.saveShapes([invalid], notebookID: id, pageID: pageID))
        invalid = original
        invalid.color.alpha = 2
        XCTAssertThrowsError(try store.saveShapes([invalid], notebookID: id, pageID: pageID))
        invalid = original
        invalid.frame.size.width = -10
        XCTAssertThrowsError(try store.saveShapes([invalid], notebookID: id, pageID: pageID))
        XCTAssertEqual(try store.shapes(notebookID: id, pageID: pageID), [original])
        XCTAssertFalse(store.hasUnsavedShapes(notebookID: id, pageID: pageID))
    }

    @MainActor
    func testMalformedBackupShapeIsRejectedWithoutChangingLibrary() throws {
        let root = testRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NotebookStore(rootURL: root)
        let id = try XCTUnwrap(store.createNotebook(title: "Original", cover: .sage, paper: .blank))
        let pageID = try XCTUnwrap(store.notebook(id: id)?.pages.first?.id)
        let original = NoteShape(kind: .ellipse, frame: CGRect(x: 80, y: 100, width: 180, height: 100), color: .red)
        try store.saveShapes([original], notebookID: id, pageID: pageID)
        let backup = try store.exportBackup(notebookID: id)
        defer { try? FileManager.default.removeItem(at: backup) }
        var archive = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: backup)) as? [String: Any])
        var notebook = try XCTUnwrap(archive["notebook"] as? [String: Any])
        var pages = try XCTUnwrap(notebook["pages"] as? [[String: Any]])
        var shapes = try XCTUnwrap(pages[0]["shapes"] as? [[String: Any]])
        var color = try XCTUnwrap(shapes[0]["color"] as? [String: Any])
        color["alpha"] = 2
        shapes[0]["color"] = color
        pages[0]["shapes"] = shapes
        notebook["pages"] = pages
        archive["notebook"] = notebook
        try JSONSerialization.data(withJSONObject: archive).write(to: backup)

        XCTAssertNil(store.importBackup(from: backup))
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(store.notebooks.count, 1)
        XCTAssertEqual(try store.shapes(notebookID: id, pageID: pageID), [original])
        XCTAssertEqual(try NotebookStore(rootURL: root).shapes(notebookID: id, pageID: pageID), [original])
    }

    @MainActor
    func testShapesAreIncludedInPNGAndPDFWithEmptyHandwriting() throws {
        let root = testRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NotebookStore(rootURL: root)
        let id = try XCTUnwrap(store.createNotebook(title: "Shape exports", cover: .gold, paper: .blank))
        let pageID = try XCTUnwrap(store.notebook(id: id)?.pages.first?.id)
        let shape = NoteShape(kind: .rectangle, frame: CGRect(x: 180, y: 210, width: 200, height: 120), color: .red, lineWidth: 4, filled: true, rotation: 20)
        try store.saveShapes([shape], notebookID: id, pageID: pageID)
        let png = try PageRenderer.png(drawing: PKDrawing(), paper: .blank, backgroundURL: nil, shapes: [shape])
        defer { try? FileManager.default.removeItem(at: png.deletingLastPathComponent()) }
        XCTAssertGreaterThan(try redPixelCount(XCTUnwrap(UIImage(contentsOfFile: png.path))), 50_000)
        let pdf = try PageRenderer.pdf(notebook: XCTUnwrap(store.notebook(id: id)), store: store)
        defer { try? FileManager.default.removeItem(at: pdf.deletingLastPathComponent()) }
        let document = try XCTUnwrap(PDFDocument(url: pdf))
        let page = try XCTUnwrap(document.page(at: 0))
        XCTAssertGreaterThan(try redPixelCount(page.thumbnail(of: CGSize(width: 768, height: 1024), for: .mediaBox)), 15_000)
        XCTAssertTrue(try store.drawingForExport(notebookID: id, pageID: pageID).strokes.isEmpty)
    }

    @MainActor
    func testRotationUsesShapeCenterAndSupportsHorizontalArrows() {
        let shape = NoteShape(kind: .rectangle, frame: CGRect(x: 100, y: 200, width: 200, height: 100), rotation: 90)
        let bounds = ShapeRenderer.path(for: shape).bounds
        XCTAssertEqual(bounds.midX, 200, accuracy: 0.001)
        XCTAssertEqual(bounds.midY, 250, accuracy: 0.001)
        XCTAssertEqual(bounds.width, 100, accuracy: 0.001)
        XCTAssertEqual(bounds.height, 200, accuracy: 0.001)
        let arrow = NoteShape(kind: .arrow, frame: CGRect(x: 50, y: 80, width: 200, height: 0))
        XCTAssertFalse(ShapeRenderer.path(for: arrow).isEmpty)
    }

    func testEarlierShapeDefaultsToNoErasedAreas() throws {
        let shape = NoteShape(kind: .rectangle, frame: CGRect(x: 10, y: 10, width: 100, height: 100))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(shape)) as? [String: Any])
        json.removeValue(forKey: "erasureMasks")
        let decoded = try JSONDecoder().decode(NoteShape.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded, shape)
    }

    @MainActor
    func testRubberErasesOnlyPaintAndSweepsBetweenEvents() {
        let outline = NoteShape(kind: .rectangle, frame: CGRect(x: 100, y: 100, width: 200, height: 200), lineWidth: 4)
        let untouched = ShapeRenderer.erasing(outline, from: CGPoint(x: 180, y: 180), to: CGPoint(x: 220, y: 220), width: 30)
        XCTAssertEqual(untouched, outline, "Rubber inside an unfilled shape should not change it")
        let erased = ShapeRenderer.erasing(outline, from: CGPoint(x: 50, y: 200), to: CGPoint(x: 350, y: 200), width: 30)
        XCTAssertFalse(erased.erasureMasks.isEmpty)
        XCTAssertFalse(ShapeRenderer.hitTest(CGPoint(x: 100, y: 200), shape: erased, tolerance: 0))
        XCTAssertFalse(ShapeRenderer.hitTest(CGPoint(x: 300, y: 200), shape: erased, tolerance: 0))
        XCTAssertTrue(ShapeRenderer.hitTest(CGPoint(x: 100, y: 150), shape: erased, tolerance: 0))
        XCTAssertEqual(ShapeRenderer.erasing(erased, from: CGPoint(x: 50, y: 200), to: CGPoint(x: 350, y: 200), width: 30), erased)
    }

    @MainActor
    func testErasedAreasFollowMoveResizeAndRotationIncludingFlatLines() {
        let original = NoteShape(kind: .rectangle, frame: CGRect(x: 100, y: 100, width: 200, height: 200), filled: true)
        var erased = ShapeRenderer.erasing(original, from: CGPoint(x: 200, y: 140), to: CGPoint(x: 200, y: 160), width: 30)
        erased.frame = CGRect(x: 300, y: 300, width: 400, height: 200)
        erased.rotation = 90
        XCTAssertFalse(ShapeRenderer.hitTest(CGPoint(x: 550, y: 400), shape: erased, tolerance: 0))
        XCTAssertTrue(ShapeRenderer.hitTest(CGPoint(x: 500, y: 400), shape: erased, tolerance: 0))
        let flat = NoteShape(kind: .line, frame: CGRect(x: 100, y: 100, width: 200, height: 0), lineWidth: 8)
        let flatErased = ShapeRenderer.erasing(flat, from: CGPoint(x: 200, y: 100), to: CGPoint(x: 200, y: 100), width: 30)
        XCTAssertFalse(ShapeRenderer.hitTest(CGPoint(x: 200, y: 100), shape: flatErased, tolerance: 0))
        XCTAssertTrue(ShapeRenderer.hitTest(CGPoint(x: 150, y: 100), shape: flatErased, tolerance: 0))
    }

    @MainActor
    func testErasedShapePNGAndPDFRevealLowerShape() throws {
        let root = testRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NotebookStore(rootURL: root)
        let id = try XCTUnwrap(store.createNotebook(title: "Rubber exports", cover: .sage, paper: .blank))
        let pageID = try XCTUnwrap(store.notebook(id: id)?.pages.first?.id)
        let lower = NoteShape(kind: .rectangle, frame: CGRect(x: 100, y: 100, width: 200, height: 200), filled: true)
        var upper = lower
        upper.id = UUID(); upper.color = .red
        upper = ShapeRenderer.erasing(upper, from: CGPoint(x: 200, y: 150), to: CGPoint(x: 200, y: 250), width: 30)
        let shapes = [lower, upper]
        try store.saveShapes(shapes, notebookID: id, pageID: pageID)
        let png = try PageRenderer.png(drawing: PKDrawing(), paper: .blank, backgroundURL: nil, shapes: shapes)
        defer { try? FileManager.default.removeItem(at: png.deletingLastPathComponent()) }
        let pngImage = try XCTUnwrap(UIImage(contentsOfFile: png.path))
        let pdf = try PageRenderer.pdf(notebook: XCTUnwrap(store.notebook(id: id)), store: store)
        defer { try? FileManager.default.removeItem(at: pdf.deletingLastPathComponent()) }
        let pdfPage = try XCTUnwrap(PDFDocument(url: pdf)?.page(at: 0))
        for image in [pngImage, pdfPage.thumbnail(of: PageRenderer.pageSize, for: .mediaBox)] {
            let hole = try pixel(image, atPagePoint: CGPoint(x: 200, y: 200))
            XCTAssertLessThan(hole[0], 40, "The hole must reveal the lower black shape, not clear it")
            XCTAssertLessThan(hole[1], 40)
            XCTAssertGreaterThan(hole[3], 240)
            let retained = try pixel(image, atPagePoint: CGPoint(x: 160, y: 200))
            XCTAssertGreaterThan(retained[0], 200)
            XCTAssertLessThan(retained[1], 80)
        }
    }

    @MainActor
    func testInvalidErasureMasksDoNotReplaceSavedShapes() throws {
        let root = testRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NotebookStore(rootURL: root)
        let id = try XCTUnwrap(store.createNotebook(title: "Safe rubber", cover: .sage, paper: .blank))
        let pageID = try XCTUnwrap(store.notebook(id: id)?.pages.first?.id)
        let original = NoteShape(kind: .rectangle, frame: CGRect(x: 10, y: 10, width: 100, height: 100))
        try store.saveShapes([original], notebookID: id, pageID: pageID)
        var invalid = original
        invalid.erasureMasks = [ShapeErasureMask(points: [.zero, CGPoint(x: 1, y: 1)])]
        XCTAssertThrowsError(try store.saveShapes([invalid], notebookID: id, pageID: pageID))
        invalid.erasureMasks = [ShapeErasureMask(points: [.zero, CGPoint(x: CGFloat.nan, y: 1), CGPoint(x: 0, y: 1)])]
        XCTAssertThrowsError(try store.saveShapes([invalid], notebookID: id, pageID: pageID))
        XCTAssertEqual(try store.shapes(notebookID: id, pageID: pageID), [original])
    }

    private func pixel(_ image: UIImage, atPagePoint point: CGPoint) throws -> [UInt8] {
        let source = try XCTUnwrap(image.cgImage)
        let x = point.x / 768 * CGFloat(source.width)
        let y = point.y / 1024 * CGFloat(source.height)
        let crop = try XCTUnwrap(source.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { memory in
            let context = try XCTUnwrap(CGContext(data: memory.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes
    }

    private func testRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("DrawBookShapeTests-\(UUID())", isDirectory: true)
    }

    private func redPixelCount(_ image: UIImage) throws -> Int {
        let source = try XCTUnwrap(image.cgImage)
        let width = source.width, height = source.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { memory in
            let context = try XCTUnwrap(CGContext(data: memory.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return stride(from: 0, to: bytes.count, by: 4).filter {
            bytes[$0] > 200 && bytes[$0 + 1] < 80 && bytes[$0 + 2] < 80
        }.count
    }
}
