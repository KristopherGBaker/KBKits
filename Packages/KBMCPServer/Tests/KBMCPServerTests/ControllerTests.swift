import Foundation
import Testing
@testable import KBMCPServer

@MainActor
@Suite struct ControllerTests {
    let nonce = UUID().uuidString

    private func controller(port: UInt16 = 0, token: String = "abc", enabled: Bool) -> MCPServerController {
        MCPServerController(port: port, token: token, isEnabled: enabled, handler: makeHandler(nonce: nonce))
    }

    @Test func tokensAre64LowercaseHexAndFresh() throws {
        let first = MCPServerController.makeToken()
        let second = MCPServerController.makeToken()
        #expect(first.count == 64)
        #expect(try Regex("^[0-9a-f]{64}$").wholeMatch(in: first) != nil)
        #expect(try Regex("^[0-9a-f]{64}$").wholeMatch(in: second) != nil)
        #expect(first != second)
    }

    @Test func claudeCodeCommandUsesTheConfiguredPortWhenStopped() {
        let stopped = controller(port: MCPServerController.defaultPort, enabled: true)
        #expect(MCPServerController.defaultPort == 47821)
        #expect(stopped.endpoint == "http://127.0.0.1:47821/mcp")
        #expect(stopped.claudeCodeCommand(name: "myapp")
            == "claude mcp add --transport http myapp http://127.0.0.1:47821/mcp --header \"Authorization: Bearer abc\"")
    }

    @Test func disabledControllerDoesNotStart() async {
        let disabled = controller(enabled: false)
        await disabled.start()
        #expect(disabled.state == .stopped)
        disabled.stop()
    }

    @Test func enableRegenerateAndDisable() async throws {
        let first = "t1-\(nonce)"
        let subject = controller(token: first, enabled: false)
        await subject.setEnabled(true)
        guard case .running(let port) = subject.state, port != 0 else {
            Issue.record("not running: \(subject.state)")
            return
        }
        #expect(subject.isEnabled)
        #expect(subject.endpoint == "http://127.0.0.1:\(port)/mcp")
        #expect(subject.claudeCodeCommand(name: "n").contains("http://127.0.0.1:\(port)/mcp"))
        #expect(try await post(port: port, token: first, body: pingBody).status == 200)

        let second = await subject.regenerateToken()
        #expect(second != first && subject.token == second)
        guard case .running(let newPort) = subject.state else {
            Issue.record("not running after regenerate: \(subject.state)")
            return
        }
        #expect(try await post(port: newPort, token: first, body: pingBody).status == 401)
        #expect(try await post(port: newPort, token: second, body: pingBody).status == 200)

        await subject.setEnabled(false)
        #expect(subject.state == .stopped)
        #expect(!subject.isEnabled)
        #expect(await refusesConnections(port: newPort, within: .seconds(2)))
    }

    @Test func setPortIgnoresPrivilegedPortsAndRestartsOnValidOnes() async throws {
        let subject = controller(token: "t-\(nonce)", enabled: true)
        await subject.start()
        guard case .running(let ephemeral) = subject.state, ephemeral != 0 else {
            Issue.record("not running: \(subject.state)")
            return
        }
        defer { subject.stop() }

        await subject.setPort(80)
        #expect(subject.port == 0)
        #expect(subject.state == .running(port: ephemeral))

        let fixed = UInt16.random(in: 50000...59000)
        await subject.setPort(fixed)
        #expect(subject.port == fixed)
        #expect(subject.state == .running(port: fixed))
        #expect(try await post(port: fixed, token: "t-\(nonce)", body: pingBody).status == 200)

        await subject.setPort(0)
        #expect(subject.port == 0)
        guard case .running(let again) = subject.state, again != 0 else {
            Issue.record("not restarted on port 0: \(subject.state)")
            return
        }
        #expect(try await post(port: again, token: "t-\(nonce)", body: pingBody).status == 200)
    }

    @Test func setPortWhileDisabledOnlyRecordsIt() async {
        let subject = controller(port: 0, enabled: false)
        await subject.setPort(50123)
        #expect(subject.port == 50123)
        #expect(subject.state == .stopped)
        #expect(subject.endpoint == "http://127.0.0.1:50123/mcp")
    }
}
