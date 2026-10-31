import Foundation
import Testing
@testable import KBMCPServer

@Suite struct ValueTests {
    private func encoded(_ value: MCPValue) throws -> String {
        try utf8(try JSONEncoder().encode(value))
    }

    @Test func nestedValuesRoundTrip() throws {
        let value: MCPValue = [
            "id": .string(UUID().uuidString),
            "list": [1, "two", true, .null, ["deep": [.number(2.5)]]],
            "empty": [:]
        ]
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(MCPValue.self, from: data) == value)
    }

    @Test func wholeNumbersEncodeAsIntegers() throws {
        #expect(try encoded(.number(3)) == "3")
        #expect(try encoded(.number(-7)) == "-7")
        #expect(try encoded(.number(2.5)) == "2.5")
        #expect(try encoded(.number(1e16)) != "10000000000000000")
    }

    @Test func literalsBuildTheExpectedCases() {
        #expect(("s" as MCPValue) == .string("s"))
        #expect((4 as MCPValue) == .number(4))
        #expect((false as MCPValue) == .bool(false))
        #expect(([1, "a"] as MCPValue) == .array([.number(1), .string("a")]))
        #expect((["k": 1] as MCPValue) == .object(["k": .number(1)]))
        // Spelled as a call: a literal with a repeated key draws a compiler warning.
        #expect(MCPValue(dictionaryLiteral: ("k", 1), ("k", 2)) == .object(["k": .number(2)]))
    }

    @Test func accessorsMatchOnlyTheirCase() {
        #expect(MCPValue.number(2.5).intValue == nil)
        #expect(MCPValue.number(4).intValue == 4)
        #expect(MCPValue.string("4").intValue == nil)
        #expect(MCPValue.number(1).stringValue == nil)
        #expect(MCPValue.bool(true).boolValue == true)
        #expect(MCPValue.string("x").arrayValue == nil)
        #expect((["k": "v"] as MCPValue)["k"] == .string("v"))
        #expect(MCPValue.array([])["k"] == nil)
    }
}
