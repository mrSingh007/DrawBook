import XCTest
import PencilKit
import Combine
@testable import DrawBook

final class ShapeCanvasTests: XCTestCase {
    @MainActor
    func testOldPageTeardownDoesNotPublishDeselectionAfterNewPageAttaches() async throws {
        let controller = CanvasController()
        let first = PaperCanvasHost(pageID: UUID(), drawing: PKDrawing(), paper: .blank, backgroundURL: nil)
        controller.attach(first)
        first.addShape(kind: .rectangle, color: .black, lineWidth: 3, filled: false)
        await drainPageTurnCallbacks()
        XCTAssertNotNil(controller.selectedShape)

        let second = PaperCanvasHost(pageID: UUID(), drawing: PKDrawing(), paper: .blank, backgroundURL: nil)
        second.addShape(kind: .ellipse, color: .red, lineWidth: 3, filled: true)
        let secondShape = try XCTUnwrap(second.selectedShape)
        var selections: [UUID?] = []
        let observation = controller.$selectedShape.dropFirst().sink { selections.append($0?.id) }

        // SwiftUI can replace the native view before its deferred cleanup runs.
        DrawingCanvas.dismantleUIView(first, coordinator: ())
        controller.attach(second)
        await drainPageTurnCallbacks()

        XCTAssertEqual(controller.selectedShape?.id, secondShape.id)
        XCTAssertFalse(selections.contains(where: { $0 == nil }),
                       "Old-page cleanup must not briefly hide the new page's shape controls")
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testShapeChangesAreEditableAndUndoableWithoutChangingInk() throws {
        let ink = sampleInk()
        let host = PaperCanvasHost(pageID: UUID(), drawing: ink, paper: .blank, backgroundURL: nil)
        let undo = try XCTUnwrap(host.canvas.undoManager)
        undo.removeAllActions()
        undo.groupsByEvent = false
        var changedShapes: [[NoteShape]] = []
        var inkCallbacks = 0
        host.onShapesChange = { changedShapes.append($0) }
        host.onChange = { _ in inkCallbacks += 1 }
        undo.beginUndoGrouping()
        host.addShape(kind: .rectangle, color: .red, lineWidth: 5, filled: false)
        undo.endUndoGrouping()
        let original = try XCTUnwrap(host.selectedShape)
        undo.beginUndoGrouping()
        host.updateSelectedShape(kind: .ellipse, color: .black, lineWidth: 12, filled: true, rotation: 45)
        undo.endUndoGrouping()
        let edited = try XCTUnwrap(host.selectedShape)
        XCTAssertEqual(edited.id, original.id)
        XCTAssertEqual(edited.kind, .ellipse)
        XCTAssertEqual(edited.lineWidth, 12)
        XCTAssertEqual(edited.rotation, 45)
        XCTAssertTrue(edited.filled)
        XCTAssertEqual(edited.frame, original.frame)
        undo.undo()
        XCTAssertEqual(host.shapes, [original])
        undo.redo()
        XCTAssertEqual(host.shapes, [edited])
        XCTAssertEqual(changedShapes.last, [edited])
        XCTAssertEqual(inkCallbacks, 0)
        XCTAssertEqual(host.canvas.drawing.strokes.count, ink.strokes.count)
        XCTAssertEqual(host.canvas.drawing.bounds, ink.bounds)
    }

    @MainActor
    func testDuplicateAndDeleteShapesKeepIndependentIdentityAndUndo() throws {
        let host = PaperCanvasHost(pageID: UUID(), drawing: PKDrawing(), paper: .blank, backgroundURL: nil)
        let undo = try XCTUnwrap(host.canvas.undoManager)
        undo.removeAllActions()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        host.addShape(kind: .triangle, color: .red, lineWidth: 4, filled: true)
        undo.endUndoGrouping()
        let first = try XCTUnwrap(host.selectedShape)
        undo.beginUndoGrouping()
        host.duplicateSelectedShape()
        undo.endUndoGrouping()
        let second = try XCTUnwrap(host.selectedShape)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(host.shapes.count, 2)
        XCTAssertEqual(second.kind, first.kind)
        XCTAssertEqual(second.color, first.color)
        undo.beginUndoGrouping()
        host.deleteSelectedShape()
        undo.endUndoGrouping()
        XCTAssertEqual(host.shapes.map(\.id), [first.id])
        undo.undo()
        XCTAssertEqual(host.shapes.map(\.id), [first.id, second.id])
        undo.undo()
        XCTAssertEqual(host.shapes.map(\.id), [first.id])
    }

    @MainActor
    func testLaserExpiresWithoutPersistingInkShapesOrUndoActions() throws {
        let ink = sampleInk()
        let shape = NoteShape(kind: .rectangle, frame: CGRect(x: 40, y: 50, width: 120, height: 80))
        let host = PaperCanvasHost(pageID: UUID(), drawing: ink, paper: .dotted, backgroundURL: nil, shapes: [shape])
        let undo = try XCTUnwrap(host.canvas.undoManager)
        undo.removeAllActions()
        var inkChanges = 0, shapeChanges = 0
        host.onChange = { _ in inkChanges += 1 }
        host.onShapesChange = { _ in shapeChanges += 1 }
        host.configure(mode: .laser, fingerDrawing: true)
        host.beginLaser(at: CGPoint(x: 100, y: 100), time: 100)
        host.appendLaser(at: CGPoint(x: 200, y: 200))
        host.endLaser(time: 100)
        XCTAssertEqual(host.visibleLaserTrailCount, 1)
        host.expireLaserTrails(at: 102.9)
        XCTAssertEqual(host.visibleLaserTrailCount, 1)
        host.expireLaserTrails(at: 103)
        XCTAssertEqual(host.visibleLaserTrailCount, 0)
        XCTAssertEqual(host.canvas.drawing.bounds, ink.bounds)
        XCTAssertEqual(host.canvas.drawing.strokes.count, 1)
        XCTAssertEqual(host.shapes, [shape])
        XCTAssertEqual(inkChanges, 0)
        XCTAssertEqual(shapeChanges, 0)
        XCTAssertFalse(undo.canUndo)
    }

    @MainActor
    func testLeavingLaserModeDiscardsActiveTrailAndReenablesInk() {
        let host = PaperCanvasHost(pageID: UUID(), drawing: PKDrawing(), paper: .blank, backgroundURL: nil)
        host.configure(mode: .laser, fingerDrawing: false)
        host.beginLaser(at: CGPoint(x: 50, y: 80))
        XCTAssertEqual(host.visibleLaserTrailCount, 1)
        XCTAssertFalse(host.canvas.drawingGestureRecognizer.isEnabled)
        host.configure(mode: .ink, fingerDrawing: false)
        XCTAssertEqual(host.visibleLaserTrailCount, 0)
        XCTAssertTrue(host.canvas.drawingGestureRecognizer.isEnabled)
        XCTAssertEqual(host.canvas.drawingPolicy, .pencilOnly)
    }

    @MainActor
    func testRubberKeepsNativeDrawingRecognizerEnabledAtConfiguredDiameter() throws {
        let host = rubberHost(width: 48)
        let tool = try XCTUnwrap(host.canvas.tool as? PKEraserTool)
        XCTAssertEqual(tool.eraserType, .fixedWidthBitmap)
        XCTAssertEqual(tool.width, 48, accuracy: 0.001)
        XCTAssertTrue(host.canvas.drawingGestureRecognizer.isEnabled,
                      "PencilKit must process eraser touches directly for native low-latency ink")
        XCTAssertFalse(host.canvas.undoManager === host.canvas.historyUndoManager,
                       "Native rubber registrations must not create duplicate app undo steps")
        host.applyTool(PKInkingTool(.pen, color: .black, width: 3))
        XCTAssertFalse(host.canvas.undoManager === host.canvas.historyUndoManager,
                       "Late eraser callbacks retain their scratch manager until the next tool begins")
        host.canvasViewDidBeginUsingTool(host.canvas)
        XCTAssertTrue(host.canvas.undoManager === host.canvas.historyUndoManager)
    }

    @MainActor
    func testCompanionRubberNeverRebuildsNativeInkForRapidSamples() throws {
        let host = rubberHost(width: 24)
        let original = host.canvas.drawing.dataRepresentation()
        var published = 0
        host.onChange = { _ in published += 1 }
        host.beginErasing(at: CGPoint(x: 80, y: 150))
        for index in 1...500 {
            host.continueErasing(at: CGPoint(x: 80 + Double(index) * 0.3, y: 150))
        }
        host.flushErasingFrame()
        XCTAssertEqual(host.canvas.drawing.dataRepresentation(), original)
        XCTAssertNil(host.canvas.drawing.strokes.first?.mask)
        XCTAssertEqual(published, 0)
        host.finishErasing()
        XCTAssertEqual(host.canvas.drawing.dataRepresentation(), original)
        XCTAssertFalse(host.canvas.historyUndoManager.canUndo,
                       "A companion gesture without native or shape changes is a no-op")
    }

    @MainActor
    func testRubberUndoRestoresNativeInkAndShapeTogether() throws {
        let shape = NoteShape(kind: .rectangle, frame: CGRect(x: 100, y: 100, width: 100, height: 100), filled: true)
        let host = rubberHost(width: 24, shapes: [shape])
        let undo = host.canvas.historyUndoManager
        undo.removeAllActions()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        host.beginErasing(at: CGPoint(x: 150, y: 130))
        host.continueErasing(at: CGPoint(x: 150, y: 170))
        // Simulate PencilKit publishing a native bitmap-erasure result. The
        // companion recognizer must preserve it and add only vector erasures.
        host.canvas.drawing = PKDrawing()
        host.canvasViewDrawingDidChange(host.canvas)
        host.finishErasing()
        undo.endUndoGrouping()
        let erasedShapes = host.shapes
        XCTAssertNotEqual(erasedShapes, [shape])
        XCTAssertTrue(host.canvas.drawing.strokes.isEmpty)
        host.canvas.undoManager?.undo()
        XCTAssertEqual(host.shapes, [shape])
        XCTAssertEqual(host.canvas.drawing.strokes.count, 1)
        XCTAssertFalse(undo.canUndo)
        host.canvas.undoManager?.redo()
        XCTAssertEqual(host.shapes, erasedShapes)
        XCTAssertTrue(host.canvas.drawing.strokes.isEmpty)
        XCTAssertFalse(undo.canRedo)
    }

    @MainActor
    func testNativeEraserResultAfterTouchLiftIsIncludedInOneUndoAction() throws {
        let shape = NoteShape(kind: .rectangle, frame: CGRect(x: 100, y: 100, width: 100, height: 100), filled: true)
        let host = rubberHost(width: 24, shapes: [shape])
        let undo = host.canvas.historyUndoManager
        undo.removeAllActions()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        host.beginErasing(at: CGPoint(x: 150, y: 130))
        host.continueErasing(at: CGPoint(x: 150, y: 170))
        host.finishErasing()
        // PencilKit documents that drawingDidChange can follow tool-end.
        host.canvas.drawing = PKDrawing()
        host.canvasViewDrawingDidChange(host.canvas)
        undo.endUndoGrouping()
        let erasedShapes = host.shapes
        undo.undo()
        XCTAssertEqual(host.shapes, [shape])
        XCTAssertEqual(host.canvas.drawing.strokes.count, 1)
        XCTAssertFalse(undo.canUndo)
        undo.redo()
        XCTAssertEqual(host.shapes, erasedShapes)
        XCTAssertTrue(host.canvas.drawing.strokes.isEmpty,
                      "Redo must capture the final native drawing, not an earlier lift snapshot")
        XCTAssertFalse(undo.canRedo)
    }

    @MainActor
    func testDelayedInkOnlyErasureIsUndoableWithoutShapeChanges() {
        let host = rubberHost(width: 24)
        let undo = host.canvas.historyUndoManager
        undo.removeAllActions()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        host.beginErasing(at: CGPoint(x: 150, y: 150))
        host.finishErasing()
        host.canvas.drawing = PKDrawing()
        host.canvasViewDrawingDidChange(host.canvas)
        undo.endUndoGrouping()
        XCTAssertTrue(undo.canUndo)
        undo.undo()
        XCTAssertEqual(host.canvas.drawing.strokes.count, 1)
        XCTAssertFalse(undo.canUndo)
        undo.redo()
        XCTAssertTrue(host.canvas.drawing.strokes.isEmpty)
    }

    @MainActor
    func testRubberDiameterChangesShapeFootprint() throws {
        let shape = NoteShape(kind: .rectangle, frame: CGRect(x: 100, y: 100, width: 100, height: 100), filled: true)
        let small = rubberHost(width: 8, shapes: [shape])
        small.beginErasing(at: CGPoint(x: 150, y: 150))
        small.finishErasing()
        let large = rubberHost(width: 60, shapes: [shape])
        large.beginErasing(at: CGPoint(x: 150, y: 150))
        large.finishErasing()
        XCTAssertTrue(ShapeRenderer.hitTest(CGPoint(x: 170, y: 150), shape: try XCTUnwrap(small.shapes.first), tolerance: 0))
        XCTAssertFalse(ShapeRenderer.hitTest(CGPoint(x: 170, y: 150), shape: try XCTUnwrap(large.shapes.first), tolerance: 0))
    }

    @MainActor
    func testBatchedRubberPreservesShapeCornersWithoutErasingShortcut() throws {
        let shape = NoteShape(kind: .rectangle, frame: CGRect(x: 50, y: 50, width: 200, height: 200), filled: true)
        let host = rubberHost(width: 16, shapes: [shape])
        let originalInk = host.canvas.drawing.dataRepresentation()
        host.beginErasing(at: CGPoint(x: 80, y: 90))
        host.continueErasing(at: CGPoint(x: 80, y: 210))
        host.continueErasing(at: CGPoint(x: 220, y: 210))
        host.continueErasing(at: CGPoint(x: 220, y: 90))
        host.flushErasingFrame()
        let erased = try XCTUnwrap(host.shapes.first)
        XCTAssertFalse(ShapeRenderer.hitTest(CGPoint(x: 80, y: 150), shape: erased, tolerance: 0))
        XCTAssertFalse(ShapeRenderer.hitTest(CGPoint(x: 150, y: 210), shape: erased, tolerance: 0))
        XCTAssertFalse(ShapeRenderer.hitTest(CGPoint(x: 220, y: 150), shape: erased, tolerance: 0))
        XCTAssertTrue(ShapeRenderer.hitTest(CGPoint(x: 150, y: 90), shape: erased, tolerance: 0))
        XCTAssertTrue(ShapeRenderer.hitTest(CGPoint(x: 150, y: 150), shape: erased, tolerance: 0))
        host.finishErasing()
        XCTAssertEqual(host.canvas.drawing.dataRepresentation(), originalInk)
    }

    @MainActor
    func testRubberLiftFlushesFinalShapeSamplesBeforeUndoRegistration() throws {
        let shape = NoteShape(kind: .rectangle, frame: CGRect(x: 100, y: 100, width: 100, height: 100), filled: true)
        let host = rubberHost(width: 20, shapes: [shape])
        let undo = host.canvas.historyUndoManager
        undo.removeAllActions()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        host.beginErasing(at: CGPoint(x: 150, y: 100))
        host.continueErasing(at: CGPoint(x: 150, y: 200))
        XCTAssertEqual(host.shapes, [shape])
        host.finishErasing()
        undo.endUndoGrouping()
        let erased = try XCTUnwrap(host.shapes.first)
        XCTAssertFalse(ShapeRenderer.hitTest(CGPoint(x: 150, y: 150), shape: erased, tolerance: 0))
        undo.undo()
        XCTAssertEqual(host.shapes, [shape])
        XCTAssertFalse(undo.canUndo)
        undo.redo()
        XCTAssertEqual(host.shapes, [erased])
    }

    @MainActor
    func testCancellingRubberRestoresNativeInkAndShapesAndDiscardsPendingSamples() throws {
        let shape = NoteShape(kind: .rectangle, frame: CGRect(x: 100, y: 100, width: 100, height: 100), filled: true)
        let host = rubberHost(width: 24, shapes: [shape])
        let undo = host.canvas.historyUndoManager
        undo.removeAllActions()
        host.beginErasing(at: CGPoint(x: 130, y: 100))
        host.continueErasing(at: CGPoint(x: 130, y: 200))
        host.canvas.drawing = PKDrawing()
        host.canvasViewDrawingDidChange(host.canvas)
        host.flushErasingFrame()
        XCTAssertNotEqual(host.shapes, [shape])
        host.continueErasing(at: CGPoint(x: 180, y: 200))
        host.finishErasing(cancelled: true)
        XCTAssertEqual(host.shapes, [shape])
        XCTAssertEqual(host.canvas.drawing.strokes.count, 1)
        XCTAssertFalse(undo.canUndo)
        host.flushErasingFrame()
        XCTAssertEqual(host.shapes, [shape])
    }

    @MainActor
    func testDensePageCompanionSamplesLeaveNativeStrokeDataUnchanged() throws {
        let strokes = (0..<200).map { row -> PKStroke in
            let y = CGFloat(60 + row * 3)
            let points = [40.0, 220, 400, 580, 720].enumerated().map { index, x in
                PKStrokePoint(location: CGPoint(x: x, y: y), timeOffset: Double(index) * 0.1,
                              size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }
            return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: Date()))
        }
        let host = PaperCanvasHost(pageID: UUID(), drawing: PKDrawing(strokes: strokes), paper: .blank, backgroundURL: nil)
        host.configure(mode: .ink, fingerDrawing: true)
        host.applyTool(PKEraserTool(.fixedWidthBitmap, width: 24))
        let original = host.canvas.drawing.dataRepresentation()
        host.beginErasing(at: CGPoint(x: 100, y: 150))
        for index in 1...500 { host.continueErasing(at: CGPoint(x: 100 + Double(index), y: 150)) }
        host.flushErasingFrame()
        host.finishErasing()
        XCTAssertEqual(host.canvas.drawing.dataRepresentation(), original)
        XCTAssertEqual(host.canvas.drawing.strokes.count, strokes.count)
        XCTAssertTrue(host.canvas.drawing.strokes.allSatisfy { $0.mask == nil })
    }

    @MainActor
    func testRubberCanvasCoordinatesApplyScrollOffsetOnlyOnceAcrossZoomLevels() {
        let host = rubberHost(width: 24)
        host.frame = CGRect(x: 0, y: 0, width: 640, height: 900)
        host.setNeedsLayout()
        host.layoutIfNeeded()
        let document = CGPoint(x: 220, y: 300)
        for zoom: CGFloat in [1, 2, 3] {
            host.canvas.zoomScale = zoom
            for offset in [CGPoint(x: -16, y: -16), CGPoint(x: 70, y: 180), CGPoint(x: 210, y: 420)] {
                host.canvas.contentOffset = offset
                let hostPoint = CGPoint(x: document.x * zoom - offset.x,
                                        y: document.y * zoom - offset.y)
                // UIScrollView location(in:) includes its bounds origin. This
                // conversion reflects a stylus location reported in the canvas.
                let canvasPoint = host.canvas.convert(hostPoint, from: host)
                let actual = host.documentPoint(fromCanvasPoint: canvasPoint)
                XCTAssertEqual(actual.x, document.x, accuracy: 0.001)
                XCTAssertEqual(actual.y, document.y, accuracy: 0.001)
            }
        }
    }

    @MainActor
    func testCachedShapeErasurePreviewMatchesSavedRendering() throws {
        let lower = NoteShape(kind: .rectangle, frame: CGRect(x: 40, y: 40, width: 220, height: 220), color: .black, filled: true)
        let shape = NoteShape(kind: .ellipse, frame: CGRect(x: 60, y: 60, width: 180, height: 180),
                              color: RGBAColor(red: 1, green: 0, blue: 0, alpha: 0.4), filled: true)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 150, y: 40)); path.addLine(to: CGPoint(x: 150, y: 260))
        let cut = path.copy(strokingWithWidth: 24, lineCap: .round, lineJoin: .round, miterLimit: 10)
        var session = ShapeRenderer.ErasureSession()
        let erased = session.erasing(shape, footprint: cut)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 300), format: format)
        let live = renderer.image { ShapeRenderer.draw([lower, erased], in: $0.cgContext, erasureSession: session) }
        let saved = renderer.image { ShapeRenderer.draw([lower, erased], in: $0.cgContext) }
        let liveImage = try XCTUnwrap(live.cgImage), savedImage = try XCTUnwrap(saved.cgImage)
        let liveBytes = try XCTUnwrap(liveImage.dataProvider?.data) as Data
        let savedBytes = try XCTUnwrap(savedImage.dataProvider?.data) as Data
        for point in [CGPoint(x: 150, y: 150), CGPoint(x: 100, y: 150), CGPoint(x: 200, y: 150), CGPoint(x: 50, y: 50)] {
            let liveOffset = Int(point.y) * liveImage.bytesPerRow + Int(point.x) * 4
            let savedOffset = Int(point.y) * savedImage.bytesPerRow + Int(point.x) * 4
            for channel in 0..<4 {
                XCTAssertEqual(Int(liveBytes[liveOffset + channel]), Int(savedBytes[savedOffset + channel]), accuracy: 1)
            }
        }
    }

    @MainActor
    func testPageEdgeNavigationIgnoresNormalScrollAndProgrammaticBounce() async {
        var turns: [PageTurnDirection] = []
        let host = pageNavigationHost { turns.append($0) }
        let edges = pageScrollEdges(host)
        // Programmatic scrolls and bounce/deceleration cannot turn pages.
        setPageScrollOffset(host, y: edges.bottom + 80)
        host.scrollViewDidEndDragging(host.canvas, willDecelerate: false)
        setPageScrollOffset(host, y: edges.top - 80)
        host.scrollViewDidEndDragging(host.canvas, willDecelerate: false)
        setPageScrollOffset(host, y: edges.top)
        host.scrollViewWillBeginDragging(host.canvas)
        setPageScrollOffset(host, y: (edges.top + edges.bottom) / 2)
        host.scrollViewDidEndDragging(host.canvas, willDecelerate: true)
        setPageScrollOffset(host, y: edges.bottom + 80)
        await drainPageTurnCallbacks()
        XCTAssertTrue(turns.isEmpty)
    }

    @MainActor
    func testPageEdgePullTurnsNextOrPreviousExactlyOnceAfterRelease() async {
        var turns: [PageTurnDirection] = []
        let host = pageNavigationHost { turns.append($0) }
        let edges = pageScrollEdges(host)
        setPageScrollOffset(host, y: edges.bottom)
        host.scrollViewWillBeginDragging(host.canvas)
        setPageScrollOffset(host, y: edges.bottom + 64)
        XCTAssertTrue(turns.isEmpty, "Replacing the page must wait until the drag releases")
        host.scrollViewDidEndDragging(host.canvas, willDecelerate: true)
        host.scrollViewDidEndDragging(host.canvas, willDecelerate: false)
        await drainPageTurnCallbacks()
        XCTAssertEqual(turns, [.next])
        setPageScrollOffset(host, y: edges.top)
        host.scrollViewWillBeginDragging(host.canvas)
        setPageScrollOffset(host, y: edges.top - 64)
        host.scrollViewDidEndDragging(host.canvas, willDecelerate: false)
        await drainPageTurnCallbacks()
        XCTAssertEqual(turns, [.next, .previous])
    }

    @MainActor
    func testPageEdgePullDoesNotNavigateBeyondFirstOrLastPage() async {
        var turns: [PageTurnDirection] = []
        let first = pageNavigationHost(canPrevious: false, canNext: true) { turns.append($0) }
        let firstEdges = pageScrollEdges(first)
        setPageScrollOffset(first, y: firstEdges.top)
        first.scrollViewWillBeginDragging(first.canvas)
        setPageScrollOffset(first, y: firstEdges.top - 80)
        first.scrollViewDidEndDragging(first.canvas, willDecelerate: false)
        let last = pageNavigationHost(canPrevious: true, canNext: false) { turns.append($0) }
        let lastEdges = pageScrollEdges(last)
        setPageScrollOffset(last, y: lastEdges.bottom)
        last.scrollViewWillBeginDragging(last.canvas)
        setPageScrollOffset(last, y: lastEdges.bottom + 80)
        last.scrollViewDidEndDragging(last.canvas, willDecelerate: false)
        await drainPageTurnCallbacks()
        XCTAssertTrue(turns.isEmpty)
    }

    @MainActor
    func testReversingPageEdgePullCancelsTheTurn() async {
        var turns: [PageTurnDirection] = []
        let host = pageNavigationHost { turns.append($0) }
        let edge = pageScrollEdges(host).bottom
        setPageScrollOffset(host, y: edge)
        host.scrollViewWillBeginDragging(host.canvas)
        setPageScrollOffset(host, y: edge + 70)
        setPageScrollOffset(host, y: edge + 8)
        host.scrollViewDidEndDragging(host.canvas, willDecelerate: false)
        await drainPageTurnCallbacks()
        XCTAssertTrue(turns.isEmpty)
    }

    @MainActor
    func testZoomingOrUsingDrawingToolCannotTurnPages() async {
        var turns: [PageTurnDirection] = []
        let host = pageNavigationHost { turns.append($0) }
        var edge = pageScrollEdges(host).bottom
        setPageScrollOffset(host, y: edge)
        host.scrollViewWillBeginDragging(host.canvas)
        host.canvas.zoomScale *= 1.5
        host.scrollViewDidZoom(host.canvas)
        edge = pageScrollEdges(host).bottom
        setPageScrollOffset(host, y: edge + 80)
        host.scrollViewDidEndDragging(host.canvas, willDecelerate: false)
        setPageScrollOffset(host, y: edge)
        host.canvasViewDidBeginUsingTool(host.canvas)
        host.scrollViewWillBeginDragging(host.canvas)
        setPageScrollOffset(host, y: edge + 80)
        host.scrollViewDidEndDragging(host.canvas, willDecelerate: false)
        host.canvasViewDidEndUsingTool(host.canvas)
        await drainPageTurnCallbacks()
        XCTAssertTrue(turns.isEmpty)
    }

    @MainActor
    func testPreviousPageEntryStartsAtBottomOnlyOnInitialLayout() {
        let host = pageNavigationHost(entryPosition: .bottom) { _ in }
        let edges = pageScrollEdges(host)
        XCTAssertGreaterThan(edges.bottom, edges.top)
        // UIScrollView rounds resting offsets to the display's pixel grid.
        XCTAssertEqual(host.canvas.contentOffset.y, edges.bottom, accuracy: 0.5)
        setPageScrollOffset(host, y: edges.top)
        host.setNeedsLayout()
        host.layoutIfNeeded()
        XCTAssertEqual(host.canvas.contentOffset.y, edges.top, accuracy: 0.01,
                       "Ordinary layout updates must not jump back to the entry position")
    }

    @MainActor
    private func pageNavigationHost(canPrevious: Bool = true, canNext: Bool = true,
                                    entryPosition: PageEntryPosition = .top,
                                    onTurn: @escaping (PageTurnDirection) -> Void) -> PaperCanvasHost {
        let host = PaperCanvasHost(pageID: UUID(), drawing: PKDrawing(), paper: .blank, backgroundURL: nil)
        host.configurePageNavigation(canGoPrevious: canPrevious, canGoNext: canNext,
                                     entryPosition: entryPosition, onTurn: onTurn)
        host.frame = CGRect(x: 0, y: 0, width: 640, height: 700)
        host.setNeedsLayout()
        host.layoutIfNeeded()
        return host
    }

    @MainActor
    private func pageScrollEdges(_ host: PaperCanvasHost) -> (top: CGFloat, bottom: CGFloat) {
        let top = -host.canvas.adjustedContentInset.top
        let bottom = max(top, PageRenderer.pageSize.height * host.canvas.zoomScale - host.canvas.bounds.height + host.canvas.adjustedContentInset.bottom)
        return (top, bottom)
    }

    @MainActor
    private func setPageScrollOffset(_ host: PaperCanvasHost, y: CGFloat) {
        host.canvas.contentOffset = CGPoint(x: host.canvas.contentOffset.x, y: y)
        host.scrollViewDidScroll(host.canvas)
    }

    @MainActor
    private func drainPageTurnCallbacks() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @MainActor
    private func rubberHost(width: CGFloat, shapes: [NoteShape] = []) -> PaperCanvasHost {
        let points = [40.0, 100, 150, 200, 260].enumerated().map { index, x in
            PKStrokePoint(location: CGPoint(x: x, y: 150), timeOffset: Double(index) * 0.1,
                          size: CGSize(width: 8, height: 8), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let stroke = PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: Date()))
        let host = PaperCanvasHost(pageID: UUID(), drawing: PKDrawing(strokes: [stroke]), paper: .blank, backgroundURL: nil, shapes: shapes)
        host.configure(mode: .ink, fingerDrawing: true)
        host.applyTool(PKEraserTool(.fixedWidthBitmap, width: width))
        return host
    }

    @MainActor
    private func sampleInk() -> PKDrawing {
        let points = [CGPoint(x: 90, y: 110), CGPoint(x: 210, y: 230)].enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: Double(index) * 0.1, size: CGSize(width: 8, height: 8), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: Date()))])
    }
}
