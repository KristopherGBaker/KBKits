import Foundation
import KBLLM
import Testing

/// The core's adapter plumbing called directly (it is `package`, so this test target of the same
/// package reaches it): the cases an adapter's stream cannot produce, such as a nil secret,
/// beside the ones `AdapterPlumbingTests` pins through every adapter.
@Suite struct AdapterPlumbingCoreTests {
    // MARK: The bounded body tap

    @Test func theBodyPrefixKeepsTheFirst512BytesAndNoMore() {
        let prefix = BodyPrefix()
        let body = (0..<700).map { UInt8(ascii: "a") + UInt8($0 % 26) }
        for byte in body { prefix.append(byte) }
        #expect(prefix.fragment == String(decoding: body.prefix(512), as: UTF8.self))
    }

    @Test func aShortBodyIsKeptWhole() {
        let prefix = BodyPrefix()
        for byte in Array(#"{"error":"short"}"#.utf8) { prefix.append(byte) }
        #expect(prefix.fragment == #"{"error":"short"}"#)
    }

    @Test func tappingForwardsEveryByteUnchangedAndKeepsThePrefix() async throws {
        let body = Array(String(repeating: "0123456789", count: 60).utf8)
        let upstream = AsyncThrowingStream<UInt8, any Error> { continuation in
            for byte in body { continuation.yield(byte) }
            continuation.finish()
        }
        let prefix = BodyPrefix()
        var forwarded: [UInt8] = []
        for try await byte in tapping(upstream, into: prefix) { forwarded.append(byte) }
        #expect(forwarded == body)
        #expect(prefix.fragment == String(decoding: body.prefix(512), as: UTF8.self))
    }

    @Test func tappingPassesAnUpstreamErrorThrough() async {
        let upstream = AsyncThrowingStream<UInt8, any Error> { continuation in
            continuation.yield(UInt8(ascii: "x"))
            continuation.finish(throwing: KBLLMError.httpStatus(code: 500, message: "boom"))
        }
        let prefix = BodyPrefix()
        await #expect(throws: KBLLMError.httpStatus(code: 500, message: "boom")) {
            for try await _ in tapping(upstream, into: prefix) {}
        }
        #expect(prefix.fragment == "x")
    }

    // MARK: Redaction

    @Test func redactionReplacesEveryOccurrenceAndKeepsTheRest() {
        #expect(AdapterPlumbing.redact("before sk-1 after", secret: "sk-1") == "before [redacted] after")
        #expect(AdapterPlumbing.redact("sk-1 and sk-1", secret: "sk-1") == "[redacted] and [redacted]")
    }

    @Test func redactionLeavesTextAloneWithoutASecretToFind() {
        #expect(AdapterPlumbing.redact("connection refused", secret: "sk-1") == "connection refused")
        #expect(AdapterPlumbing.redact("connection refused", secret: "") == "connection refused")
        #expect(AdapterPlumbing.redact("connection refused", secret: nil) == "connection refused")
    }

    // MARK: The endpoint join

    @Test func theEndpointIsBaseThenSuffixAsWritten() throws {
        #expect(try AdapterPlumbing.composeEndpoint(base: "http://localhost:1234/v1", suffix: "/responses")
            == "http://localhost:1234/v1/responses")
        #expect(try AdapterPlumbing.composeEndpoint(base: "http://localhost:1234/v1/", suffix: "/responses")
            == "http://localhost:1234/v1//responses")
    }

    @Test func aMalformedBaseIsInvalidRequestNamingTheBase() {
        #expect(throws: KBLLMError.invalidRequest(field: "baseURL", reason: "malformed base URL: http://exa mple")) {
            try AdapterPlumbing.composeEndpoint(base: "http://exa mple", suffix: "/responses")
        }
    }

    // MARK: The credential fetch

    @Test func aStoredSecretIsReturnedAsIsEvenWhenEmpty() async throws {
        #expect(try await StubStore(secret: "sk-1").resolvedSecret(forKey: "K") == "sk-1")
        #expect(try await StubStore(secret: "").resolvedSecret(forKey: "K") == "")
    }

    @Test func aStoreThatCannotSupplyTheKeyIsMissingCredentialNamingIt() async {
        await #expect(throws: KBLLMError.missingCredential(key: "PLUMBING_KEY")) {
            try await StubStore(secret: nil).resolvedSecret(forKey: "PLUMBING_KEY")
        }
    }

    // MARK: The body serializer

    @Test func keysAreAlwaysSortedAndTheCallersOptionsAdded() throws {
        let nested: [String: Any] = ["y": true, "b": NSNull()]
        let body: [String: Any] = ["z": "a/b", "a": 1, "m": nested]
        let plain = try AdapterPlumbing.serialize(body)
        #expect(String(decoding: plain, as: UTF8.self) == #"{"a":1,"m":{"b":null,"y":true},"z":"a\/b"}"#)
        let sorted = try AdapterPlumbing.serialize(body, options: [.sortedKeys])
        #expect(sorted == plain)
        let verbatim = try AdapterPlumbing.serialize(body, options: [.sortedKeys, .withoutEscapingSlashes])
        #expect(String(decoding: verbatim, as: UTF8.self) == #"{"a":1,"m":{"b":null,"y":true},"z":"a/b"}"#)
    }

    @Test func aBodyJSONCannotCarryIsInvalidRequestNamingTheBody() {
        let unserializable = KBLLMError.invalidRequest(field: "body", reason: "request body could not be serialized")
        #expect(throws: unserializable) { try AdapterPlumbing.serialize(["temperature": Double.nan]) }
        #expect(throws: unserializable) { try AdapterPlumbing.serialize(["top_p": Double.infinity]) }
    }
}

/// A store that holds one secret for every key, or none.
private struct StubStore: CredentialStore {
    let stored: String?

    init(secret: String?) {
        stored = secret
    }

    func secret(forKey key: String) async throws -> String {
        guard let stored else { throw StubStoreMiss() }
        return stored
    }
}

private struct StubStoreMiss: Error {}
