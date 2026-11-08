import PencilKit
import XCTest
@testable import DrawBook

@MainActor
final class AIPageStateTests: XCTestCase {
    func testDocumentDescribesObjectsInkAndHandwriting() throws {
        let box = NoteShape(kind: .rectangle, frame: CGRect(x: 20, y: 30, width: 100, height: 80))
        let strokes = [stroke([CGPoint(x: 40, y: 100), CGPoint(x: 80, y: 100)]),
                       stroke([CGPoint(x: 90, y: 100), CGPoint(x: 120, y: 100)], ink: .marker, color: .yellow),
                       stroke([CGPoint(x: 300, y: 500), CGPoint(x: 400, y: 600)])]
        let line = HandwritingLine(text: "Hi", bounds: CGRect(x: 40, y: 90, width: 80, height: 20), confidence: 0.9,
                                   strokeIndices: [0, 1], words: [])
        let state = AIPageState(content: AIPageContent(drawing: PKDrawing(strokes: strokes), shapes: [box]),
                                handwriting: [line], info: .init(), keys: AIPageKeys(), selectedShapeID: box.id)
        let document = state.document(points: .sketches)

        XCTAssertEqual(document["selection"], "rect1")
        XCTAssertEqual(document["objects"]?["rect1"]?["kind"], "rectangle")
        XCTAssertEqual(document["handwriting"]?["h1"]?["text"], "Hi")
        XCTAssertEqual(document["handwriting"]?["h1"]?["strokes"], ["s1", "s2"])
        XCTAssertEqual(document["ink"]?["s2"]?["brush"], "marker")
        XCTAssertEqual(document["ink"]?["s2"]?["color"], "#FFFF00")
        XCTAssertNil(document["ink"]?["s1"]?["points"], "Handwriting strokes are described by text")
        XCTAssertEqual(document["ink"]?["s3"]?["points"]?.arrayValue?.first, [300, 500])
        XCTAssertNotNil(state.document(points: .all)["ink"]?["s1"]?["points"])
    }

    func testPatchAddsTextAndRemovesHandwritingAsOneRevision() throws {
        let strokes = [stroke([CGPoint(x: 40, y: 100), CGPoint(x: 80, y: 100)]),
                       stroke([CGPoint(x: 300, y: 500), CGPoint(x: 400, y: 600)])]
        let line = HandwritingLine(text: "Hi", bounds: .zero, confidence: 1, strokeIndices: [0], words: [])
        let state = AIPageState(content: AIPageContent(drawing: PKDrawing(strokes: strokes), shapes: []),
                                handwriting: [line], info: .init(), keys: AIPageKeys(), selectedShapeID: nil)
        let outcome = state.execute(call("apply_patch", #"""
        {"base_revision":0,"operations":[
          {"op":"remove","path":"/handwriting/h1"},
          {"op":"add","path":"/objects/title","value":{"kind":"text","text":"Hi","x":40,"y":80,"width":200,"fontSize":28}}
        ]}
        """#))
        let response = try JSONValue(parsing: outcome.result)

        XCTAssertEqual(response["ok"], true, outcome.result)
        XCTAssertEqual(state.revision, 1)
        XCTAssertEqual(state.content.drawing.strokes.count, 1)
        XCTAssertEqual(state.content.shapes.first?.text, "Hi")
        XCTAssertEqual(state.document()["objects"]?["title"]?["kind"], "text")
        XCTAssertEqual(state.document()["handwriting"]?.objectValue?.isEmpty, true)
    }

    func testInvalidPatchChangesNothingAndExplains() throws {
        let box = NoteShape(kind: .rectangle, frame: CGRect(x: 20, y: 30, width: 100, height: 80))
        let state = AIPageState(content: AIPageContent(drawing: PKDrawing(), shapes: [box]), handwriting: [],
                                info: .init(), keys: AIPageKeys(), selectedShapeID: nil)
        let outcome = state.execute(call("apply_patch", #"""
        {"base_revision":0,"operations":[
          {"op":"replace","path":"/objects/rect1/x","value":300},
          {"op":"replace","path":"/objects/rect1/width","value":-4}
        ]}
        """#))
        let response = try JSONValue(parsing: outcome.result)

        XCTAssertEqual(response["ok"], false)
        XCTAssertTrue(response["error"]?.stringValue?.contains("/objects/rect1") == true, outcome.result)
        XCTAssertEqual(state.revision, 0)
        XCTAssertEqual(state.content.shapes, [box])

        let stale = state.execute(call("apply_patch", #"{"base_revision":3,"operations":[{"op":"remove","path":"/objects/rect1"}]}"#))
        XCTAssertTrue(stale.result.contains("stale"))
        XCTAssertEqual(state.content.shapes, [box])
    }

    func testUpdatesKeepIdentityAndUnrelatedStrokesExactly() throws {
        let mask = ShapeErasureMask(points: [CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0), CGPoint(x: 0.5, y: 0.5)])
        let box = NoteShape(kind: .rectangle, frame: CGRect(x: 20, y: 30, width: 100, height: 80), erasureMasks: [mask])
        let strokes = [stroke([CGPoint(x: 40, y: 100), CGPoint(x: 80, y: 140)]),
                       stroke([CGPoint(x: 300, y: 500), CGPoint(x: 400, y: 600)])]
        let state = AIPageState(content: AIPageContent(drawing: PKDrawing(strokes: strokes), shapes: [box]),
                                handwriting: [], info: .init(), keys: AIPageKeys(), selectedShapeID: nil)
        try state.apply(JSONPatch.operations(from: JSONValue(parsing: #"""
        [{"op":"replace","path":"/objects/rect1/x","value":520},
         {"op":"replace","path":"/ink/s1/bounds/x","value":140},
         {"op":"replace","path":"/ink/s1/color","value":"#FF0000"}]
        """#)))
        var expected = box
        expected.frame.origin.x = 520
        XCTAssertEqual(state.content.shapes, [expected])
        let moved = state.content.drawing.strokes[0]
        XCTAssertEqual(moved.renderBounds.midX - strokes[0].renderBounds.midX, 100, accuracy: 0.5)
        XCTAssertEqual(AIPageState.hex(moved.ink.color), "#FF0000")
        XCTAssertEqual(state.content.drawing.strokes[1].renderBounds, strokes[1].renderBounds)
    }

    func testAddsInkStrokeWithBrushAndClearsLayers() throws {
        let box = NoteShape(kind: .ellipse, frame: CGRect(x: 20, y: 30, width: 100, height: 80))
        let state = AIPageState(content: AIPageContent(drawing: PKDrawing(strokes: [stroke([.zero, CGPoint(x: 9, y: 9)])]), shapes: [box]),
                                handwriting: [], info: .init(), keys: AIPageKeys(), selectedShapeID: nil)
        try state.apply(JSONPatch.operations(from: JSONValue(parsing: #"""
        [{"op":"replace","path":"/ink","value":{}},
         {"op":"add","path":"/ink/wave","value":{"points":[[100,100],[150,80],[200,100]],"brush":"crayon","color":"#00AA00","width":8}}]
        """#)))
        XCTAssertEqual(state.content.drawing.strokes.count, 1)
        XCTAssertEqual(state.content.drawing.strokes[0].ink.inkType, .crayon)
        XCTAssertEqual(state.content.shapes, [box])
        XCTAssertEqual(state.document()["ink"]?["wave"]?["brush"], "crayon")

        try state.apply(JSONPatch.operations(from: JSONValue(parsing: #"[{"op":"replace","path":"/objects","value":{}}]"#)))
        XCTAssertTrue(state.content.shapes.isEmpty)
        XCTAssertEqual(state.revision, 2)
    }

    func testKeysStayStableAcrossTurns() throws {
        let keys = AIPageKeys()
        let box = NoteShape(kind: .text, frame: CGRect(x: 20, y: 30, width: 100, height: 30), text: "A")
        let ink = stroke([CGPoint(x: 40, y: 100), CGPoint(x: 80, y: 140)])
        let first = AIPageState(content: AIPageContent(drawing: PKDrawing(strokes: [ink]), shapes: [box]),
                                handwriting: [], info: .init(), keys: keys, selectedShapeID: nil)
        try first.apply(JSONPatch.operations(from: JSONValue(parsing: #"""
        [{"op":"add","path":"/objects/arrow_a","value":{"kind":"arrow","x":10,"y":10,"width":50,"height":0}},
         {"op":"replace","path":"/ink/s1/color","value":"#0000FF"}]
        """#)))
        let second = AIPageState(content: first.content, handwriting: [], info: .init(), keys: keys, selectedShapeID: nil)
        let document = second.document()
        XCTAssertEqual(document["objects"]?.objectValue?.keys, ["text1", "arrow_a"])
        XCTAssertEqual(document["ink"]?.objectValue?.keys, ["s1"])
    }

    func testReadOnlyMembersAndHandwritingTextAreRejected() {
        let state = AIPageState(content: AIPageContent(drawing: PKDrawing(strokes: [stroke([.zero, CGPoint(x: 9, y: 9)])]), shapes: []),
                                handwriting: [HandwritingLine(text: "x", bounds: .zero, confidence: 1, strokeIndices: [0], words: [])],
                                info: .init(), keys: AIPageKeys(), selectedShapeID: nil)
        for patch in [#"[{"op":"replace","path":"/page/width","value":10}]"#,
                      #"[{"op":"replace","path":"/handwriting/h1/text","value":"y"}]"#,
                      #"[{"op":"add","path":"/objects/bad key","value":{"kind":"ellipse","x":1,"y":1,"width":5,"height":5}}]"#,
                      #"[{"op":"add","path":"/objects/a","value":{"kind":"text","text":"","x":1,"y":1,"width":5}}]"#] {
            XCTAssertThrowsError(try state.apply(JSONPatch.operations(from: JSONValue(parsing: patch))), patch)
        }
        XCTAssertEqual(state.revision, 0)
    }

    func testWritesHandwritingWithTheCurrentPen() throws {
        var info = AIPageState.PageInfo()
        info.pen = PKInkingTool(.pencil, color: .blue, width: 4)
        let state = AIPageState(content: AIPageContent(drawing: PKDrawing(), shapes: []), handwriting: [],
                                info: info, keys: AIPageKeys(), selectedShapeID: nil)
        XCTAssertEqual(state.document()["pen"]?["brush"], "pencil")
        let outcome = state.execute(call("apply_patch", #"""
        {"base_revision":0,"operations":[
          {"op":"add","path":"/handwriting/note","value":{"text":"Buy milk","x":80,"y":200,"fontSize":30}},
          {"op":"add","path":"/ink/tick","value":{"points":[[60,210],[66,220],[76,200]]}}
        ]}
        """#))
        XCTAssertEqual(try JSONValue(parsing: outcome.result)["ok"], true, outcome.result)
        let strokes = state.content.drawing.strokes
        XCTAssertGreaterThan(strokes.count, 8)
        XCTAssertTrue(strokes.allSatisfy { $0.ink.inkType == .pencil && AIPageState.hex($0.ink.color) == "#0000FF" })
        let line = try XCTUnwrap(state.document()["handwriting"]?["note"])
        XCTAssertEqual(line["text"], "Buy milk")
        XCTAssertEqual(line["words"]?.arrayValue?.map { $0["text"] }, ["Buy", "milk"])
        let bounds = try XCTUnwrap(line["bounds"])
        XCTAssertEqual(bounds["x"]?.numberValue ?? 0, 80, accuracy: 6)
        XCTAssertEqual(bounds["y"]?.numberValue ?? 0, 200, accuracy: 12)

        // Written ink is real handwriting for the next turn and can be erased like the user's own.
        try state.apply(JSONPatch.operations(from: JSONValue(parsing: #"[{"op":"remove","path":"/handwriting/note"}]"#)))
        XCTAssertEqual(state.content.drawing.strokes.count, 1)

        let offPage = state.execute(call("apply_patch", #"{"base_revision":2,"operations":[{"op":"add","path":"/handwriting/big","value":{"text":"Too far","x":700,"y":1000,"fontSize":60,"maxWidth":60}}]}"#))
        XCTAssertTrue(offPage.result.contains("off the page"), offPage.result)
    }

    @MainActor
    func testWrittenHandwritingIsReadableByRecognizer() async throws {
        let state = AIPageState(content: AIPageContent(drawing: PKDrawing(), shapes: []), handwriting: [],
                                info: .init(), keys: AIPageKeys(), selectedShapeID: nil)
        try state.apply(JSONPatch.operations(from: JSONValue(parsing: #"[{"op":"add","path":"/handwriting/h","value":{"text":"Hello world","x":80,"y":200,"fontSize":40}}]"#)))
        let lines = await HandwritingRecognizer.recognize(state.content.drawing)
        try XCTSkipIf(lines.isEmpty, "Vision returned no text in this environment")
        XCTAssertTrue(lines.map(\.text).joined(separator: " ").lowercased().contains("hello"), "\(lines.map(\.text))")
    }

    func testViewPageReturnsImageOnlyWhenEnabled() throws {
        let box = NoteShape(kind: .rectangle, frame: CGRect(x: 20, y: 30, width: 100, height: 80))
        let content = AIPageContent(drawing: PKDrawing(), shapes: [box])
        let disabled = AIPageState(content: content, handwriting: [], info: .init(), keys: AIPageKeys(), selectedShapeID: nil)
        XCTAssertFalse(AIPageState.tools(imageInput: false).map(\.name).contains("view_page"))
        XCTAssertEqual(disabled.execute(call("view_page", "{}")).images, [])
        XCTAssertTrue(disabled.execute(call("view_page", "{}")).result.contains("Unknown tool"))

        let enabled = AIPageState(content: content, handwriting: [], info: .init(), keys: AIPageKeys(),
                                  selectedShapeID: nil, imageInput: true)
        XCTAssertTrue(AIPageState.tools(imageInput: true).map(\.name).contains("view_page"))
        let outcome = enabled.execute(call("view_page", #"{"grid":false}"#))
        let response = try JSONValue(parsing: outcome.result)
        XCTAssertEqual(response["ok"], true, outcome.result)
        XCTAssertEqual(response["image"]?["grid"], false)
        let image = try XCTUnwrap(outcome.images.first.flatMap(UIImage.init(data:)))
        XCTAssertEqual(image.size.width * image.scale, 768)
        XCTAssertEqual(image.size.height * image.scale, 1024)
    }

    func testCopiedStrokesKeepTheirKeysNextTurn() throws {
        let keys = AIPageKeys()
        let original = [stroke([CGPoint(x: 40, y: 100), CGPoint(x: 80, y: 100)])]
        let state = AIPageState(content: AIPageContent(drawing: PKDrawing(strokes: original), shapes: []),
                                handwriting: [], info: .init(), keys: keys, selectedShapeID: nil)
        let outcome = state.execute(call("apply_patch", #"""
        {"base_revision":0,"operations":[
          {"op":"copy","from":"/ink/s1","path":"/ink/a"},
          {"op":"copy","from":"/ink/s1","path":"/ink/b"}
        ]}
        """#))
        XCTAssertEqual(try JSONValue(parsing: outcome.result)["ok"], true, outcome.result)
        let next = AIPageState(content: state.content, handwriting: [], info: .init(), keys: keys, selectedShapeID: nil)
        XCTAssertEqual(next.document()["ink"]?.objectValue?.keys, ["s1", "a", "b"])
    }

    func testSystemPromptAddsOnlyTheNotesThatApply() {
        let content = AIPageContent(drawing: PKDrawing(), shapes: [])
        let plain = AIPageState(content: content, handwriting: [], info: .init(), keys: AIPageKeys(), selectedShapeID: nil)
        let prompt = plain.systemPrompt(includeInk: true)
        XCTAssertTrue(prompt.hasPrefix(AIPageState.instructions))
        XCTAssertFalse(prompt.contains(AIPageState.imageInstructions))
        XCTAssertFalse(prompt.contains(AIPageState.unsharedInkInstructions))
        XCTAssertTrue(prompt.contains("Current page state:\n{\"revision\":0"))

        let images = AIPageState(content: content, handwriting: [], info: .init(), keys: AIPageKeys(),
                                 selectedShapeID: nil, imageInput: true)
        let full = images.systemPrompt(includeInk: false)
        XCTAssertTrue(full.contains(AIPageState.imageInstructions))
        XCTAssertTrue(full.contains(AIPageState.unsharedInkInstructions))
    }

    func testChatMarkdownParsesCommonBlocks() {
        let reply = """
        ## Changes
        I **added** a title.
        It sits at the top.

        - Moved `rect1`
          - nested item
        2) Recolored the arrow
        > Note: handwriting may be misread
        > twice
        ---
        ```
        let x = 1
        ```
        Not a #heading, and *not* - a list
        """
        XCTAssertEqual(ChatMarkdown.blocks(reply), [
            .heading(level: 2, text: "Changes"),
            .paragraph("I **added** a title.\nIt sits at the top."),
            .bullet(indent: 0, text: "Moved `rect1`"),
            .bullet(indent: 1, text: "nested item"),
            .numbered(indent: 0, number: "2", text: "Recolored the arrow"),
            .quote("Note: handwriting may be misread\ntwice"),
            .rule,
            .code("let x = 1"),
            .paragraph("Not a #heading, and *not* - a list"),
        ])
        XCTAssertEqual(String(ChatMarkdown.inline("I **added** it").characters), "I added it")
        XCTAssertEqual(ChatMarkdown.blocks("Unclosed\n```\ncode"), [.paragraph("Unclosed"), .code("code")])
    }

    func testBaseRevisionMustBeAnExactInteger() throws {
        let state = AIPageState(content: AIPageContent(drawing: PKDrawing(), shapes: []), handwriting: [],
                                info: .init(), keys: AIPageKeys(), selectedShapeID: nil)
        let add = #"[{"op":"add","path":"/objects/t","value":{"kind":"text","text":"Hi","x":10,"y":10,"width":100}}]"#
        for base in ["1e100", "0.9", "-1e300", #""x""#] {
            let outcome = state.execute(call("apply_patch", #"{"base_revision":\#(base),"operations":\#(add)}"#))
            XCTAssertEqual(try JSONValue(parsing: outcome.result)["ok"], false, base)
        }
        let missing = state.execute(call("apply_patch", #"{"operations":\#(add)}"#))
        XCTAssertEqual(try JSONValue(parsing: missing.result)["ok"], false)
        XCTAssertEqual(state.revision, 0)
        let ok = state.execute(call("apply_patch", #"{"base_revision":"0","operations":\#(add)}"#))
        XCTAssertEqual(try JSONValue(parsing: ok.result)["ok"], true, ok.result)
    }

    func testDuplicateStrokesKeepUniqueKeysAfterRemovalAndUndo() throws {
        let duplicate = stroke([CGPoint(x: 40, y: 100), CGPoint(x: 80, y: 100)])
        let keys = AIPageKeys()
        let page = AIPageContent(drawing: PKDrawing(strokes: [duplicate, duplicate]), shapes: [])
        let first = AIPageState(content: page, handwriting: [], info: .init(), keys: keys, selectedShapeID: nil)
        XCTAssertEqual(first.document()["ink"]?.objectValue?.keys, ["s1", "s2"])
        try first.apply([JSONPatchOperation(op: .remove, path: "/ink/s1")])

        // Undo restores both strokes; the next snapshot must not assign one key twice.
        let restored = AIPageState(content: page, handwriting: [], info: .init(), keys: keys, selectedShapeID: nil)
        let inkKeys = try XCTUnwrap(restored.document()["ink"]?.objectValue?.keys)
        XCTAssertEqual(inkKeys.count, 2)
        XCTAssertEqual(Set(inkKeys).count, 2)
        XCTAssertTrue(inkKeys.contains("s2"))
    }

    func testErasingAWordRemovesItFromTheLineText() throws {
        let strokes = [stroke([CGPoint(x: 40, y: 100), CGPoint(x: 80, y: 100)]),
                       stroke([CGPoint(x: 100, y: 100), CGPoint(x: 140, y: 100)])]
        let words = [HandwritingWord(text: "Buy", bounds: .zero, strokeIndices: [0]),
                     HandwritingWord(text: "milk", bounds: .zero, strokeIndices: [1])]
        let line = HandwritingLine(text: "Buy milk", bounds: .zero, confidence: 1, strokeIndices: [0, 1], words: words)
        let state = AIPageState(content: AIPageContent(drawing: PKDrawing(strokes: strokes), shapes: []),
                                handwriting: [line], info: .init(), keys: AIPageKeys(), selectedShapeID: nil)
        try state.apply([JSONPatchOperation(op: .remove, path: "/ink/s1")])
        XCTAssertEqual(state.document()["handwriting"]?["h1"]?["text"], "milk")
    }

    func testRemovingRotationResetsItAndOtherRemovalsAreRejected() throws {
        let box = NoteShape(kind: .rectangle, frame: CGRect(x: 20, y: 30, width: 100, height: 80), rotation: 30)
        let state = AIPageState(content: AIPageContent(drawing: PKDrawing(), shapes: [box]), handwriting: [],
                                info: .init(), keys: AIPageKeys(), selectedShapeID: nil)
        XCTAssertThrowsError(try state.apply([JSONPatchOperation(op: .remove, path: "/objects/rect1/color")]))
        XCTAssertEqual(state.revision, 0)
        let result = try state.apply([JSONPatchOperation(op: .remove, path: "/objects/rect1/rotation")])
        XCTAssertEqual(result.changes, ["changed objects/rect1"])
        XCTAssertEqual(state.content.shapes.first?.rotation, 0)
    }

    private func call(_ name: String, _ arguments: String) -> AIToolCall {
        AIToolCall(id: "1", name: name, arguments: (try? JSONValue(parsing: arguments)) ?? .string(arguments))
    }

    private func stroke(_ locations: [CGPoint], ink: PKInkingTool.InkType = .pen, color: UIColor = .black) -> PKStroke {
        let points = locations.enumerated().map { index, location in
            PKStrokePoint(location: location, timeOffset: Double(index) * 0.1, size: CGSize(width: 4, height: 4),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(ink, color: color), path: PKStrokePath(controlPoints: points, creationDate: Date()))
    }
}
