import Foundation
import Testing
@testable import KBMCPServer

@Suite struct HTTPParserTests {
    private func malformedStatus(_ raw: String) -> Int? {
        if case .malformed(let status, _) = MCPHTTPServer.parse(Data(raw.utf8)) { return status }
        return nil
    }

    private func needsMore(_ data: Data) -> Bool {
        if case .needMore = MCPHTTPServer.parse(data) { return true }
        return false
    }

    private func parsed(_ raw: String) -> MCPHTTPServer.Request? {
        if case .request(let request) = MCPHTTPServer.parse(Data(raw.utf8)) { return request }
        return nil
    }

    @Test func headerCapIs32KiB() {
        #expect(needsMore(Data(repeating: 0x41, count: 32 * 1024)))
        #expect(malformedStatus(String(repeating: "A", count: 32 * 1024 + 1)) == 431)
    }

    @Test func bodyCapIs8MiBAndIsCheckedBeforeTheBodyArrives() {
        #expect(needsMore(Data("POST /mcp HTTP/1.1\r\nContent-Length: 8388608\r\n\r\n".utf8)))
        #expect(malformedStatus("POST /mcp HTTP/1.1\r\nContent-Length: 8388609\r\n\r\n") == 413)
    }

    @Test func waitsForTheFullBody() throws {
        let head = "POST /mcp HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\n\r\n"
        #expect(needsMore(Data((head + "ab").utf8)))
        let request = try #require(parsed(head + "abcde"))
        #expect(request.body == Data("abcde".utf8))
        #expect(request.method == "POST")
        #expect(request.path == "/mcp")
        #expect(request.headers["host"] == "localhost")
    }

    @Test func noContentLengthMeansAnEmptyBody() throws {
        let request = try #require(parsed("GET /mcp HTTP/1.1\r\nHost: localhost\r\n\r\n"))
        #expect(request.method == "GET" && request.body.isEmpty)
    }

    @Test func rejectsAnyTransferEncoding() {
        #expect(malformedStatus("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n") == 501)
        #expect(malformedStatus("POST /mcp HTTP/1.1\r\nTransfer-Encoding: gzip\r\n\r\n") == 501)
    }

    @Test func rejectsBadContentLengthAndRequestLines() {
        #expect(malformedStatus("POST /mcp HTTP/1.1\r\nContent-Length: x\r\n\r\n") == 400)
        #expect(malformedStatus("POST /mcp HTTP/1.1\r\nContent-Length: -1\r\n\r\n") == 400)
        #expect(malformedStatus("GARBAGE\r\n\r\n") == 400)
    }

    @Test func lowercasesHeaderNames() throws {
        let request = try #require(parsed("POST /mcp HTTP/1.1\r\nHoSt: localhost\r\nX-MiXeD-NaMe: v\r\n\r\n"))
        #expect(request.headers["host"] == "localhost")
        #expect(request.headers["x-mixed-name"] == "v")
        #expect(request.headers["HoSt"] == nil)
    }

    @Test func serializesTheWireFormat() throws {
        let body = Data(#"{"ok":true}"#.utf8)
        let wire = try utf8(MCPHTTPServer.serialize(.init(status: 200, body: body)))
        #expect(wire.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(wire.contains("Content-Length: \(body.count)\r\n"))
        #expect(wire.contains("Content-Type: application/json\r\n"))
        #expect(wire.contains("Cache-Control: no-store\r\nConnection: close\r\n\r\n"))
        #expect(wire.hasSuffix("\r\n\r\n" + #"{"ok":true}"#))
        let empty = try utf8(MCPHTTPServer.serialize(.init(status: 202, body: nil)))
        #expect(empty.hasPrefix("HTTP/1.1 202 Accepted\r\n"))
        #expect(empty.contains("Content-Length: 0\r\n"))
        #expect(!empty.contains("Content-Type"))
        #expect(empty.hasSuffix("\r\n\r\n"))
    }
}
