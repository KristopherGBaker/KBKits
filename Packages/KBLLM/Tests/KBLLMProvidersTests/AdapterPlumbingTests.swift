import Foundation
import KBLLM
import KBLLMAnthropic
import KBLLMOpenAI
import Testing

// The plumbing every HTTP adapter needs, pinned through each adapter's real `stream` (or
// `listModels`) path over the recording fake transport, so the pins hold whichever module
// the helpers live in: the bounded raw-body tap behind the "2xx with no usable event"
// diagnostic, the secret's redaction from a foreign transport error, the credential fetch
// mapped onto `.missingCredential`, the base URL joined to the provider path, and the
// sorted-keys body serializer with each wire's slash policy. Offline.

/// One streaming adapter under test, with the key it asks its store for and its transport.
private struct Adapter {
    let name: String
    let credentialKey: String
    let model: any LanguageModel
    let transport: RecordingTransport
}

@Suite struct AdapterPlumbingTests {
    /// The three streaming adapters, each over its own transport with `behavior`, each with a
    /// distinct credential key so a `.missingCredential` names the adapter's own.
    private static func everyAdapter(
        _ behavior: RecordingTransport.Behavior,
        secret: FakeCredentialStore.Response = .secret(sentinelSecret),
        anthropicBase: String = "https://api.anthropic.com",
        openAIBase: String = "https://api.openai.com/v1"
    ) -> [Adapter] {
        let credentials = FakeCredentialStore(response: secret)
        let anthropic = RecordingTransport(behavior)
        let chat = RecordingTransport(behavior)
        let responses = RecordingTransport(behavior)
        return [
            Adapter(
                name: "Anthropic", credentialKey: "PLUMBING_ANTHROPIC_KEY",
                model: AnthropicModel(
                    model: "claude-3-5-sonnet-20241022", credentialKey: "PLUMBING_ANTHROPIC_KEY",
                    baseURL: anthropicBase, transport: anthropic, credentials: credentials
                ),
                transport: anthropic
            ),
            Adapter(
                name: "Chat Completions", credentialKey: "PLUMBING_CHAT_KEY",
                model: OpenAIModel(
                    model: "gpt-4o", credentialKey: "PLUMBING_CHAT_KEY",
                    baseURL: openAIBase, transport: chat, credentials: credentials
                ),
                transport: chat
            ),
            Adapter(
                name: "Responses", credentialKey: "PLUMBING_RESPONSES_KEY",
                model: OpenAIResponsesModel(
                    model: "gpt-6-astra", credentialKey: "PLUMBING_RESPONSES_KEY",
                    baseURL: openAIBase, transport: responses, credentials: credentials
                ),
                transport: responses
            )
        ]
    }

    /// A 200 body of exactly `byteCount` ASCII bytes that is a plain JSON error object, not an
    /// event stream, so every adapter drains it to zero usable events.
    private static func plainJSONBody(byteCount: Int) -> [UInt8] {
        let head = #"{"error":""#
        let tail = #""}"#
        let filler = String(repeating: "x", count: byteCount - head.utf8.count - tail.utf8.count)
        return Array((head + filler + tail).utf8)
    }

    private static func decodingFragment(_ result: Collected) -> String? {
        guard case .decoding(_, let fragment) = result.error else { return nil }
        return fragment
    }

    private static func transportUnderlying(_ result: Collected) -> String? {
        guard case .transport(_, let underlying) = result.error else { return nil }
        return underlying
    }

    // MARK: The bounded body tap

    @Test func aNoUsableEventFragmentIsExactlyTheBodysFirst512Bytes() async {
        let long = Self.plainJSONBody(byteCount: 700)
        let expected = String(decoding: long.prefix(512), as: UTF8.self)
        for adapter in Self.everyAdapter(.replay(long)) {
            let fragment = Self.decodingFragment(await collect(adapter.model, weatherRequest))
            #expect(fragment == expected, "\(adapter.name)")
            #expect(fragment?.utf8.count == 512, "\(adapter.name)")
        }
    }

    @Test func aNoUsableEventFragmentOfAShortBodyIsTheWholeBody() async {
        let short = Self.plainJSONBody(byteCount: 40)
        for adapter in Self.everyAdapter(.replay(short)) {
            let fragment = Self.decodingFragment(await collect(adapter.model, weatherRequest))
            #expect(fragment == String(decoding: short, as: UTF8.self), "\(adapter.name)")
        }
    }

    // MARK: Redaction

    @Test func aSecretInAForeignTransportErrorIsReplacedAndTheRestKept() async {
        for adapter in Self.everyAdapter(.foreign(detail: "reset before \(sentinelSecret) after")) {
            let underlying = Self.transportUnderlying(await collect(adapter.model, weatherRequest))
            #expect(underlying == "ForeignFailure: reset before [redacted] after", "\(adapter.name)")
        }
    }

    @Test func aForeignErrorWithoutTheSecretIsUnchanged() async {
        for adapter in Self.everyAdapter(.foreign(detail: "connection refused")) {
            let underlying = Self.transportUnderlying(await collect(adapter.model, weatherRequest))
            #expect(underlying == "ForeignFailure: connection refused", "\(adapter.name)")
        }
    }

    @Test func anEmptySecretRedactsNothing() async {
        for adapter in Self.everyAdapter(.foreign(detail: "connection refused"), secret: .secret("")) {
            let underlying = Self.transportUnderlying(await collect(adapter.model, weatherRequest))
            #expect(underlying == "ForeignFailure: connection refused", "\(adapter.name)")
        }
    }

    // MARK: The credential fetch

    @Test func aMissingSecretIsMissingCredentialNamingTheAdaptersKeyAndNothingOpens() async {
        for adapter in Self.everyAdapter(.replay(Fixtures.openAIWeather), secret: .missing) {
            let result = await collect(adapter.model, weatherRequest)
            #expect(result.error == .missingCredential(key: adapter.credentialKey), "\(adapter.name)")
            #expect(result.events.isEmpty, "\(adapter.name)")
            #expect(adapter.transport.openCount.get() == 0, "\(adapter.name)")
        }
    }

    @Test func aMissingSecretFailsEitherModelListBeforeAnyRequest() async {
        let missing = FakeCredentialStore(response: .missing)
        let anthropicTransport = ListTransport(json: ListFixtures.anthropicPage2)
        let anthropic = AnthropicModelList(
            credentialKey: "PLUMBING_ANTHROPIC_LIST_KEY", transport: anthropicTransport, credentials: missing
        )
        await #expect(throws: KBLLMError.missingCredential(key: "PLUMBING_ANTHROPIC_LIST_KEY")) {
            try await anthropic.listModels()
        }
        #expect(anthropicTransport.requests.get().isEmpty)

        let openAITransport = ListTransport(json: ListFixtures.openAI)
        let openAI = OpenAIModelList(
            credentialKey: "PLUMBING_OPENAI_LIST_KEY", transport: openAITransport, credentials: missing
        )
        await #expect(throws: KBLLMError.missingCredential(key: "PLUMBING_OPENAI_LIST_KEY")) {
            try await openAI.listModels()
        }
        #expect(openAITransport.requests.get().isEmpty)
    }

    @Test func anEmptySecretSendsNoAuthorizationOnEitherOpenAIWire() async throws {
        let request = ModelRequest(messages: [Message(role: .user, text: "hello")])
        let (chat, chatTransport) = makeOpenAI(
            .replay(Fixtures.openAIWeather), credentials: FakeCredentialStore(response: .secret(""))
        )
        #expect(await collect(chat, request).error == nil)
        let chatHeaders = try #require(chatTransport.requests.get().first?.headers)
        #expect(!chatHeaders.keys.contains { $0.lowercased() == "authorization" })

        let (responses, responsesTransport) = makeResponses(
            .replay(Fixtures.responsesText), credentials: FakeCredentialStore(response: .secret(""))
        )
        #expect(await collect(responses, request).error == nil)
        let responsesHeaders = try #require(responsesTransport.requests.get().first?.headers)
        #expect(!responsesHeaders.keys.contains { $0.lowercased() == "authorization" })
    }

    // MARK: The endpoint join

    /// The URL each adapter's transport was asked to open, by adapter name.
    private static func openedURLs(anthropicBase: String, openAIBase: String) async -> [String: String] {
        var urls: [String: String] = [:]
        let adapters = everyAdapter(
            .foreign(detail: "unreachable"), anthropicBase: anthropicBase, openAIBase: openAIBase
        )
        for adapter in adapters {
            _ = await collect(adapter.model, weatherRequest)
            urls[adapter.name] = adapter.transport.requests.get().first?.url
        }
        return urls
    }

    @Test func theEndpointIsTheBaseFollowedByTheProviderPath() async {
        let urls = await Self.openedURLs(anthropicBase: "http://localhost:8080", openAIBase: "http://localhost:1234/v1")
        #expect(urls == [
            "Anthropic": "http://localhost:8080/v1/messages",
            "Chat Completions": "http://localhost:1234/v1/chat/completions",
            "Responses": "http://localhost:1234/v1/responses"
        ])
    }

    @Test func aTrailingSlashOnTheBaseIsJoinedAsWrittenNotNormalized() async {
        let urls = await Self.openedURLs(
            anthropicBase: "http://localhost:8080/", openAIBase: "http://localhost:1234/v1/"
        )
        #expect(urls == [
            "Anthropic": "http://localhost:8080//v1/messages",
            "Chat Completions": "http://localhost:1234/v1//chat/completions",
            "Responses": "http://localhost:1234/v1//responses"
        ])
    }

    @Test func aMalformedBaseIsInvalidRequestAndNothingOpens() async {
        let adapters = Self.everyAdapter(
            .replay(Fixtures.openAIWeather), anthropicBase: "http://exa mple", openAIBase: "http://exa mple"
        )
        for adapter in adapters {
            let result = await collect(adapter.model, weatherRequest)
            #expect(
                result.error == .invalidRequest(field: "baseURL", reason: "malformed base URL: http://exa mple"),
                "\(adapter.name)"
            )
            #expect(adapter.transport.openCount.get() == 0, "\(adapter.name)")
        }
    }

    // MARK: The body serializer

    /// `body` parsed and written again with `options`: equal bytes mean `body` was written
    /// with exactly that key order and slash escaping.
    private static func rewritten(_ body: Data, options: JSONSerialization.WritingOptions) -> Data? {
        let object = try? JSONSerialization.jsonObject(with: body)
        return object.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: options) }
    }

    @Test func eachWireKeepsItsSortedKeyAndSlashPolicy() async throws {
        let slashed = ModelRequest(messages: [Message(role: .user, text: "a/b")])

        // Chat Completions: sorted keys, slashes escaped.
        let (chat, chatTransport) = makeOpenAI(.replay(Fixtures.openAIWeather))
        _ = await collect(chat, slashed)
        let chatBody = try #require(chatTransport.requests.get().first?.body)
        #expect(chatBody == Self.rewritten(chatBody, options: [.sortedKeys]))
        #expect(String(decoding: chatBody, as: UTF8.self).contains(#""a\/b""#))

        // Responses: sorted keys, slashes always written verbatim.
        let (responses, responsesTransport) = makeResponses(.replay(Fixtures.responsesText))
        _ = await collect(responses, slashed)
        let responsesBody = try #require(responsesTransport.requests.get().first?.body)
        #expect(responsesBody == Self.rewritten(responsesBody, options: [.sortedKeys, .withoutEscapingSlashes]))
        #expect(String(decoding: responsesBody, as: UTF8.self).contains(#""a/b""#))

        // Anthropic: sorted keys; slashes escaped on a plain request, verbatim on a search one.
        let (plain, plainTransport) = makeAnthropic(.replay(Fixtures.anthropicWithUsage))
        _ = await collect(plain, slashed)
        let plainBody = try #require(plainTransport.requests.get().first?.body)
        #expect(plainBody == Self.rewritten(plainBody, options: [.sortedKeys]))
        #expect(String(decoding: plainBody, as: UTF8.self).contains(#""a\/b""#))

        let (searching, searchingTransport) = makeAnthropic(.replay(Fixtures.anthropicWithUsage))
        _ = await collect(
            searching, ModelRequest(messages: [Message(role: .user, text: "a/b")], webSearch: WebSearchOptions())
        )
        let searchingBody = try #require(searchingTransport.requests.get().first?.body)
        #expect(searchingBody == Self.rewritten(searchingBody, options: [.sortedKeys, .withoutEscapingSlashes]))
        #expect(String(decoding: searchingBody, as: UTF8.self).contains(#""a/b""#))
    }

    #if os(macOS) || os(Linux)
    /// A body JSON cannot carry (a non-finite temperature, which Chat Completions forwards as
    /// given) fails as `.invalidRequest` naming the body, before the transport opens. Run in a
    /// child process: Foundation documents that writing an invalid JSON object may raise
    /// rather than throw, and a raise must fail this test, not take the whole suite down.
    @Test func anUnserializableBodyIsInvalidRequestAndNothingOpens() async {
        await #expect(processExitsWith: .success) {
            let request = ModelRequest(
                messages: [Message(role: .user, text: "hello")],
                options: GenerationOptions(temperature: .nan)
            )
            let (chat, transport) = makeOpenAI(.replay(Fixtures.openAIWeather))
            let result = await collect(chat, request)
            let unserializable = KBLLMError.invalidRequest(
                field: "body", reason: "request body could not be serialized"
            )
            guard result.error == unserializable, transport.openCount.get() == 0 else { exit(1) }
        }
    }
    #endif
}
