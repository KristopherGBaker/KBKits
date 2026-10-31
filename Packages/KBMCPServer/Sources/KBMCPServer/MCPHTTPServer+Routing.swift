import Foundation

// HTTP parsing, routing and serialization: pure, so every rule is unit-testable without a socket.
extension MCPHTTPServer {
    struct Request: Sendable {
        var method: String
        var path: String
        /// Names lowercased.
        var headers: [String: String]
        var body: Data
    }

    struct Response: Sendable {
        var status: Int
        var body: Data?
        var contentType: String = "application/json"
        var headers: [String: String] = [:]
    }

    enum ParseResult {
        case needMore
        case malformed(status: Int, message: String)
        case request(Request)
    }

    static func parse(_ buffer: Data) -> ParseResult {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = buffer.range(of: separator) else {
            return buffer.count > maxHeaderBytes ? .malformed(status: 431, message: "Headers too large") : .needMore
        }
        guard let head = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8) else {
            return .malformed(status: 400, message: "Bad request")
        }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return .malformed(status: 400, message: "Bad request line") }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[line[..<colon].lowercased()] = value
        }
        if headers["transfer-encoding"] != nil {
            return .malformed(status: 501, message: "Chunked bodies are not supported")
        }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0 else { return .malformed(status: 400, message: "Bad Content-Length") }
        // Refused on the declared length, before any of the body has to arrive.
        guard length <= maxBodyBytes else { return .malformed(status: 413, message: "Body too large") }

        let bodyStart = headerEnd.upperBound
        guard buffer.count - bodyStart >= length else { return .needMore }
        return .request(Request(
            method: String(requestLine[0]),
            path: String(requestLine[1]),
            headers: headers,
            body: Data(buffer[bodyStart..<(bodyStart + length)])
        ))
    }

    /// Host, then Origin, then the bearer token, then path, then method: a foreign page learns
    /// nothing past the first check it fails.
    static func route(_ request: Request, handler: MCPRequestHandler, token: String) async -> Response {
        guard isLocal(host: request.headers["host"]) else {
            return Response(status: 403, body: Data("Forbidden host".utf8), contentType: "text/plain")
        }
        if let origin = request.headers["origin"], !isLocalOrigin(origin) {
            return Response(status: 403, body: Data("Forbidden origin".utf8), contentType: "text/plain")
        }
        let presented = request.headers["authorization"].flatMap { value -> String? in
            let parts = value.split(separator: " ", maxSplits: 1)
            return parts.count == 2 && parts[0].lowercased() == "bearer" ? String(parts[1]) : nil
        }
        guard let presented, constantTimeEqual(presented, token) else {
            return Response(
                status: 401,
                body: Data("Missing or invalid bearer token".utf8),
                contentType: "text/plain",
                headers: ["WWW-Authenticate": "Bearer"]
            )
        }
        let path = request.path.split(separator: "?").first.map(String.init) ?? request.path
        guard path == "/mcp" else {
            return Response(status: 404, body: Data("Not found".utf8), contentType: "text/plain")
        }
        guard request.method == "POST" else {
            // No server-initiated SSE stream: spec-compliant clients treat 405 on GET as "none offered".
            return Response(status: 405, body: nil, headers: ["Allow": "POST"])
        }
        guard let reply = await handler.handle(body: request.body) else {
            return Response(status: 202, body: nil)
        }
        return Response(status: 200, body: reply)
    }

    static func isLocal(host: String?) -> Bool {
        guard let host else { return false }
        let name: String
        if host.hasPrefix("[") {
            // Bracketed IPv6: only an optional `:port` may follow the closing bracket.
            guard let close = host.firstIndex(of: "]") else { return false }
            let rest = host[host.index(after: close)...]
            guard rest.isEmpty || rest.hasPrefix(":") else { return false }
            name = String(host[host.index(after: host.startIndex)..<close])
        } else if host.filter({ $0 == ":" }).count > 1 {
            // Unbracketed with several colons: a bare IPv6 literal, which cannot carry a port.
            // `::1:8080` is ambiguous (it is itself a valid IPv6 address), so only `::1` passes.
            return host == "::1"
        } else {
            name = String(host.split(separator: ":").first ?? "")
        }
        return ["localhost", "127.0.0.1", "::1"].contains(name.lowercased())
    }

    static func isLocalOrigin(_ origin: String) -> Bool {
        guard let host = URL(string: origin)?.host else { return false }
        return ["localhost", "127.0.0.1", "::1"].contains(host.lowercased())
    }

    /// Compares every byte position up to the longer length and folds the length difference in,
    /// so the time taken does not reveal how much of a guessed token was right.
    static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8), right = Array(rhs.utf8)
        var diff = left.count ^ right.count
        for index in 0..<max(left.count, right.count) {
            diff |= Int(index < left.count ? left[index] : 0) ^ Int(index < right.count ? right[index] : 0)
        }
        return diff == 0
    }

    /// The full wire form: status line, headers, blank line, body.
    static func serialize(_ response: Response) -> Data {
        var head = "HTTP/1.1 \(response.status) \(reason(response.status))\r\n"
        head += "Content-Length: \(response.body?.count ?? 0)\r\n"
        if response.body != nil { head += "Content-Type: \(response.contentType)\r\n" }
        for (key, value) in response.headers.sorted(by: { $0.key < $1.key }) { head += "\(key): \(value)\r\n" }
        head += "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        var payload = Data(head.utf8)
        if let body = response.body { payload.append(body) }
        return payload
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 413: "Payload Too Large"
        case 431: "Request Header Fields Too Large"
        case 501: "Not Implemented"
        default: "Error"
        }
    }
}
