import Foundation

/// The MCP stdio transport: a client launches the server as a subprocess and exchanges
/// newline-delimited JSON-RPC messages over its standard input and output.
///
/// Each input line is one message (or batch) for the shared `MCPRequestHandler`; each response is
/// written as one line. Notifications get no reply. Messages are handled in order, one at a time.
public struct MCPStdioTransport: Sendable {
    public let handler: MCPRequestHandler

    public init(handler: MCPRequestHandler) {
        self.handler = handler
    }

    /// Serves until `lines` ends, passing each response line (without its newline) to `write`.
    public func serve<Lines: AsyncSequence>(
        _ lines: Lines,
        write: @Sendable (Data) async -> Void
    ) async throws where Lines.Element == String {
        for try await line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let response = await handler.handle(body: Data(trimmed.utf8)) {
                await write(response)
            }
        }
    }

    /// Serves on the process's standard input and output until standard input closes. Log to
    /// standard error: anything else written to standard output corrupts the stream.
    public func serveStandardIO() async throws {
        try await serve(FileHandle.standardInput.bytes.lines) { response in
            FileHandle.standardOutput.write(response + Data("\n".utf8))
        }
    }
}
