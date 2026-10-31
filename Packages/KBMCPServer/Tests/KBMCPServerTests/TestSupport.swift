import Foundation
import Network
import Synchronization
import Testing
@testable import KBMCPServer

/// Sends one JSON-RPC body and decodes the reply; fails the test when there is no reply.
func rpc(_ handler: MCPRequestHandler, _ json: String) async throws -> MCPValue {
    let reply = try #require(await handler.handle(body: Data(json.utf8)))
    return try JSONDecoder().decode(MCPValue.self, from: reply)
}

/// Builds a JSON-RPC request body with a numeric id.
func request(_ method: String, _ params: MCPValue = [:], id: Int = 1) throws -> String {
    let value: MCPValue = ["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params]
    return try utf8(try JSONEncoder().encode(value))
}

/// Decodes UTF-8 bytes, failing the test on invalid input.
func utf8(_ data: Data) throws -> String {
    try #require(String(bytes: data, encoding: .utf8))
}

/// The text of a `tools/call` result's first content block, and its `isError` flag.
func toolText(_ response: MCPValue) -> (isError: Bool?, text: String?) {
    let result = response["result"]
    return (result?["isError"]?.boolValue, result?["content"]?.arrayValue?.first?["text"]?.stringValue)
}

/// A tool whose output is derived from a per-test nonce: `<nonce>:<msg argument>`.
func echoTool(nonce: String, name: String = "echo", readOnly: Bool = false, destructive: Bool = false) -> MCPTool {
    MCPTool(
        name: name,
        title: "Echo",
        description: "Echoes msg behind a nonce.",
        inputSchema: ["type": "object", "properties": ["msg": ["type": "string"]]],
        readOnly: readOnly,
        destructive: destructive
    ) { args in
        .string("\(nonce):\(args["msg"]?.stringValue ?? "")")
    }
}

func makeHandler(nonce: String, tools: [MCPTool]? = nil) -> MCPRequestHandler {
    MCPRequestHandler(
        serverName: "srv-\(nonce)",
        serverVersion: "v-\(nonce)",
        instructions: "ins-\(nonce)",
        tools: tools ?? [echoTool(nonce: nonce)]
    )
}

// MARK: - HTTP clients

let pingBody = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
let notificationBody = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#

struct HTTPReply {
    let status: Int
    let data: Data
    let response: HTTPURLResponse
}

/// A real URLSession request to `http://127.0.0.1:<port>/mcp`.
func post(
    port: UInt16,
    token: String?,
    body: String,
    method: String = "POST",
    timeout: TimeInterval = 10
) async throws -> HTTPReply {
    var request = URLRequest(url: try #require(URL(string: "http://127.0.0.1:\(port)/mcp")))
    request.httpMethod = method
    request.timeoutInterval = timeout
    if method == "POST" { request.httpBody = Data(body.utf8) }
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    let (data, response) = try await URLSession.shared.data(for: request)
    let http = try #require(response as? HTTPURLResponse)
    return HTTPReply(status: http.statusCode, data: data, response: http)
}

/// True once a POST to `port` is refused at connect time, polling until `deadline` passes.
func refusesConnections(port: UInt16, within deadline: Duration = .seconds(2)) async -> Bool {
    let clock = ContinuousClock()
    let end = clock.now + deadline
    while clock.now < end {
        do {
            _ = try await post(port: port, token: nil, body: pingBody, timeout: 0.5)
        } catch let error as URLError where error.code == .cannotConnectToHost {
            return true
        } catch {
            // A timeout or reset is not a refusal; try again.
        }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return false
}

/// What a raw TCP client saw: the bytes, whether the server closed the stream (EOF) or reset it,
/// and how long after sending that happened.
struct RawReply: Sendable {
    var bytes = Data()
    var sawEOF = false
    var sawError = false
    var elapsed: Duration = .zero

    var text: String { String(bytes: bytes, encoding: .utf8) ?? "" }
    var closed: Bool { sawEOF || sawError }

    /// The response head's header lines, keyed by lowercased name.
    var headers: [String: String] {
        guard let end = text.range(of: "\r\n\r\n") else { return [:] }
        var result: [String: String] = [:]
        for line in text[..<end.lowerBound].components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            result[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    var body: Data {
        guard let end = bytes.range(of: Data("\r\n\r\n".utf8)) else { return Data() }
        return bytes[end.upperBound...]
    }
}

/// Opens a raw `NWConnection` to the loopback port, sends `payload` without closing the write
/// side, and reads until the server closes the connection or `deadline` passes.
func rawExchange(port: UInt16, payload: Data, deadline: Duration = .seconds(3)) async throws -> RawReply {
    let nwPort = try #require(NWEndpoint.Port(rawValue: port))
    let connection = NWConnection(host: "127.0.0.1", port: nwPort, using: .tcp)
    let queue = DispatchQueue(label: "kbmcpserver.tests.raw")
    let clock = ContinuousClock()
    let started = clock.now
    return await withCheckedContinuation { (continuation: CheckedContinuation<RawReply, Never>) in
        let reply = Mutex<(done: Bool, value: RawReply)>((false, RawReply()))
        let finish: @Sendable (_ eof: Bool, _ error: Bool) -> Void = { eof, error in
            let result = reply.withLock { state -> RawReply? in
                guard !state.done else { return nil }
                state.done = true
                state.value.sawEOF = eof
                state.value.sawError = error
                state.value.elapsed = clock.now - started
                return state.value
            }
            guard let result else { return }
            connection.cancel()
            continuation.resume(returning: result)
        }
        @Sendable func read() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let data { reply.withLock { $0.value.bytes.append(data) } }
                if error != nil {
                    finish(false, true)
                } else if isComplete {
                    finish(true, false)
                } else {
                    read()
                }
            }
        }
        connection.stateUpdateHandler = { state in
            if case .failed = state { finish(false, true) }
        }
        connection.start(queue: queue)
        connection.send(content: payload, isComplete: false, completion: .contentProcessed { _ in })
        read()
        let (seconds, attoseconds) = deadline.components
        let nanoseconds = Int(seconds * 1_000_000_000 + attoseconds / 1_000_000_000)
        queue.asyncAfter(deadline: .now() + .nanoseconds(nanoseconds)) { finish(false, false) }
    }
}

/// A full HTTP/1.1 request as raw bytes.
func rawRequest(token: String, body: String, extraHeaders: String = "") -> Data {
    let head = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer \(token)\r\n"
        + "Content-Length: \(Data(body.utf8).count)\r\n\(extraHeaders)\r\n"
    return Data((head + body).utf8)
}
