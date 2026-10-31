import Foundation

/// Thrown by a tool handler to report a failure the calling agent should see and can act on
/// (bad id, missing argument, name already taken). Surfaced as a tool result with
/// `isError: true`, not as a protocol error, so the model can read the message and retry.
public struct MCPToolError: Error, Sendable, Equatable, LocalizedError {
    public let message: String

    public init(_ message: String) { self.message = message }

    public var errorDescription: String? { message }
}

/// One callable tool: its advertised schema plus the handler that runs it.
public struct MCPTool: Sendable {
    public let name: String
    public let title: String
    public let description: String
    public let inputSchema: MCPValue
    public let readOnly: Bool
    public let destructive: Bool
    public let handler: @Sendable (MCPValue) async throws -> MCPValue

    public init(
        name: String,
        title: String,
        description: String,
        inputSchema: MCPValue,
        readOnly: Bool = false,
        destructive: Bool = false,
        handler: @escaping @Sendable (MCPValue) async throws -> MCPValue
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.readOnly = readOnly
        self.destructive = destructive
        self.handler = handler
    }

    /// The `tools/list` entry. A read-only tool is also advertised as idempotent; no tool here
    /// reaches the open world.
    var descriptor: MCPValue {
        [
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": inputSchema,
            "annotations": [
                "readOnlyHint": .bool(readOnly),
                "destructiveHint": .bool(destructive),
                "idempotentHint": .bool(readOnly),
                "openWorldHint": false
            ]
        ]
    }
}

/// Typed access to a tool call's `arguments` object, throwing `MCPToolError`s an agent can read.
public struct MCPArguments: Sendable {
    public let raw: MCPValue

    public init(_ raw: MCPValue) { self.raw = raw }

    /// A required, non-empty string.
    public func string(_ key: String) throws -> String {
        guard let value = raw[key]?.stringValue, !value.isEmpty else {
            throw MCPToolError("Missing required string argument '\(key)'.")
        }
        return value
    }

    public func optionalString(_ key: String) -> String? {
        raw[key]?.stringValue
    }

    public func optionalInt(_ key: String) -> Int? {
        raw[key]?.intValue
    }

    public func optionalBool(_ key: String) -> Bool? {
        raw[key]?.boolValue
    }

    /// Absent or null is nil; anything other than an array of strings throws.
    public func optionalStringArray(_ key: String) throws -> [String]? {
        guard let value = raw[key], value != .null else { return nil }
        guard let items = value.arrayValue else {
            throw MCPToolError("Argument '\(key)' must be an array of strings.")
        }
        return try items.map {
            guard let text = $0.stringValue else {
                throw MCPToolError("Argument '\(key)' must be an array of strings.")
            }
            return text
        }
    }

    public func uuid(_ key: String) throws -> UUID {
        let text = try string(key)
        guard let id = UUID(uuidString: text) else {
            throw MCPToolError("Argument '\(key)' is not a valid UUID: \(text)")
        }
        return id
    }

    public func optionalUUIDArray(_ key: String) throws -> [UUID]? {
        guard let strings = try optionalStringArray(key) else { return nil }
        return try strings.map {
            guard let id = UUID(uuidString: $0) else {
                throw MCPToolError("'\(key)' contains an invalid UUID: \($0)")
            }
            return id
        }
    }
}
