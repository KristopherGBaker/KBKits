import Foundation
import Network
import os
import Synchronization

/// Minimal MCP "Streamable HTTP" transport: `POST /mcp` with a JSON-RPC body, answered with a
/// single JSON response (no SSE stream, no sessions).
///
/// Security posture, because a tool server exposes whatever its tools can reach:
/// - Listens on loopback only (`requiredInterfaceType = .loopback`), never a LAN interface.
/// - Every request needs `Authorization: Bearer <token>` (constant-time compare).
/// - `Host` and `Origin` must be local, which defeats DNS rebinding from a web page.
/// - Headers and bodies are capped, stalled connections time out, and every connection is
///   closed after one exchange.
public final class MCPHTTPServer: Sendable {
    public enum State: Sendable, Equatable {
        case stopped
        case running(port: UInt16)
        case failed(String)
    }

    public static let defaultConnectionTimeout = Duration.seconds(30)

    static let maxBodyBytes = 8 * 1024 * 1024
    static let maxHeaderBytes = 32 * 1024

    private let handler: MCPRequestHandler
    private let token: String
    private let connectionTimeout: Duration
    private let queue = DispatchQueue(label: "kbmcpserver.http")
    private let logger = Logger(subsystem: "KBMCPServer", category: "http")
    private let listener = Mutex<NWListener?>(nil)

    public init(
        handler: MCPRequestHandler,
        token: String,
        connectionTimeout: Duration = MCPHTTPServer.defaultConnectionTimeout
    ) {
        self.handler = handler
        self.token = token
        self.connectionTimeout = connectionTimeout
    }

    /// Starts listening and returns once the listener is ready or has failed. Port 0 binds an
    /// ephemeral port; `.running` always reports the port actually bound.
    public func start(port: UInt16) async -> State {
        stop()
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return .failed("Invalid port \(port).") }
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        let newListener: NWListener
        do {
            newListener = try NWListener(using: parameters, on: nwPort)
        } catch {
            return .failed("Couldn't listen on port \(port): \(error.localizedDescription)")
        }
        listener.withLock { $0 = newListener }

        let logger = self.logger
        let state = await withCheckedContinuation { (continuation: CheckedContinuation<State, Never>) in
            let resume = Self.resumeOnce(continuation)
            newListener.stateUpdateHandler = { [weak newListener] state in
                switch state {
                case .ready:
                    resume(.running(port: newListener?.port?.rawValue ?? port))
                case .failed(let error), .waiting(let error):
                    // A waiting listener retries forever; report it rather than hang `start`.
                    logger.error("MCP listener failed: \(error.localizedDescription, privacy: .public)")
                    resume(.failed(Self.describe(error, port: port)))
                case .cancelled:
                    resume(.stopped)
                default:
                    break
                }
            }
            newListener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            newListener.start(queue: queue)
        }
        if case .failed = state { stop(listener: newListener) }
        return state
    }

    /// Stops accepting connections. Synchronous; the socket closes as the cancel is processed.
    public func stop() {
        let current = listener.withLock { current -> NWListener? in
            defer { current = nil }
            return current
        }
        current?.cancel()
    }

    /// `stop()`, then waits (up to 2 s) until the listener has released its port, so a restart
    /// on the same port does not race the old socket.
    func stopAndWait() async {
        let current = listener.withLock { current -> NWListener? in
            defer { current = nil }
            return current
        }
        guard let current else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resume = Self.resumeOnce(continuation)
            let previous = current.stateUpdateHandler
            current.stateUpdateHandler = { state in
                previous?(state)
                if case .cancelled = state { resume(()) }
            }
            current.cancel()
            queue.asyncAfter(deadline: .now() + 2) { resume(()) }
        }
    }

    /// Wraps `continuation` in a closure that resumes it with the first value it is given;
    /// later calls do nothing. Listener callbacks can race, and a continuation resumes once.
    private static func resumeOnce<T: Sendable>(
        _ continuation: CheckedContinuation<T, Never>
    ) -> @Sendable (T) -> Void {
        let resumed = Mutex(false)
        return { value in
            let first = resumed.withLock { done -> Bool in
                defer { done = true }
                return !done
            }
            if first { continuation.resume(returning: value) }
        }
    }

    /// Cancels `failed` only if it is still the current listener (a later `start` may own it).
    private func stop(listener failed: NWListener) {
        listener.withLock { current in
            if current === failed { current = nil }
        }
        failed.cancel()
    }

    private static func describe(_ error: NWError, port: UInt16) -> String {
        if case .posix(let code) = error, code == .EADDRINUSE {
            return "Port \(port) is already in use. Pick another port."
        }
        return error.localizedDescription
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        // A stalled client shouldn't hold a connection open forever.
        let (seconds, attoseconds) = connectionTimeout.components
        let nanoseconds = seconds * 1_000_000_000 + attoseconds / 1_000_000_000
        queue.asyncAfter(deadline: .now() + .nanoseconds(Int(nanoseconds))) { connection.cancel() }
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1024
        ) { [weak self] data, _, isComplete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }

            switch Self.parse(buffer) {
            case .needMore:
                if error != nil || isComplete {
                    connection.cancel()
                } else {
                    self.receive(on: connection, buffer: buffer)
                }
            case .malformed(let status, let message):
                let response = Response(status: status, body: Data(message.utf8), contentType: "text/plain")
                Self.respond(connection, response)
            case .request(let request):
                Task { [handler = self.handler, token = self.token] in
                    Self.respond(connection, await Self.route(request, handler: handler, token: token))
                }
            }
        }
    }

    /// Writes the one response this connection gets, then closes it.
    private static func respond(_ connection: NWConnection, _ response: Response) {
        connection.send(
            content: serialize(response),
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { _ in connection.cancel() }
        )
    }
}
