import Foundation
import Observation
import Security

/// Owns an MCP server's lifecycle. Persistence-agnostic: the caller supplies the port, the
/// bearer token and whether the server is enabled, and persists whatever changes (the token
/// `regenerateToken()` returns, a new port). Nothing is read from or written to storage here.
@MainActor
@Observable
public final class MCPServerController {
    public static let defaultPort: UInt16 = 47821

    public private(set) var isEnabled: Bool
    /// The configured port; 0 means "any free port".
    public private(set) var port: UInt16
    public private(set) var token: String
    public private(set) var state: MCPHTTPServer.State = .stopped

    private let handler: MCPRequestHandler
    @ObservationIgnored private var server: MCPHTTPServer?
    /// Bumped by every restart, so an overtaken restart drops the server it started.
    @ObservationIgnored private var generation = 0

    public init(port: UInt16, token: String, isEnabled: Bool, handler: MCPRequestHandler) {
        self.port = port
        self.token = token
        self.isEnabled = isEnabled
        self.handler = handler
    }

    /// Endpoint URL to give an agent: the bound port while running, else the configured one.
    public var endpoint: String {
        if case .running(let bound) = state { return "http://127.0.0.1:\(bound)/mcp" }
        return "http://127.0.0.1:\(port)/mcp"
    }

    /// One-line registration for Claude Code, under the server name `name`.
    public func claudeCodeCommand(name: String) -> String {
        "claude mcp add --transport http \(name) \(endpoint) --header \"Authorization: Bearer \(token)\""
    }

    /// Starts the server if it is enabled; otherwise does nothing.
    public func start() async {
        guard isEnabled else { return }
        await restart()
    }

    public func setEnabled(_ enabled: Bool) async {
        isEnabled = enabled
        await restart()
    }

    /// Accepts 0 (any free port) or 1024 and above; a privileged port is ignored.
    public func setPort(_ newPort: UInt16) async {
        guard newPort == 0 || newPort >= 1024, newPort != port else { return }
        port = newPort
        await restart()
    }

    /// Invalidates the old token immediately; agents must be re-registered. Returns the new
    /// token so the caller can persist it.
    @discardableResult
    public func regenerateToken() async -> String {
        token = Self.makeToken()
        await restart()
        return token
    }

    public func stop() {
        generation += 1
        server?.stop()
        server = nil
        state = .stopped
    }

    /// 32 bytes from `SecRandomCopyBytes`, as 64 lowercase hex characters.
    public static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func restart() async {
        generation += 1
        let mine = generation
        let previous = server
        server = nil
        await previous?.stopAndWait()
        guard mine == generation else { return }
        guard isEnabled else {
            state = .stopped
            return
        }
        let newServer = MCPHTTPServer(handler: handler, token: token)
        server = newServer
        let result = await newServer.start(port: port)
        guard mine == generation else {
            newServer.stop()
            return
        }
        state = result
        if case .failed = result { server = nil }
    }
}
