import Foundation
import SwiftSyntax

// Shared parsing used by @Tool, @Schema, and @ToolGroup: doc-comment extraction,
// Swift-type to JSON-type mapping, and string-literal escaping. Kept in one place so
// the single-source-of-truth rule for descriptions has a single implementation.

/// The descriptions parsed out of a declaration's doc comment: the leading overview
/// and any `- Parameter name: text` lines. This is the ONLY place a description is
/// read, so a schema description cannot diverge from the doc comment.
struct DocComment {
    var overview: String
    var parameters: [String: String]
}

enum MacroSupport {
    /// Parse the doc comment attached ahead of a declaration.
    static func docComment(for leadingTrivia: Trivia) -> DocComment {
        var overviewLines: [String] = []
        var parameters: [String: String] = [:]
        for piece in leadingTrivia {
            switch piece {
            case .docLineComment(let text):
                consume(line: stripLinePrefix(text), into: &overviewLines, parameters: &parameters)
            case .docBlockComment(let text):
                for raw in stripBlock(text) {
                    consume(line: raw, into: &overviewLines, parameters: &parameters)
                }
            default:
                continue
            }
        }
        let overview = overviewLines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return DocComment(overview: overview, parameters: parameters)
    }

    private static func consume(
        line: String,
        into overviewLines: inout [String],
        parameters: inout [String: String]
    ) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if let (name, description) = parseParameterLine(trimmed) {
            parameters[name] = description
        } else if !trimmed.hasPrefix("-") {
            overviewLines.append(trimmed)
        }
    }

    /// Match a `- Parameter name: text` doc line, returning the name and text.
    private static func parseParameterLine(_ line: String) -> (name: String, description: String)? {
        let marker = "- Parameter "
        guard line.hasPrefix(marker) else { return nil }
        let rest = line.dropFirst(marker.count)
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        let name = rest[..<colon].trimmingCharacters(in: .whitespaces)
        let description = rest[rest.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !description.isEmpty else { return nil }
        return (name, description)
    }

    private static func stripLinePrefix(_ text: String) -> String {
        var line = text
        if line.hasPrefix("///") { line.removeFirst(3) }
        if line.hasPrefix(" ") { line.removeFirst() }
        return line
    }

    private static func stripBlock(_ text: String) -> [String] {
        var body = text
        if body.hasPrefix("/**") { body.removeFirst(3) }
        if body.hasSuffix("*/") { body.removeLast(2) }
        return body.split(separator: "\n", omittingEmptySubsequences: false).map { raw in
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("*") { line.removeFirst() }
            if line.hasPrefix(" ") { line.removeFirst() }
            return line
        }
    }

    /// Whether a written type is optional, and the type it wraps.
    ///
    /// Both spellings, because both appear in real code and a `count: Int?` that maps to a
    /// STRING is the kind of wrong that only shows up when a model sends `"3"`.
    static func unwrapOptional(_ type: String) -> (isOptional: Bool, wrapped: String) {
        let normalized = type.trimmingCharacters(in: .whitespaces)
        if normalized.hasSuffix("?") {
            return (true, String(normalized.dropLast()).trimmingCharacters(in: .whitespaces))
        }
        if normalized.hasPrefix("Optional<"), normalized.hasSuffix(">") {
            let inner = normalized.dropFirst("Optional<".count).dropLast()
            return (true, String(inner).trimmingCharacters(in: .whitespaces))
        }
        return (false, normalized)
    }

    /// Whether this package can map a written type onto a JSON Schema type with confidence.
    ///
    /// A macro sees SYNTAX, never a resolved type, so an unrecognized name could be a
    /// String-backed enum (for which the `string` fallback is exactly right) or a nested
    /// struct (for which it is exactly wrong). The caller warns rather than guessing silently.
    static func isRecognizedSchemaType(_ type: String) -> Bool {
        let (_, wrapped) = unwrapOptional(type)
        if wrapped.hasPrefix("["), wrapped.hasSuffix("]"), !wrapped.contains(":") {
            return isRecognizedSchemaType(String(wrapped.dropFirst().dropLast()))
        }
        return recognizedScalars.contains(wrapped)
    }

    private static let recognizedScalars: Set<String> = [
        "Int", "Int8", "Int16", "Int32", "Int64",
        "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
        "Double", "Float", "Float16", "CGFloat",
        "Bool", "String", "Character"
    ]

    /// Build the `JSONSchema` factory expression for a Swift type, sourcing the
    /// description from the doc comment. Falls back to `.string` for shapes the client
    /// does not model, so an unknown type still yields a valid schema.
    static func schemaExpression(for type: String, description: String?) -> String {
        // An optional describes whether the property is REQUIRED, not what type it holds, so
        // the wrapper is stripped here and the caller decides the required list.
        let normalized = unwrapOptional(type).wrapped
        let descriptionArgument = descriptionLiteral(description)
        if normalized.hasPrefix("["), normalized.hasSuffix("]"), !normalized.contains(":") {
            let element = String(normalized.dropFirst().dropLast())
            let elementSchema = schemaExpression(for: element, description: nil)
            return "JSONSchema.array(items: \(elementSchema), description: \(descriptionArgument))"
        }
        switch normalized {
        case "Int", "Int8", "Int16", "Int32", "Int64",
             "UInt", "UInt8", "UInt16", "UInt32", "UInt64":
            return "JSONSchema.integer(description: \(descriptionArgument))"
        case "Double", "Float", "Float16", "CGFloat":
            return "JSONSchema.number(description: \(descriptionArgument))"
        case "Bool":
            return "JSONSchema.boolean(description: \(descriptionArgument))"
        case "String", "Character":
            return "JSONSchema.string(description: \(descriptionArgument))"
        default:
            return "JSONSchema.string(description: \(descriptionArgument))"
        }
    }

    /// A `String?` literal expression, `nil` when absent, for embedding in generated
    /// source. Escaping keeps a description with a quote or backslash valid.
    static func descriptionLiteral(_ description: String?) -> String {
        guard let description else { return "nil" }
        return stringLiteral(description)
    }

    /// A double-quoted, escaped Swift string literal.
    static func stringLiteral(_ value: String) -> String {
        var escaped = ""
        for character in value {
            switch character {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\t": escaped += "\\t"
            default: escaped.append(character)
            }
        }
        return "\"\(escaped)\""
    }
}
