import Foundation
import KBLLM

/// A wrapper around a `LanguageModel` a caller can author OUTSIDE this package. It sees
/// the request going down and may rewrite it, and it sees the events coming back up and
/// may transform them, by choosing what it forwards to `next` and what it yields. Only
/// `stream` is intercepted, because the collected `complete` path is derived from it, so
/// one interception point covers both.
public protocol LanguageModelMiddleware: Sendable {
    func intercept(
        _ request: ModelRequest,
        next: any LanguageModel
    ) -> AsyncThrowingStream<ModelEvent, any Error>
}

/// Compose middlewares around a base model in a DECLARED order: the FIRST element is the
/// outermost wrapper, so it touches the request first and the response last. The order is
/// spelled out rather than left to insertion because a wrapping order the caller cannot
/// predict would make it unpredictable which middleware runs first; callers may `reorder`
/// the array to change it deliberately, never by accident.
public func wrap(
    _ base: any LanguageModel,
    with middlewares: [any LanguageModelMiddleware]
) -> any LanguageModel {
    var model: any LanguageModel = base
    // Wrap from the inside out: fold the LAST middleware closest to the base so the
    // FIRST middleware ends up outermost and applies first on the way down.
    for middleware in middlewares.reversed() {
        model = MiddlewareModel(middleware: middleware, next: model)
    }
    return model
}

/// The `LanguageModel` a single middleware plus its downstream collapse into. Kept next
/// to `wrap` because it is purely how composition is realized.
struct MiddlewareModel: LanguageModel {
    let middleware: any LanguageModelMiddleware
    let next: any LanguageModel

    /// The capability of the model this middleware wraps, so wrapping never hides it.
    var supportsWebSearch: Bool { next.supportsWebSearch }

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, any Error> {
        middleware.intercept(request, next: next)
    }
}

/// Middleware that logs each request and every returned event to a `LogSink`. It records
/// the request's text and each event's payload so a log reader can see what was asked and
/// what came back, which is why the records carry the fixture-specific content and not a
/// constant line.
public struct LoggingMiddleware: LanguageModelMiddleware {
    private let sink: any LogSink

    public init(sink: any LogSink) {
        self.sink = sink
    }

    public func intercept(
        _ request: ModelRequest,
        next: any LanguageModel
    ) -> AsyncThrowingStream<ModelEvent, any Error> {
        let sink = self.sink
        sink.log(.info, "request " + Self.render(request))
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in next.stream(request) {
                        sink.log(.debug, "response " + Self.render(event))
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    sink.log(.error, "response error " + String(describing: error))
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Flatten a request to its message text so the log line carries any marker a caller
    /// put in the prompt.
    private static func render(_ request: ModelRequest) -> String {
        request.messages
            .flatMap { message in
                message.content.compactMap { part -> String? in
                    if case .text(let text) = part { return text }
                    return nil
                }
            }
            .joined(separator: " ")
    }

    /// Flatten an event to the payload worth logging, so a returned content delta shows
    /// up verbatim in the log.
    private static func render(_ event: ModelEvent) -> String {
        switch event {
        case .contentDelta(let delta): "delta " + delta
        case .reasoningDelta(let delta): "reasoning " + delta
        case .toolCall(let call): "toolCall " + call.name
        case .usage(let usage): "usage in=\(usage.inputTokens) out=\(usage.outputTokens)"
        case .webSearchCall(let call): "webSearch " + call.query
        case .webSearchResult(let result): "webSearchResult " + result.searchID
        case .citation(let citation): "citation " + citation.url
        case .completed(let reason): "completed " + reason.rawValue
        }
    }
}

/// A caller-authored retry policy: which errors are worth retrying, and the delay before
/// each successive attempt. There is deliberately no default; retrying is a decision the
/// caller makes, so the policy is always supplied.
public struct RetryPolicy: Sendable {
    public let delays: [Duration]
    public let isRetryable: @Sendable (KBLLMError) -> Bool

    public init(
        delays: [Duration],
        isRetryable: @escaping @Sendable (KBLLMError) -> Bool
    ) {
        self.delays = delays
        self.isRetryable = isRetryable
    }
}

/// Middleware that retries a failed model call per a caller-supplied ``RetryPolicy``,
/// sleeping between attempts through the injected `ClockSource` so a test drives the delay
/// with a fake clock and no real time passes. A non-retryable error is rethrown at once,
/// with no sleep, so the policy fully decides whether time is spent.
public struct RetryMiddleware: LanguageModelMiddleware {
    private let policy: RetryPolicy
    private let clock: any ClockSource

    public init(policy: RetryPolicy, clock: any ClockSource) {
        self.policy = policy
        self.clock = clock
    }

    public func intercept(
        _ request: ModelRequest,
        next: any LanguageModel
    ) -> AsyncThrowingStream<ModelEvent, any Error> {
        let policy = self.policy
        let clock = self.clock
        return AsyncThrowingStream { continuation in
            let task = Task {
                var attempt = 0
                while true {
                    // Only a clean run may retry: if events already reached the caller on
                    // this attempt, re-issuing the request would double them, so a
                    // mid-stream failure is rethrown rather than retried.
                    var yielded = false
                    do {
                        for try await event in next.stream(request) {
                            yielded = true
                            continuation.yield(event)
                        }
                        continuation.finish()
                        return
                    } catch {
                        let typed = KBLLMError.from(error)
                        guard !yielded, attempt < policy.delays.count, policy.isRetryable(typed) else {
                            continuation.finish(throwing: typed)
                            return
                        }
                        let delay = policy.delays[attempt]
                        attempt += 1
                        do {
                            try await clock.sleep(for: delay)
                        } catch {
                            continuation.finish(throwing: KBLLMError.from(error))
                            return
                        }
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
