import XCTest
@testable import DrawBook

final class AIJSONPatchTests: XCTestCase {
    private func patch(_ json: String, _ document: JSONValue) throws -> JSONValue {
        try JSONPatch.apply(JSONPatch.operations(from: JSONValue(parsing: json)), to: document)
    }

    private func patchError(_ json: String, _ document: JSONValue,
                            file: StaticString = #filePath, line: UInt = #line) -> JSONPatchError? {
        do {
            let result = try patch(json, document)
            XCTFail("expected failure, got \(result.jsonString)", file: file, line: line)
        } catch let error as JSONPatchError {
            return error
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
        return nil
    }

    func testAddToObjectAppendsNewKeyAndReplacesExistingInPlace() throws {
        let document: JSONValue = ["a": 1, "b": 2]
        let added = try patch(#"[{"op":"add","path":"/c","value":3}]"#, document)
        XCTAssertEqual(added.objectValue?.keys, ["a", "b", "c"])
        let replaced = try patch(#"[{"op":"add","path":"/a","value":9}]"#, document)
        XCTAssertEqual(replaced.objectValue?.keys, ["a", "b"])
        XCTAssertEqual(replaced.jsonString, #"{"a":9,"b":2}"#)
    }

    func testAddToArrayIndexAndAppend() throws {
        let document: JSONValue = ["list": [1, 2]]
        XCTAssertEqual(try patch(#"[{"op":"add","path":"/list/0","value":0}]"#, document).jsonString, #"{"list":[0,1,2]}"#)
        XCTAssertEqual(try patch(#"[{"op":"add","path":"/list/2","value":3}]"#, document).jsonString, #"{"list":[1,2,3]}"#)
        XCTAssertEqual(try patch(#"[{"op":"add","path":"/list/-","value":3}]"#, document).jsonString, #"{"list":[1,2,3]}"#)
        XCTAssertNotNil(patchError(#"[{"op":"add","path":"/list/3","value":3}]"#, document))
        XCTAssertNotNil(patchError(#"[{"op":"add","path":"/list/01","value":3}]"#, document))
    }

    func testAddWholeDocument() throws {
        XCTAssertEqual(try patch(#"[{"op":"add","path":"","value":[1]}]"#, ["a": 1]), [1])
    }

    func testRemove() throws {
        let document: JSONValue = ["a": 1, "b": [1, 2, 3]]
        XCTAssertEqual(try patch(#"[{"op":"remove","path":"/a"}]"#, document), ["b": [1, 2, 3]])
        XCTAssertEqual(try patch(#"[{"op":"remove","path":"/b/1"}]"#, document), ["a": 1, "b": [1, 3]])
        // Lenient: a stray "value" on remove is ignored.
        XCTAssertEqual(try patch(#"[{"op":"remove","path":"/a","value":1}]"#, document), ["b": [1, 2, 3]])
        XCTAssertNotNil(patchError(#"[{"op":"remove","path":"/b/3"}]"#, document))
    }

    func testReplaceKeepsOrderAndRequiresTarget() throws {
        let document: JSONValue = ["a": 1, "b": 2, "c": 3]
        let replaced = try patch(#"[{"op":"replace","path":"/a","value":"x"}]"#, document)
        XCTAssertEqual(replaced.jsonString, #"{"a":"x","b":2,"c":3}"#)
        XCTAssertEqual(try patch(#"[{"op":"replace","path":"","value":5}]"#, document), 5)
        let error = patchError(#"[{"op":"replace","path":"/z","value":1}]"#, document)
        XCTAssertEqual(error?.operationIndex, 0)
    }

    func testMoveAndCopy() throws {
        let document: JSONValue = ["a": ["x": 1], "b": [1, 2]]
        XCTAssertEqual(try patch(#"[{"op":"move","from":"/a/x","path":"/y"}]"#, document),
                       ["a": [:], "b": [1, 2], "y": 1])
        XCTAssertEqual(try patch(#"[{"op":"move","from":"/b/0","path":"/b/-"}]"#, document),
                       ["a": ["x": 1], "b": [2, 1]])
        XCTAssertEqual(try patch(#"[{"op":"copy","from":"/a","path":"/c"}]"#, document),
                       ["a": ["x": 1], "b": [1, 2], "c": ["x": 1]])
    }

    func testMoveIntoOwnChildRejected() {
        let error = patchError(#"[{"op":"move","from":"/a","path":"/a/x/y"}]"#, ["a": ["x": [:]]])
        XCTAssertEqual(error?.operationIndex, 0)
        XCTAssertTrue(error?.message.contains("own child") ?? false)
    }

    func testTestOperation() throws {
        let document: JSONValue = ["a": ["p": 1, "q": [true, nil]]]
        // Object member order does not matter for equality.
        XCTAssertEqual(try patch(#"[{"op":"test","path":"/a","value":{"q":[true,null],"p":1.0}}]"#, document), document)
        let error = patchError(#"[{"op":"add","path":"/b","value":1},{"op":"test","path":"/a/p","value":2}]"#, document)
        XCTAssertEqual(error?.operationIndex, 1)
        XCTAssertEqual(error?.message, "Operation 1 (test /a/p): test failed; actual value is 1, expected 2")
    }

    func testPointerEscaping() throws {
        XCTAssertEqual(try JSONPatch.tokens(of: ""), [])
        XCTAssertEqual(try JSONPatch.tokens(of: "/"), [""])
        XCTAssertEqual(try JSONPatch.tokens(of: "/a~1b/m~0n/~01"), ["a/b", "m~n", "~1"])
        XCTAssertThrowsError(try JSONPatch.tokens(of: "a"))
        XCTAssertThrowsError(try JSONPatch.tokens(of: "/a~2"))
        let document: JSONValue = ["a/b": ["m~n": 7]]
        XCTAssertEqual(JSONPatch.value(at: "/a~1b/m~0n", in: document), 7)
        XCTAssertNil(JSONPatch.value(at: "/missing", in: document))
        XCTAssertEqual(try patch(#"[{"op":"replace","path":"/a~1b/m~0n","value":8}]"#, document), ["a/b": ["m~n": 8]])
    }

    func testAtomicFailureLeavesNoPartialResult() {
        let document: JSONValue = ["a": 1]
        var result: JSONValue?
        XCTAssertThrowsError(result = try patch(#"[{"op":"add","path":"/b","value":2},{"op":"remove","path":"/zzz"}]"#, document)) { error in
            XCTAssertEqual((error as? JSONPatchError)?.operationIndex, 1)
        }
        XCTAssertNil(result)
        XCTAssertEqual(document, ["a": 1])
    }

    func testMissingMemberErrorListsExistingKeys() {
        let document: JSONValue = ["objects": ["t1": ["x": 0], "r2": ["x": 0]]]
        let error = patchError(#"[{"op":"add","path":"/n","value":1},{"op":"add","path":"/n2","value":1},{"op":"replace","path":"/objects/t9/x","value":1}]"#, document)
        XCTAssertEqual(error?.operationIndex, 2)
        XCTAssertEqual(error?.message, #"Operation 2 (replace /objects/t9/x): path not found; member "t9" does not exist in /objects. Existing members: t1, r2"#)
    }

    func testParseErrors() throws {
        XCTAssertThrowsError(try JSONPatchOperation(json: ["op": "add", "path": "/a"])) { error in
            XCTAssertTrue((error as? JSONPatchError)?.message.contains("missing \"value\"") ?? false)
        }
        XCTAssertThrowsError(try JSONPatchOperation(json: ["op": "move", "path": "/a"])) { error in
            XCTAssertTrue((error as? JSONPatchError)?.message.contains("missing \"from\"") ?? false)
        }
        XCTAssertThrowsError(try JSONPatchOperation(json: ["op": "nope", "path": "/a"]))
        XCTAssertThrowsError(try JSONPatchOperation(json: ["op": "add", "value": 1]))
        XCTAssertThrowsError(try JSONPatch.operations(from: ["op": "add"])) { error in
            XCTAssertNil((error as? JSONPatchError)?.operationIndex)
        }
        XCTAssertThrowsError(try JSONPatch.operations(from: [["op": "add", "path": "/a", "value": 1], ["op": "copy", "path": "/b"]])) { error in
            XCTAssertEqual((error as? JSONPatchError)?.operationIndex, 1)
        }
        XCTAssertEqual(try JSONPatchOperation(json: ["op": "add", "path": "/a", "value": nil]),
                       JSONPatchOperation(op: .add, path: "/a", value: .null))
    }

    func testSelfCopiesHitTheInsertionBudgetInsteadOfGrowingExponentially() throws {
        let document: JSONValue = ["notes": ["seed": ["a": [1, 2, 3, 4], "b": "text"]]]
        let copies = (1...40).map { #"{"op":"copy","from":"/notes","path":"/notes/c\#($0)"}"# }
        let operations = "[" + copies.joined(separator: ",") + #",{"op":"test","path":"/notes","value":0}]"#
        let error = try XCTUnwrap(patchError(operations, document))
        XCTAssertTrue(error.message.contains("too much data"), error.message)
    }

    func testDeepNestingIsRejected() throws {
        var value: JSONValue = 1
        for _ in 0..<(JSONPatch.maxDepth + 1) { value = ["x": value] }
        let operation = JSONPatchOperation(op: .add, path: "/deep", value: value)
        XCTAssertThrowsError(try JSONPatch.apply([operation], to: [:]))
    }

    func testFailedTestPreviewStaysShort() throws {
        let big = JSONValue.array(Array(repeating: "0123456789", count: 10_000))
        let error = try XCTUnwrap(patchError(#"[{"op":"test","path":"/big","value":0}]"#, ["big": big]))
        XCTAssertLessThan(error.message.utf8.count, 400)
        XCTAssertLessThan(big.jsonString(limit: 50).utf8.count, 80)
    }
}
