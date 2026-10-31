import Foundation

// Every platform capability the client needs is a protocol HERE and an implementation
// in a leaf target. These are the HOST-CONSUMED seams: the things the core CONSUMES
// from its host, a separate category from the adapter-facing surface in
// `LanguageModel.swift`. Someone porting to Android reimplements exactly this file.
// The core ships NO concrete network, keychain, or wall-clock implementation.

/// An HTTP verb. Kept as a closed enum so a request can only name a method the
/// transport understands.
public enum HTTPMethod: String, Sendable, Equatable {
    case get
    case post
    case put
    case delete
    case patch
}

/// A provider-neutral HTTP request. The core builds these; a host `HTTPTransport`
/// turns them into whatever its platform's client wants. Deliberately free of any
/// concrete networking type so the core has no networking dependency.
public struct HTTPRequestSpec: Sendable, Equatable {
    public var method: HTTPMethod
    public var url: String
    public var headers: [String: String]
    public var body: Data?

    public init(
        method: HTTPMethod,
        url: String,
        headers: [String: String] = [:],
        body: Data? = nil
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

/// A provider-neutral HTTP response handed back by a host transport.
public struct HTTPResponseSpec: Sendable, Equatable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

/// The network seam. A host supplies one whole and streaming send; the core owns no
/// HTTP client and makes no requests itself.
///
/// Non-success obligation: because `openBytes` returns only bytes, a streaming call has
/// nowhere else to report a rejected status. A host transport MUST therefore surface a
/// non-success HTTP status by throwing `KBLLMError.httpStatus(code:message:)` into the
/// byte stream, rather than yielding the provider's error body as if it were content. An
/// adapter passes such a thrown status through unchanged and never parses an error body
/// into a normal event; this is the contract every future transport implementor honors.
public protocol HTTPTransport: Sendable {
    /// Send a request and await the whole response.
    func send(_ request: HTTPRequestSpec) async throws -> HTTPResponseSpec

    /// Open a byte stream for a request, for feeding the SSE parser. See the type's
    /// non-success obligation: a rejected status arrives here as a thrown
    /// `KBLLMError.httpStatus`, never as bytes.
    func openBytes(_ request: HTTPRequestSpec) -> AsyncThrowingStream<UInt8, any Error>
}

/// The credential seam. Where a secret lives (a platform vault, an environment, a
/// file) is the host's business; the core only asks for one by key.
public protocol CredentialStore: Sendable {
    /// The secret for a key, or a throw if it is absent or unreadable.
    func secret(forKey key: String) async throws -> String
}

/// The severity of a log record.
public enum LogLevel: String, Sendable, Codable, CaseIterable {
    case debug
    case info
    case warning
    case error
}

/// The logging seam. The core never reaches for a platform logger or print; it hands
/// records to a host sink so logging is portable and testable.
public protocol LogSink: Sendable {
    func log(_ level: LogLevel, _ message: String)
}

/// The clock seam. Time is injected so tests are deterministic and offline; the core
/// never reads the wall clock directly.
public protocol ClockSource: Sendable {
    /// The current instant, according to whoever supplied the clock.
    var now: Date { get }

    /// Suspend for a duration, so retry/backoff logic can be driven by a fake clock.
    func sleep(for duration: Duration) async throws
}

/// The randomness seam. Randomness is injected (idempotency keys, jitter) so a seeded
/// generator makes a run reproducible. Refines the standard generator so it drops into
/// `Int.random(in:using:)` and friends.
public protocol RandomSource: RandomNumberGenerator, Sendable {}
