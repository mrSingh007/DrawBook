import Foundation

/// One RFC 6902 operation. Leniency for LLMs: `remove` accepts (and ignores) a `value` member;
/// everything else is strict. Unknown members are ignored, as RFC 6902 requires.
struct JSONPatchOperation: Equatable {
    enum Op: String, CaseIterable { case add, remove, replace, move, copy, test }

    let op: Op
    let path: String
    let from: String?
    let value: JSONValue?

    init(op: Op, path: String, from: String? = nil, value: JSONValue? = nil) {
        self.op = op
        self.path = path
        self.from = from
        self.value = value
    }

    /// Parse one operation object like {"op":"add","path":"/a/-","value":1}.
    init(json: JSONValue) throws {
        guard let object = json.objectValue else {
            throw JSONPatchError(operationIndex: nil, message: "operation must be an object, got \(json.typeDescription)")
        }
        guard let opValue = object["op"] else { throw JSONPatchError(operationIndex: nil, message: "missing \"op\"") }
        guard let name = opValue.stringValue, let op = Op(rawValue: name) else {
            let valid = Op.allCases.map(\.rawValue).joined(separator: ", ")
            throw JSONPatchError(operationIndex: nil, message: "invalid \"op\" \(opValue.preview); expected one of \(valid)")
        }
        guard let pathValue = object["path"] else {
            throw JSONPatchError(operationIndex: nil, message: "\(name): missing \"path\"")
        }
        guard let path = pathValue.stringValue else {
            throw JSONPatchError(operationIndex: nil, message: "\(name): \"path\" must be a string, got \(pathValue.typeDescription)")
        }
        var from: String?
        if op == .move || op == .copy {
            guard let fromValue = object["from"] else {
                throw JSONPatchError(operationIndex: nil, message: "\(name) \(path): missing \"from\"")
            }
            guard let string = fromValue.stringValue else {
                throw JSONPatchError(operationIndex: nil, message: "\(name) \(path): \"from\" must be a string, got \(fromValue.typeDescription)")
            }
            from = string
        }
        var value: JSONValue?
        if op == .add || op == .replace || op == .test {
            guard let member = object["value"] else {
                throw JSONPatchError(operationIndex: nil, message: "\(name) \(path): missing \"value\"")
            }
            value = member
        }
        self.init(op: op, path: path, from: from, value: value)
    }
}

struct JSONPatchError: LocalizedError, Equatable {
    let operationIndex: Int?
    let message: String
    var errorDescription: String? { message }
}

enum JSONPatch {
    /// Parse an array of operation objects (the "operations" tool argument).
    static func operations(from json: JSONValue) throws -> [JSONPatchOperation] {
        guard let array = json.arrayValue else {
            throw JSONPatchError(operationIndex: nil, message: "operations must be an array of operation objects, got \(json.typeDescription)")
        }
        return try array.enumerated().map { index, element in
            do { return try JSONPatchOperation(json: element) }
            catch let error as JSONPatchError {
                throw JSONPatchError(operationIndex: index, message: "Operation \(index): \(error.message)")
            }
        }
    }

    /// Logical nodes a patch may insert in total. `copy` shares storage, so without a budget a few
    /// self-copies grow the logical document exponentially and serializing it exhausts memory.
    static let maxInsertedNodes = 500_000
    /// Maximum nesting depth of the patched document.
    static let maxDepth = 64

    /// Apply atomically: either all operations succeed and the new document is returned, or it throws.
    static func apply(_ operations: [JSONPatchOperation], to document: JSONValue,
                      maxInsertedNodes: Int = maxInsertedNodes) throws -> JSONValue {
        var result = document
        var budget = maxInsertedNodes
        for (index, operation) in operations.enumerated() {
            do {
                try apply(operation, to: &result, budget: &budget)
            }
            catch let failure as Failure {
                var label = "\(operation.op.rawValue) \(operation.path.isEmpty ? "\"\"" : operation.path)"
                if let from = operation.from { label += " from \(from.isEmpty ? "\"\"" : from)" }
                throw JSONPatchError(operationIndex: index, message: "Operation \(index) (\(label)): \(failure.message)")
            }
        }
        return result
    }

    /// JSON Pointer (RFC 6901) parsing with ~1 -> "/" and ~0 -> "~" unescaping. "" = whole document.
    static func tokens(of pointer: String) throws -> [String] {
        do { return try parseTokens(pointer) }
        catch let failure as Failure { throw JSONPatchError(operationIndex: nil, message: failure.message) }
    }

    static func value(at pointer: String, in document: JSONValue) -> JSONValue? {
        guard let tokens = try? parseTokens(pointer) else { return nil }
        return try? resolve(tokens, in: document)
    }

    // MARK: - Implementation

    private struct Failure: Error { let message: String; init(_ message: String) { self.message = message } }

    /// Charges `value`'s logical size against `budget` and checks its depth at `path`,
    /// visiting at most `budget + 1` nodes so the check itself stays bounded.
    private static func charge(_ value: JSONValue, at path: [String], budget: inout Int) throws {
        var stack: [(JSONValue, Int)] = [(value, path.count)]
        while let (node, depth) = stack.popLast() {
            budget -= 1
            guard budget >= 0 else { throw Failure("the patch inserts too much data; send smaller values") }
            guard depth <= maxDepth else { throw Failure("the patch nests values deeper than \(maxDepth) levels") }
            switch node {
            case let .array(values): stack += values.map { ($0, depth + 1) }
            case let .object(object): stack += object.pairs.map { ($0.value, depth + 1) }
            default: break
            }
        }
    }

    private static func apply(_ operation: JSONPatchOperation, to document: inout JSONValue, budget: inout Int) throws {
        let path = try parseTokens(operation.path)
        switch operation.op {
        case .add:
            let value = try required(operation.value, "value")
            try charge(value, at: path, budget: &budget)
            try add(value, at: path, in: &document)
        case .remove:
            try remove(at: path, in: &document)
        case .replace:
            let value = try required(operation.value, "value")
            try charge(value, at: path, budget: &budget)
            guard let last = path.last else { document = value; return }
            try mutate(&document, path.dropLast(), "") { container, pointer in
                switch container {
                case var .object(object):
                    guard object[last] != nil else { throw missingMember(last, in: object, at: pointer) }
                    object[last] = value
                    container = .object(object)
                case var .array(array):
                    array[try index(last, count: array.count, at: pointer)] = value
                    container = .array(array)
                default:
                    throw notContainer(container, at: pointer)
                }
            }
        case .move:
            let from = try parseTokens(try required(operation.from, "from"))
            if from == path { _ = try resolve(from, in: document); return }
            if path.count > from.count, Array(path.prefix(from.count)) == from {
                throw Failure("cannot move a value into its own child")
            }
            let value = try resolve(from, in: document)
            if path.count > from.count { try charge(value, at: path, budget: &budget) } // may deepen
            try remove(at: from, in: &document)
            try add(value, at: path, in: &document)
        case .copy:
            let from = try parseTokens(try required(operation.from, "from"))
            let value = try resolve(from, in: document)
            try charge(value, at: path, budget: &budget)
            try add(value, at: path, in: &document)
        case .test:
            let expected = try required(operation.value, "value")
            let actual = try resolve(path, in: document)
            guard actual == expected else {
                throw Failure("test failed; actual value is \(actual.preview), expected \(expected.preview)")
            }
        }
    }

    private static func required<T>(_ value: T?, _ member: String) throws -> T {
        guard let value else { throw Failure("missing \"\(member)\"") }
        return value
    }

    private static func add(_ value: JSONValue, at path: [String], in document: inout JSONValue) throws {
        guard let last = path.last else { document = value; return }
        try mutate(&document, path.dropLast(), "") { container, pointer in
            switch container {
            case var .object(object):
                object[last] = value
                container = .object(object)
            case var .array(array):
                let position = last == "-" ? array.count : try index(last, count: array.count + 1, at: pointer)
                array.insert(value, at: position)
                container = .array(array)
            default:
                throw notContainer(container, at: pointer)
            }
        }
    }

    private static func remove(at path: [String], in document: inout JSONValue) throws {
        guard let last = path.last else { throw Failure("cannot remove the whole document") }
        try mutate(&document, path.dropLast(), "") { container, pointer in
            switch container {
            case var .object(object):
                guard object[last] != nil else { throw missingMember(last, in: object, at: pointer) }
                object[last] = nil
                container = .object(object)
            case var .array(array):
                array.remove(at: try index(last, count: array.count, at: pointer))
                container = .array(array)
            default:
                throw notContainer(container, at: pointer)
            }
        }
    }

    /// Walks to the container at `tokens` and lets `body` mutate it in place.
    private static func mutate(_ node: inout JSONValue, _ tokens: ArraySlice<String>, _ pointer: String,
                               _ body: (inout JSONValue, String) throws -> Void) throws {
        guard let token = tokens.first else { try body(&node, pointer); return }
        let childPointer = pointer + "/" + escape(token)
        switch node {
        case var .object(object):
            guard var child = object[token] else { throw missingMember(token, in: object, at: pointer) }
            node = .null // drop the extra reference so the child mutates without copying
            object[token] = .null
            try mutate(&child, tokens.dropFirst(), childPointer, body)
            object[token] = child
            node = .object(object)
        case var .array(array):
            let position = try index(token, count: array.count, at: pointer)
            var child = array[position]
            node = .null
            array[position] = .null
            try mutate(&child, tokens.dropFirst(), childPointer, body)
            array[position] = child
            node = .array(array)
        default:
            throw notContainer(node, at: pointer)
        }
    }

    private static func resolve(_ tokens: [String], in document: JSONValue) throws -> JSONValue {
        var node = document
        var pointer = ""
        for token in tokens {
            switch node {
            case let .object(object):
                guard let child = object[token] else { throw missingMember(token, in: object, at: pointer) }
                node = child
            case let .array(array):
                node = array[try index(token, count: array.count, at: pointer)]
            default:
                throw notContainer(node, at: pointer)
            }
            pointer += "/" + escape(token)
        }
        return node
    }

    /// Validates an array index token: digits only, no leading zeros, `0..<count`.
    private static func index(_ token: String, count: Int, at pointer: String) throws -> Int {
        let location = describe(pointer)
        if token == "-" { throw Failure("\"-\" (append) is only valid as the last token of an add path; \(location) is an array") }
        guard !token.isEmpty, token.allSatisfy({ $0.isASCII && $0.isNumber }),
              token == "0" || !token.hasPrefix("0"), let value = Int(token) else {
            throw Failure("\"\(token)\" is not a valid array index for \(location) (use digits without leading zeros)")
        }
        guard value < count else {
            throw Failure(count == 0 ? "index \(value) is out of range; \(location) is an empty array"
                                     : "index \(value) is out of range for \(location); valid indices are 0...\(count - 1)")
        }
        return value
    }

    private static func missingMember(_ token: String, in object: JSONObject, at pointer: String) -> Failure {
        let keys = object.keys.prefix(20).joined(separator: ", ")
        let more = object.count > 20 ? ", … (\(object.count - 20) more)" : ""
        let existing = object.isEmpty ? "it has no members" : "Existing members: \(keys)\(more)"
        return Failure("path not found; member \"\(token)\" does not exist in \(describe(pointer)). \(existing)")
    }

    private static func notContainer(_ value: JSONValue, at pointer: String) -> Failure {
        Failure("path not found; \(describe(pointer)) is \(value.typeDescription), not an object or array")
    }

    private static func describe(_ pointer: String) -> String { pointer.isEmpty ? "the document root" : pointer }

    private static func escape(_ token: String) -> String {
        token.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
    }

    private static func parseTokens(_ pointer: String) throws -> [String] {
        if pointer.isEmpty { return [] }
        guard pointer.hasPrefix("/") else {
            throw Failure("invalid JSON Pointer \"\(pointer)\"; it must be \"\" or start with \"/\"")
        }
        return try pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map { raw in
            var token = ""
            var iterator = raw.makeIterator()
            while let character = iterator.next() {
                guard character == "~" else { token.append(character); continue }
                switch iterator.next() {
                case "0": token.append("~")
                case "1": token.append("/")
                default: throw Failure("invalid JSON Pointer \"\(pointer)\"; \"~\" must be escaped as \"~0\" (and \"/\" as \"~1\")")
                }
            }
            return token
        }
    }
}

private extension JSONValue {
    var typeDescription: String {
        switch self {
        case .null: "null"
        case .bool: "a boolean"
        case .number: "a number"
        case .string: "a string"
        case .array: "an array"
        case .object: "an object"
        }
    }

    /// Compact JSON, truncated so error messages stay short.
    var preview: String {
        let text = jsonString(limit: 120)
        return text.utf8.count > 120 ? String(text.prefix(120)) + "…" : text
    }
}
