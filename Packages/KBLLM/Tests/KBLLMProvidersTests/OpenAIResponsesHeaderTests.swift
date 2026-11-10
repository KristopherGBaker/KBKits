import Foundation
import KBLLM
import KBLLMOpenAI
import Testing

/// The headers `OpenAIResponsesModel` sends, read off the recorded `HTTPRequestSpec`: the two rules
/// `OpenAIModel.requestHeaders` documents must hold on the Responses wire too — the adapter's own headers win over a
/// caller's `extraHeaders` in ANY letter case (HTTP header names are case-insensitive, so a case-variant duplicate
/// would ride beside the adapter's and the transport would pick one), and an EMPTY secret sends no `Authorization`
/// header at all (a keyless server, or one that takes its key in a caller-supplied header of its own). Offline.
@Suite struct OpenAIResponsesHeaderTests {

    /// Build a Responses model over a recording transport, drive one request through the real `stream` path, and
    /// return the headers of the spec the transport saw.
    private func sentHeaders(secret: String, extraHeaders: [String: String]) async throws -> [String: String] {
        let transport = RecordingTransport(.replay(Fixtures.responsesText))
        let model = OpenAIResponsesModel(
            model: "gpt-6-astra", credentialKey: "OPENAI_API_KEY", extraHeaders: extraHeaders,
            transport: transport, credentials: FakeCredentialStore(response: .secret(secret))
        )
        let result = await collect(model, ModelRequest(messages: [Message(role: .user, text: "Weather?")]))
        #expect(result.error == nil)
        let spec = try #require(transport.requests.get().first)
        return spec.headers
    }

    /// Every sent header whose name lowercases to `name`. A case-variant duplicate riding beside the adapter's
    /// header is exactly the defect under test, so no lookup here goes through the exact-match subscript.
    private func matching(_ headers: [String: String], _ name: String) -> [(name: String, value: String)] {
        headers.filter { $0.key.lowercased() == name }.map { (name: $0.key, value: $0.value) }
    }

    /// (a) A caller's lowercase `authorization` neither rides beside nor replaces the adapter's `Authorization`.
    @Test func aCallersLowercaseAuthorizationLosesToTheAdapters() async throws {
        let headers = try await sentHeaders(
            secret: sentinelSecret, extraHeaders: ["authorization": "Bearer attacker"]
        )
        let auth = matching(headers, "authorization")
        #expect(auth.count == 1, "exactly one authorization header, the adapter's: \(auth)")
        #expect(auth.first?.value == "Bearer \(sentinelSecret)")
    }

    /// (b) A caller's case-variant `Content-Type` neither rides beside nor replaces the adapter's `content-type`.
    @Test func aCallersCaseVariantContentTypeLosesToTheAdapters() async throws {
        let headers = try await sentHeaders(secret: sentinelSecret, extraHeaders: ["Content-Type": "text/plain"])
        let contentType = matching(headers, "content-type")
        #expect(contentType.count == 1, "exactly one content-type header, the adapter's: \(contentType)")
        #expect(contentType.first?.value == "application/json")
    }

    /// (c) An empty secret sends NO Authorization header, not a bare `Bearer `.
    @Test func anEmptySecretSendsNoAuthorizationHeaderAtAll() async throws {
        let headers = try await sentHeaders(secret: "", extraHeaders: [:])
        #expect(matching(headers, "authorization").isEmpty)
    }

    /// (d) With an empty secret, a caller's own `Authorization` is the one sent (the keyless server that takes its
    /// key in a header of the caller's own).
    @Test func anEmptySecretKeepsTheCallersOwnAuthorization() async throws {
        let headers = try await sentHeaders(secret: "", extraHeaders: ["Authorization": "Bearer caller-key"])
        let auth = matching(headers, "authorization")
        #expect(auth.count == 1)
        #expect(auth.first?.value == "Bearer caller-key")
    }

    /// (e) A caller header that collides with nothing is sent intact.
    @Test func aNonCollidingCallerHeaderIsKeptIntact() async throws {
        let headers = try await sentHeaders(secret: sentinelSecret, extraHeaders: ["X-Title": "Aside"])
        #expect(headers["X-Title"] == "Aside")
    }
}
