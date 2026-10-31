import Foundation
import KBLLM

// Schema translation: the neutral `JSONSchema` written the way each Anthropic surface reads it.
// In its own file, beside request building, so that file stays within the house length limits.
extension AnthropicModel {
    /// How a schema is written for the surface it rides on.
    enum SchemaDialect {
        /// A caller tool's `input_schema`: the schema as the caller wrote it.
        case tool
        /// The legacy synthetic structured tool, sent with `strict: true`: every object closed
        /// with `additionalProperties: false`, which strict tool use requires; otherwise as
        /// written, `minItems` included, because the models on this route predate the
        /// structured-outputs grammar and its limits.
        case strictTool
        /// `output_config.format.schema`: every object closed and carrying `required`, and only
        /// the `minItems` values the structured-outputs grammar accepts (0 and 1). A larger
        /// minimum is a 400 there, so it moves into the node's description as an instruction
        /// instead; the shared conformance check still enforces it on the answer. A string's
        /// `choices` go as `enum` unchanged, which the grammar accepts for strings.
        case structuredOutput
    }

    static func schemaJSON(_ schema: JSONSchema, dialect: SchemaDialect = .tool) -> [String: Any] {
        var node: [String: Any] = ["type": schema.jsonType]
        var description = schema.schemaDescription
        switch schema {
        case .object(let properties, let required, _):
            node["properties"] = properties.mapValues { schemaJSON($0, dialect: dialect) }
            node["required"] = required
            if dialect != .tool { node["additionalProperties"] = false }
        case .array(let items, _, let minItems):
            node["items"] = schemaJSON(items, dialect: dialect)
            // Sent whenever the caller set one, 0 included; absent otherwise, so a schema
            // with no minimum serializes exactly as it did before the keyword existed.
            if let minItems {
                if dialect == .structuredOutput, minItems > 1 {
                    node["minItems"] = 1
                    description = [description, "Must contain at least \(minItems) items."]
                        .compactMap { $0 }
                        .joined(separator: " ")
                } else {
                    node["minItems"] = minItems
                }
            }
        case .string(_, let choices):
            // The same on every surface: the structured-outputs grammar documents `enum` of
            // strings as supported, so nothing is degraded. Absent when unset, so a schema
            // without choices serializes exactly as it did before the keyword existed.
            if let choices { node["enum"] = choices }
        default:
            break
        }
        if let description { node["description"] = description }
        return node
    }
}
