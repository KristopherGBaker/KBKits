import Foundation
import Testing
@testable import KBMCPServer

@Suite struct StdioTransportTests {
    let nonce = UUID().uuidString

    private actor Output {
        var lines: [MCPValue] = []
        func append(_ data: Data) throws {
            #expect(!data.contains(UInt8(ascii: "\n")))
            lines.append(try JSONDecoder().decode(MCPValue.self, from: data))
        }
    }

    private func serve(_ input: [String]) async throws -> [MCPValue] {
        let output = Output()
        let lines = AsyncStream<String> { continuation in
            input.forEach { continuation.yield($0) }
            continuation.finish()
        }
        try await MCPStdioTransport(handler: makeHandler(nonce: nonce)).serve(lines) { data in
            try? await output.append(data)
        }
        return await output.lines
    }

    @Test func answersEachRequestLineInOrderAndSkipsNotificationsAndBlankLines() async throws {
        let replies = try await serve([
            try request("initialize", ["protocolVersion": "2025-06-18"], id: 1),
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            "",
            "   ",
            try request("ping", id: 2)
        ])
        #expect(replies.count == 2)
        #expect(replies.first?["id"] == .number(1))
        #expect(replies.first?["result"]?["serverInfo"]?["name"]?.stringValue == "srv-\(nonce)")
        #expect(replies.last?["id"] == .number(2))
        #expect(replies.last?["result"] == .object([:]))
    }

    @Test func malformedLinesGetAParseErrorAndTheStreamContinues() async throws {
        let replies = try await serve(["{not json", pingBody])
        #expect(replies.count == 2)
        #expect(replies.first?["error"]?["code"] == .number(-32700))
        #expect(replies.last?["result"] == .object([:]))
    }
}
