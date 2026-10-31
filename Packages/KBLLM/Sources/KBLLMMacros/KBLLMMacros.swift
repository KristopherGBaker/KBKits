// The macro DECLARATIONS. swift-syntax is quarantined in the plugin target; this
// target only declares the attached-macro shapes, so the core stays cheap to build.
//
// A tool is declared in exactly one place: a function with a doc comment and `@Tool`.
// The schema, the `ToolDefinition`, and the argument-decoding invoker are all derived
// from that single declaration, so a description and its schema cannot drift apart.

/// Attach to a function to derive its tool surface. Generates a peer factory
/// `<name>Tool()` returning a `Tool` whose `ToolDefinition` schema is built from the
/// parameter list and whose parameter descriptions come from the function's own
/// `- Parameter` doc-comment lines. The invoker decodes a JSON arguments payload, runs
/// the body, and encodes the result, turning any failure into an error `ToolResult`
/// rather than a throw.
@attached(peer, names: suffixed(Tool), suffixed(ToolArguments))
public macro Tool() = #externalMacro(module: "KBLLMMacrosPlugin", type: "ToolMacro")

/// Attach to a type to derive its structured-output JSON Schema. Generates a
/// `static let schema: JSONSchema` enumerating the type's stored properties with the
/// JSON type of each, sourcing property descriptions from their doc comments.
@attached(member, names: named(schema))
public macro Schema() = #externalMacro(module: "KBLLMMacrosPlugin", type: "SchemaMacro")

/// Attach to a type to collect its `@Tool` methods into a `ToolBox`. Generates a
/// `toolBox` property that binds every `@Tool` method to `self`, so tools can capture
/// injected dependencies and stay testable.
@attached(member, names: named(toolBox))
public macro ToolGroup() = #externalMacro(module: "KBLLMMacrosPlugin", type: "ToolGroupMacro")
