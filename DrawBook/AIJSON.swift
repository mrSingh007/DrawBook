import Foundation

/// A JSON object that keeps member order so state documents read top-down and
/// map keys keep their insertion (drawing) order. Equality ignores order, per RFC 6902 `test`.
struct JSONObject: Equatable, Sendable, ExpressibleByDictionaryLiteral {
    private(set) var keys: [String] = []
    private var storage: [String: JSONValue] = [:]

    init() {}
    init(dictionaryLiteral elements: (String, JSONValue)...) {
        for (key, value) in elements { self[key] = value }
    }
    init(_ pairs: [(String, JSONValue)]) {
        for (key, value) in pairs { self[key] = value }
    }

    var count: Int { keys.count }
    var isEmpty: Bool { keys.isEmpty }
    var pairs: [(key: String, value: JSONValue)] { keys.map { ($0, storage[$0]!) } }

    /// Setting nil removes the member. Assigning an existing key keeps its position.
    subscript(key: String) -> JSONValue? {
        get { storage[key] }
        set {
            if let newValue {
                if storage.updateValue(newValue, forKey: key) == nil { keys.append(key) }
            } else if storage.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }

    static func == (lhs: JSONObject, rhs: JSONObject) -> Bool { lhs.storage == rhs.storage }
}

indirect enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)

    var objectValue: JSONObject? { if case let .object(value) = self { return value }; return nil }
    var arrayValue: [JSONValue]? { if case let .array(value) = self { return value }; return nil }
    var stringValue: String? { if case let .string(value) = self { return value }; return nil }
    var numberValue: Double? { if case let .number(value) = self { return value }; return nil }
    var boolValue: Bool? { if case let .bool(value) = self { return value }; return nil }

    subscript(key: String) -> JSONValue? { objectValue?[key] }

    /// Parse UTF-8 JSON text. Top-level scalars are allowed.
    init(parsing text: String) throws {
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
        self = try JSONValue(foundation: object)
    }

    init(foundation object: Any) throws {
        switch object {
        case is NSNull: self = .null
        case let number as NSNumber:
            // JSONSerialization represents booleans as CFBoolean-backed NSNumbers.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { self = .bool(number.boolValue) }
            else { self = .number(number.doubleValue) }
        case let string as String: self = .string(string)
        case let array as [Any]: self = .array(try array.map(JSONValue.init(foundation:)))
        case let dictionary as [String: Any]:
            // Foundation dictionaries are unordered; sort for a stable result.
            var object = JSONObject()
            for key in dictionary.keys.sorted() { object[key] = try JSONValue(foundation: dictionary[key]!) }
            self = .object(object)
        default:
            throw CocoaError(.coderReadCorrupt)
        }
    }

    /// Compact JSON text in member order. Whole numbers print without a fraction.
    var jsonString: String {
        var output = ""
        write(to: &output, limit: .max)
        return output
    }

    /// The start of `jsonString`, stopping soon after `limit` UTF-8 bytes so previews of
    /// huge (or logically huge, shared) values cost about the same as small ones.
    func jsonString(limit: Int) -> String {
        var output = ""
        write(to: &output, limit: limit)
        return output
    }

    private func write(to output: inout String, limit: Int) {
        guard output.utf8.count <= limit else { return }
        switch self {
        case .null: output += "null"
        case let .bool(value): output += value ? "true" : "false"
        case let .number(value):
            if !value.isFinite { output += "null" }
            else if value == value.rounded(), abs(value) < 1e15 { output += String(Int64(value)) }
            else { output += String(value) }
        case let .string(value): Self.writeString(value, to: &output)
        case let .array(values):
            output += "["
            for (index, value) in values.enumerated() {
                guard output.utf8.count <= limit else { return }
                if index > 0 { output += "," }
                value.write(to: &output, limit: limit)
            }
            output += "]"
        case let .object(object):
            output += "{"
            for (index, pair) in object.pairs.enumerated() {
                guard output.utf8.count <= limit else { return }
                if index > 0 { output += "," }
                Self.writeString(pair.key, to: &output)
                output += ":"
                pair.value.write(to: &output, limit: limit)
            }
            output += "}"
        }
    }

    private static func writeString(_ value: String, to output: inout String) {
        output += "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case let control where control.value < 0x20:
                output += String(format: "\\u%04X", control.value)
            default: output.unicodeScalars.append(scalar)
            }
        }
        output += "\""
    }
}

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
                     ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral,
                     ExpressibleByDictionaryLiteral {
    init(nilLiteral: ()) { self = .null }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(floatLiteral value: Double) { self = .number(value) }
    init(stringLiteral value: String) { self = .string(value) }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(JSONObject(elements)) }
}

extension JSONValue: Encodable {
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(values): try container.encode(values)
        case let .object(object):
            try container.encode(Dictionary(uniqueKeysWithValues: object.pairs.map { ($0.key, $0.value) }))
        }
    }
}
