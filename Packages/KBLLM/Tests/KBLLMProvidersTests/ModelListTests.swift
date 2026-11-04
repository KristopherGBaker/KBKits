import Foundation
import KBLLM
import KBLLMAnthropic
import KBLLMOpenAI
import Testing

/// A fake transport for the whole-response path the model lists use: it records each request and answers the Nth with the
/// Nth canned response (the last repeating). Nothing reaches the network.
final class ListTransport: HTTPTransport, @unchecked Sendable {
    let responses: [HTTPResponseSpec]
    let requests = Box<[HTTPRequestSpec]>([])

    init(_ responses: [HTTPResponseSpec]) {
        self.responses = responses
    }

    convenience init(json: String, status: Int = 200) {
        self.init([HTTPResponseSpec(status: status, body: Data(json.utf8))])
    }

    func send(_ request: HTTPRequestSpec) async throws -> HTTPResponseSpec {
        let count = requests.mutate { list -> Int in
            list.append(request)
            return list.count
        }
        return responses[min(count, responses.count) - 1]
    }

    func openBytes(_ request: HTTPRequestSpec) -> AsyncThrowingStream<UInt8, any Error> {
        AsyncThrowingStream { $0.finish(throwing: KBLLMError.transport(url: request.url, underlying: "lists never stream")) }
    }
}

/// Recorded list responses, in each provider's documented shape.
enum ListFixtures {
    static let openAI = """
        {"object":"list","data":[
          {"id":"gpt-6.1-sol","object":"model","created":1790000000,"owned_by":"openai"},
          {"id":"gpt-6-luna","object":"model","created":1780000000,"owned_by":"openai"}
        ]}
        """
    static let anthropicPage1 = """
        {"data":[{"type":"model","id":"claude-opus-5-5","display_name":"Claude Opus 5.5","created_at":"2026-09-01T00:00:00Z"}],
         "has_more":true,"first_id":"claude-opus-5-5","last_id":"claude-opus-5-5"}
        """
    static let anthropicPage2 = """
        {"data":[{"type":"model","id":"claude-haiku-5-5","display_name":"Claude Haiku 5.5","created_at":"2026-08-01T00:00:00Z"}],
         "has_more":false,"first_id":"claude-haiku-5-5","last_id":"claude-haiku-5-5"}
        """
    /// A catalog that is a bare array with `name`s (GitHub Models' shape).
    static let catalog = """
        [{"id":"openai/gpt-5","name":"OpenAI GPT-5"},{"name":"no id"},{"id":"meta/llama-4","name":""}]
        """
}

@Suite struct ModelListTests {
    @Test func openAIListsModelsWithBearerAndExtraHeaders() async throws {
        let transport = ListTransport(json: ListFixtures.openAI)
        let list = OpenAIModelList(
            baseURL: "https://api.example.test/v1/", credentialKey: "K", extraHeaders: ["X-Title": "Aside", "Content-Type": "x"],
            transport: transport, credentials: FakeCredentialStore(response: .secret(sentinelSecret))
        )
        let models = try await list.listModels()
        #expect(models.map(\.id) == ["gpt-6.1-sol", "gpt-6-luna"])
        #expect(models.first?.created == Date(timeIntervalSince1970: 1_790_000_000))
        let request = try #require(transport.requests.get().first)
        #expect(request.method == .get)
        #expect(request.url == "https://api.example.test/v1/models")
        #expect(request.headers["Authorization"] == "Bearer \(sentinelSecret)")
        #expect(request.headers["X-Title"] == "Aside")
        #expect(request.headers.keys.allSatisfy { $0.lowercased() != "content-type" })
        #expect(request.body == nil)
    }

    @Test func openAIListWithAnEmptyKeySendsNoAuthorization() async throws {
        let transport = ListTransport(json: ListFixtures.openAI)
        let list = OpenAIModelList(
            baseURL: "http://localhost:1234/v1", credentialKey: "K", extraHeaders: ["x-api-key": "header-key"],
            transport: transport, credentials: FakeCredentialStore(response: .secret(""))
        )
        _ = try await list.listModels()
        let headers = try #require(transport.requests.get().first).headers
        #expect(headers.keys.allSatisfy { $0.lowercased() != "authorization" })
        #expect(headers["x-api-key"] == "header-key")
    }

    @Test func aCatalogURLAndABareArrayAreRead() async throws {
        let transport = ListTransport(json: ListFixtures.catalog)
        let list = OpenAIModelList(
            url: "https://models.example.test/catalog/models", credentialKey: "K", transport: transport,
            credentials: FakeCredentialStore(response: .secret("t"))
        )
        let models = try await list.listModels()
        #expect(models == [ListedModel(id: "openai/gpt-5", displayName: "OpenAI GPT-5"), ListedModel(id: "meta/llama-4")])
        #expect(transport.requests.get().first?.url == "https://models.example.test/catalog/models")
    }

    @Test func aRejectedOrUnreadableListThrows() async {
        let rejected = OpenAIModelList(
            credentialKey: "K", transport: ListTransport(json: "{\"error\":\"bad key\"}", status: 401),
            credentials: FakeCredentialStore(response: .secret("k"))
        )
        await #expect(throws: KBLLMError.httpStatus(code: 401, message: "{\"error\":\"bad key\"}")) { try await rejected.listModels() }
        let garbled = OpenAIModelList(
            credentialKey: "K", transport: ListTransport(json: "<html>"), credentials: FakeCredentialStore(response: .secret("k"))
        )
        await #expect { try await garbled.listModels() } throws: { error in
            if case .decoding = error as? KBLLMError { return true }
            return false
        }
        let keyless = OpenAIModelList(
            credentialKey: "K", transport: ListTransport(json: ListFixtures.openAI), credentials: FakeCredentialStore(response: .missing)
        )
        await #expect(throws: KBLLMError.missingCredential(key: "K")) { try await keyless.listModels() }
    }

    @Test func anthropicFollowsPagesWithItsOwnHeaders() async throws {
        let transport = ListTransport([
            HTTPResponseSpec(status: 200, body: Data(ListFixtures.anthropicPage1.utf8)),
            HTTPResponseSpec(status: 200, body: Data(ListFixtures.anthropicPage2.utf8))
        ])
        let list = AnthropicModelList(credentialKey: "K", transport: transport, credentials: FakeCredentialStore(response: .secret(sentinelSecret)))
        let models = try await list.listModels()
        #expect(models.map(\.id) == ["claude-opus-5-5", "claude-haiku-5-5"])
        #expect(models.map(\.displayName) == ["Claude Opus 5.5", "Claude Haiku 5.5"])
        #expect(models.first?.created == ISO8601DateFormatter().date(from: "2026-09-01T00:00:00Z"))
        let requests = transport.requests.get()
        #expect(requests.map(\.url) == [
            "https://api.anthropic.com/v1/models?limit=1000",
            "https://api.anthropic.com/v1/models?limit=1000&after_id=claude-opus-5-5"
        ])
        #expect(requests.allSatisfy { $0.headers["x-api-key"] == sentinelSecret && $0.headers["anthropic-version"] == "2023-06-01" })
        #expect(requests.allSatisfy { $0.headers["Authorization"] == nil && $0.method == .get })
    }
}

/// The adapter's own headers against the caller's, in any letter case, and the empty key.
@Suite struct OpenAIHeaderTests {
    func headers(secret: String, extra: [String: String]) async -> [String: String] {
        let transport = RecordingTransport(.replay(Fixtures.openAIWeather))
        let model = OpenAIModel(
            model: "gpt-x", credentialKey: "K", extraHeaders: extra, transport: transport,
            credentials: FakeCredentialStore(response: .secret(secret))
        )
        _ = await collect(model, weatherRequest)
        return transport.requests.get().first?.headers ?? [:]
    }

    @Test func callerHeadersInAnotherCaseNeverRideBesideTheAdaptersOwn() async {
        let headers = await headers(
            secret: sentinelSecret, extra: ["authorization": "Bearer attacker", "Content-Type": "text/plain", "X-Tenant": "t1"]
        )
        #expect(headers == ["Authorization": "Bearer \(sentinelSecret)", "content-type": "application/json", "X-Tenant": "t1"])
    }

    @Test func anEmptyKeySendsNoAuthorizationHeader() async {
        let keyless = await headers(secret: "", extra: [:])
        #expect(keyless == ["content-type": "application/json"])
        // With no key of its own, a server's own auth header (here a non-Bearer Authorization) is the caller's to send.
        let own = await headers(secret: "", extra: ["Authorization": "Basic dXNlcjpwYXNz", "content-type": "text/plain"])
        #expect(own == ["Authorization": "Basic dXNlcjpwYXNz", "content-type": "application/json"])
    }
}
