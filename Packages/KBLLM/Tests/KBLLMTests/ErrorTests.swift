import Foundation
import KBLLM
import Testing

/// A foreign, non-typed error. It is deliberately NOT a `KBLLMError`, so a test that
/// sees a `KBLLMError` come out of the core has witnessed a real conversion, not a
/// hand-built enum value being re-thrown.
private struct BoomError: Error {
    let label = "BoomError-detail"
}

/// An adapter whose `stream` surfaces the foreign error. Both core normalization choke
/// points are driven through this same fake.
private struct FailingModel: LanguageModel {
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, any Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: BoomError())
        }
    }
}

@Suite struct ErrorTests {
    /// Every case carries an actionable payload beyond a bare message. The `switch` has
    /// no `default`, so a new case cannot be added without extending this test.
    @Test func everyCaseCarriesActionablePayload() {
        let samples: [KBLLMError] = [
            .transport(url: "https://api.example.com/v1", underlying: "connection reset"),
            .httpStatus(code: 429, message: "rate limited"),
            .missingCredential(key: "OPENAI_API_KEY"),
            .decoding(expected: "an SSE data frame", fragment: "{partial"),
            .unknownTool(name: "search"),
            .invalidRequest(field: "messages", reason: "must not be empty"),
            .upstream(cause: "some foreign failure"),
            .unavailable(reason: "appleIntelligenceNotEnabled"),
            .schemaViolation(expected: "a JSON object with required keys [\"title\"]", received: "{\"title\":")
        ]
        for error in samples {
            #expect(actionablePayloadIsPresent(error))
        }
    }

    private func actionablePayloadIsPresent(_ error: KBLLMError) -> Bool {
        switch error {
        case .transport(let url, let underlying):
            !url.isEmpty && !underlying.isEmpty
        case .httpStatus(let code, let message):
            code != 0 && !message.isEmpty
        case .missingCredential(let key):
            !key.isEmpty
        case .decoding(let expected, let fragment):
            !expected.isEmpty && !fragment.isEmpty
        case .unknownTool(let name):
            !name.isEmpty
        case .invalidRequest(let field, let reason):
            !field.isEmpty && !reason.isEmpty
        case .upstream(let cause):
            !cause.isEmpty
        case .unavailable(let reason):
            !reason.isEmpty
        case .schemaViolation(let expected, let received):
            !expected.isEmpty && !received.isEmpty
        case .cancelled:
            // Cancellation carries no payload because there is nothing to act on: the caller
            // asked for it. The case exists so it stays distinguishable from a fault.
            true
        }
    }

    @Test func collectedPathConvertsForeignErrorToTypedCase() async {
        do {
            _ = try await FailingModel().complete(ModelRequest(messages: []))
            Issue.record("expected the collected path to throw")
        } catch {
            // `complete` has typed throws, so `error` is a KBLLMError.
            guard case .upstream(let cause) = error else {
                Issue.record("expected .upstream, got \(error)")
                return
            }
            #expect(cause.contains("BoomError"))
        }
    }

    @Test func decoratedStreamConvertsForeignErrorToTypedCase() async {
        let decorated = FailingModel().normalizingErrors()
        do {
            for try await _ in decorated.stream(ModelRequest(messages: [])) {
                Issue.record("expected no events before the throw")
            }
            Issue.record("expected the decorated stream to throw")
        } catch let error as KBLLMError {
            guard case .upstream(let cause) = error else {
                Issue.record("expected .upstream, got \(error)")
                return
            }
            #expect(cause.contains("BoomError"))
        } catch {
            Issue.record("expected a KBLLMError, got a foreign error: \(error)")
        }
    }

    @Test func errorIsSendableAndError() {
        let value: any (Error & Sendable) = KBLLMError.unknownTool(name: "search")
        #expect(value is KBLLMError)
    }
}

@Suite("What a failure says to a person")
struct ErrorDescriptionTests {
    /// The failure this rules out: a caller doing `error as? any LocalizedError` got nil, so a
    /// server explaining exactly what was wrong was shown as "something went wrong".
    @Test("Every case describes itself")
    func everyCaseHasWords() {
        let cases: [KBLLMError] = [
            .transport(url: "https://example.invalid", underlying: "no route"),
            .httpStatus(code: 400, message: "This is not a chat model."),
            .missingCredential(key: "openai-api-key"),
            .decoding(expected: "an object", fragment: "["),
            .unknownTool(name: "logFood"),
            .invalidRequest(field: "model", reason: "is required"),
            .upstream(cause: "something foreign"),
            .cancelled,
            .unavailable(reason: "No on-device model here."),
            .schemaViolation(expected: "an object", received: "prose")
        ]
        for failure in cases {
            let described = (failure as any LocalizedError).errorDescription
            #expect(described?.isEmpty == false, "\(failure) describes itself as nothing")
        }
    }

    /// The server knows why, and paraphrasing it would drop the one detail the reader needs.
    @Test("A rejected request carries the server's own words through")
    func serverWordsSurvive() {
        let failure = KBLLMError.httpStatus(code: 400, message: "This is not a chat model.")
        let described = failure.errorDescription ?? ""
        #expect(described.contains("400"))
        #expect(described.contains("This is not a chat model."))
    }

    @Test("A status with no body still says what happened")
    func emptyBodyStillReads() {
        #expect(KBLLMError.httpStatus(code: 503, message: "").errorDescription == "The server answered 503.")
    }
}
