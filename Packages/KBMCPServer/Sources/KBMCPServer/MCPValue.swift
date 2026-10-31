import Foundation

/// A JSON document, used for JSON-RPC envelopes and tool arguments and results.
///
/// Named `MCPValue` rather than `JSONValue` because consuming apps already declare their own
/// public `JSONValue`; importing both would make the bare name ambiguous at every call site.
public enum MCPValue: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([MCPValue])
    case object([String: MCPValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([MCPValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: MCPValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            // Whole numbers encode without a trailing ".0" (ids and counts).
            if value == value.rounded(), abs(value) < 1e15 {
                try container.encode(Int64(value))
            } else {
                try container.encode(value)
            }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// The number as an `Int` when it is whole and fits; a fractional number is nil rather than
    /// silently rounded.
    public var intValue: Int? {
        if case .number(let value) = self, value == value.rounded() { return Int(exactly: value) }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var arrayValue: [MCPValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: MCPValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public subscript(key: String) -> MCPValue? {
        objectValue?[key]
    }
}

extension MCPValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension MCPValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
}

extension MCPValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension MCPValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: MCPValue...) { self = .array(elements) }
}

extension MCPValue: ExpressibleByDictionaryLiteral {
    /// Duplicate keys keep the last value.
    public init(dictionaryLiteral elements: (String, MCPValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
