import Foundation

/// Transport-independent MCP (Model Context Protocol) server core.
///
/// Speaks JSON-RPC 2.0 and implements the slice of MCP a tool-only server needs: `initialize`,
/// `ping`, `tools/list`, `tools/call`, and the `notifications/initialized` no-op. It is stateless
/// per request (no session id), so the HTTP transport can serve any request independently.
public final class MCPRequestHandler: Sendable {
    /// Newest first; an unknown or missing requested version negotiates to the first.
    public static let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    private let serverName: String
    private let serverVersion: String
    private let instructions: String
    private let tools: [String: MCPTool]
    private let orderedTools: [MCPTool]

    /// Tools are listed in the order given. When two share a name, the first one handles calls.
    public init(serverName: String, serverVersion: String, instructions: String, tools: [MCPTool]) {
        self.serverName = serverName
        self.serverVersion = serverVersion
        self.instructions = instructions
        self.orderedTools = tools
        self.tools = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Handles one HTTP POST body. Returns the response body, or `nil` when the body held only
    /// notifications or responses (the transport answers 202).
    public func handle(body: Data) async -> Data? {
        guard let message = try? JSONDecoder().decode(MCPValue.self, from: body) else {
            return encode(Self.errorResponse(id: .null, code: -32700, message: "Parse error"))
        }
        if let batch = message.arrayValue {
            guard !batch.isEmpty else {
                return encode(Self.errorResponse(id: .null, code: -32600, message: "Empty batch"))
            }
            var responses: [MCPValue] = []
            for item in batch {
                if let response = await handleMessage(item) { responses.append(response) }
            }
            return responses.isEmpty ? nil : encode(.array(responses))
        }
        guard let response = await handleMessage(message) else { return nil }
        return encode(response)
    }

    private func handleMessage(_ message: MCPValue) async -> MCPValue? {
        guard message.objectValue != nil else {
            return Self.errorResponse(id: .null, code: -32600, message: "Invalid Request")
        }
        // No `method` means a client response to something we sent (we send nothing).
        guard let method = message["method"]?.stringValue else { return nil }
        // No `id` means a notification: never answered.
        guard let id = message["id"], id != .null else { return nil }
        let params = message["params"] ?? [:]

        switch method {
        case "initialize":
            return initialize(id: id, params: params)
        case "ping":
            return Self.result(id: id, [:])
        case "tools/list":
            return Self.result(id: id, ["tools": .array(orderedTools.map(\.descriptor))])
        case "tools/call":
            return await callTool(id: id, params: params)
        default:
            return Self.errorResponse(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func initialize(id: MCPValue, params: MCPValue) -> MCPValue {
        let requested = params["protocolVersion"]?.stringValue
        let version = requested.flatMap { Self.supportedProtocolVersions.contains($0) ? $0 : nil }
            ?? Self.supportedProtocolVersions[0]
        return Self.result(id: id, [
            "protocolVersion": .string(version),
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": .string(serverName), "version": .string(serverVersion)],
            "instructions": .string(instructions)
        ])
    }

    private func callTool(id: MCPValue, params: MCPValue) async -> MCPValue {
        guard let name = params["name"]?.stringValue, let tool = tools[name] else {
            let shown = params["name"]?.stringValue ?? "(none)"
            return Self.errorResponse(id: id, code: -32602, message: "Unknown tool: \(shown)")
        }
        let arguments = params["arguments"] ?? [:]
        do {
            let output = try await tool.handler(arguments)
            return Self.result(id: id, Self.toolResult(text: Self.render(output), isError: false))
        } catch let error as MCPToolError {
            return Self.result(id: id, Self.toolResult(text: error.message, isError: true))
        } catch {
            let text = "Tool failed: \(error.localizedDescription)"
            return Self.result(id: id, Self.toolResult(text: text, isError: true))
        }
    }

    // MARK: - Envelope helpers

    private static func toolResult(text: String, isError: Bool) -> MCPValue {
        ["content": [["type": "text", "text": .string(text)]], "isError": .bool(isError)]
    }

    /// Strings pass through as-is; structured output is pretty JSON text so every client
    /// renders it (structured content support varies).
    private static func render(_ value: MCPValue) -> String {
        if let text = value.stringValue { return text }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else {
            return "null"
        }
        return text
    }

    static func result(id: MCPValue, _ result: MCPValue) -> MCPValue {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    static func errorResponse(id: MCPValue, code: Int, message: String) -> MCPValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)]]
    }

    private func encode(_ value: MCPValue) -> Data? {
        try? JSONEncoder().encode(value)
    }
}
