import Foundation

/// A parsed JSON document as a closed set of cases, used by schema conformance.
///
/// This exists because the obvious alternative, `JSONSerialization` into `Any`, cannot tell
/// a JSON `true` from the number `1` in portable Swift. On Apple platforms both arrive as
/// `NSNumber` and the distinction needs `CFGetTypeID(x) == CFBooleanGetTypeID()`, which is
/// Apple-only; the tempting portable substitute, `x is Bool`, is not merely imprecise but
/// WRONG, because `1` and `0` bridge to `Bool` while `5` does not. Decoding into these cases
/// instead reads JSON tokens, so `true` and `1` are different by construction on every
/// platform, and no `#if` is needed.
///
/// Numbers keep their value but only their CASE is consulted: JSON draws no integer/number
/// distinction at the value level, and neither does the schema check.
enum JSONValue: Sendable, Decodable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        // Bool is tried first, but measured on Apple the order is DEFENSIVE rather than
        // load-bearing: `JSONDecoder` refuses `Bool` from `1` and refuses a number from
        // `true`, so the two are already disjoint and swapping these lines changes nothing
        // (a mutation test confirmed the suite stays green either way). It stays Bool-first
        // because swift-corelibs' strictness here is unverified, and this order is the one
        // that survives a laxer numeric decode.
        if let bool = try? container.decode(Bool.self) { self = .bool(bool); return }
        if let number = try? container.decode(Double.self) { self = .number(number); return }
        if let string = try? container.decode(String.self) { self = .string(string); return }
        if let array = try? container.decode([JSONValue].self) { self = .array(array); return }
        if let object = try? container.decode([String: JSONValue].self) { self = .object(object); return }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a JSON value")
    }
}
