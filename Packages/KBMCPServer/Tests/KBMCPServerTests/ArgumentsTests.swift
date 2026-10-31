import Foundation
import Testing
@testable import KBMCPServer

@Suite struct ArgumentsTests {
    let id = UUID()

    var args: MCPArguments {
        MCPArguments([
            "name": "kit",
            "empty": "",
            "count": 4,
            "flag": true,
            "tags": ["a", "b"],
            "mixed": ["a", 1],
            "scalar": "x",
            "nothing": .null,
            "id": .string(id.uuidString),
            "badID": "not-a-uuid",
            "ids": [.string(id.uuidString)],
            "badIDs": [.string(id.uuidString), "zz"]
        ])
    }

    @Test func toolErrorIsLocalized() {
        let error = MCPToolError("readable \(id)")
        #expect(error.errorDescription == "readable \(id)")
        #expect(error.localizedDescription == "readable \(id)")
        #expect(error == MCPToolError("readable \(id)"))
    }

    @Test func requiredStringRejectsMissingEmptyAndWrongType() throws {
        #expect(try args.string("name") == "kit")
        #expect(throws: MCPToolError("Missing required string argument 'absent'.")) { try args.string("absent") }
        #expect(throws: MCPToolError("Missing required string argument 'empty'.")) { try args.string("empty") }
        #expect(throws: MCPToolError("Missing required string argument 'count'.")) { try args.string("count") }
    }

    @Test func optionalScalarsNeverThrow() {
        #expect(args.optionalString("name") == "kit")
        #expect(args.optionalString("count") == nil)
        #expect(args.optionalString("absent") == nil)
        #expect(args.optionalInt("count") == 4)
        #expect(args.optionalInt("name") == nil)
        #expect(args.optionalBool("flag") == true)
        #expect(args.optionalBool("name") == nil)
    }

    @Test func stringArrays() throws {
        #expect(try args.optionalStringArray("tags") == ["a", "b"])
        #expect(try args.optionalStringArray("nothing") == nil)
        #expect(try args.optionalStringArray("absent") == nil)
        let wrong = MCPToolError("Argument 'mixed' must be an array of strings.")
        #expect(throws: wrong) { try args.optionalStringArray("mixed") }
        #expect(throws: MCPToolError("Argument 'scalar' must be an array of strings.")) {
            try args.optionalStringArray("scalar")
        }
    }

    @Test func uuids() throws {
        #expect(try args.uuid("id") == id)
        #expect(throws: MCPToolError("Argument 'badID' is not a valid UUID: not-a-uuid")) { try args.uuid("badID") }
        #expect(throws: MCPToolError("Missing required string argument 'absent'.")) { try args.uuid("absent") }
        #expect(try args.optionalUUIDArray("ids") == [id])
        #expect(try args.optionalUUIDArray("absent") == nil)
        #expect(throws: MCPToolError("'badIDs' contains an invalid UUID: zz")) { try args.optionalUUIDArray("badIDs") }
        #expect(throws: MCPToolError("Argument 'mixed' must be an array of strings.")) {
            try args.optionalUUIDArray("mixed")
        }
    }
}
