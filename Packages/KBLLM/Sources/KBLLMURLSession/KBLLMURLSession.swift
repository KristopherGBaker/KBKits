import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import KBLLM

// The ONE target in the package that imports a networking framework. Everything else
// speaks only to the `HTTPTransport`/`CredentialStore` seams in the core, so porting the
// client to a platform without URLSession means reimplementing exactly this file and
// nothing else. The URLSession code path is exercised offline in tests by injecting a
// `URLSessionConfiguration` whose `protocolClasses` register a stub `URLProtocol`; the
// injectable configuration is the whole reason the incremental-delivery test is possible.

/// A `URLSession`-backed `HTTPTransport`. It honors the seam's non-success obligation: a
/// non-2xx status becomes a thrown `KBLLMError.httpStatus` carrying the server body's
/// message, never the error body yielded as if it were content. A `final class` marked
/// `@unchecked Sendable` because its only stored state is an immutable configuration; the
/// class never mutates it, and `URLSession` is created per call.
public final class KBLLMURLSession: HTTPTransport, @unchecked Sendable {
    /// The configuration every `URLSession` is built from. Injectable so a test can register
    /// a stub `URLProtocol` through `protocolClasses`; defaults to `.default` for production.
    /// Internal rather than private so the delegate-driven streaming path, which lives in
    /// its own file, can build a session from the same configuration.
    let configuration: URLSessionConfiguration

    /// - Parameter configuration: the session configuration. The default is `.default`; a
    ///   test passes one whose `protocolClasses` intercept every request so no socket opens.
    public init(configuration: URLSessionConfiguration = .default) {
        self.configuration = configuration
    }

    public func send(_ request: HTTPRequestSpec) async throws -> HTTPResponseSpec {
        let urlRequest = try Self.urlRequest(from: request)
        let session = URLSession(configuration: configuration)
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw KBLLMError.transport(url: request.url, underlying: "response was not an HTTP response")
        }
        return HTTPResponseSpec(status: http.statusCode, headers: Self.headers(http), body: data)
    }

    public func openBytes(_ request: HTTPRequestSpec) -> AsyncThrowingStream<UInt8, any Error> {
        #if canImport(Darwin)
        return openBytesViaAsyncBytes(request)
        #else
        // swift-corelibs has no `URLSession.AsyncBytes`, so the delegate API drives the
        // stream instead. See `DelegateByteStream.swift`.
        return openBytesViaDelegate(request)
        #endif
    }

    #if canImport(Darwin)
    private func openBytesViaAsyncBytes(_ request: HTTPRequestSpec) -> AsyncThrowingStream<UInt8, any Error> {
        let configuration = self.configuration
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlRequest = try Self.urlRequest(from: request)
                    let session = URLSession(configuration: configuration)
                    let (bytes, response) = try await session.bytes(for: urlRequest)
                    guard let http = response as? HTTPURLResponse else {
                        throw KBLLMError.transport(url: request.url, underlying: "response was not an HTTP response")
                    }
                    guard (200...299).contains(http.statusCode) else {
                        // Non-success obligation: drain the error body for its message and
                        // throw `.httpStatus` into the stream. The body is NEVER yielded as
                        // content, so an adapter can never mistake it for a model frame.
                        throw KBLLMError.httpStatus(
                            code: http.statusCode,
                            message: try await Self.drainMessage(bytes)
                        )
                    }
                    // Incremental by construction: each byte is yielded as `URLSession`
                    // delivers it, so a consumer sees an early chunk before a later one is
                    // ever sent rather than waiting for the whole body.
                    for try await byte in bytes {
                        continuation.yield(byte)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // Cancelling the consumer cancels this task, which cancels the underlying
            // `URLSession` task (its `URLProtocol.stopLoading` fires), so nothing leaks.
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Read a non-success response body into a message string, bounded so a pathological
    /// error body cannot buffer without limit. The body is only ever used as the thrown
    /// status's message, never surfaced as stream content.
    private static func drainMessage(_ bytes: URLSession.AsyncBytes) async throws -> String {
        var collected: [UInt8] = []
        let limit = 4096
        for try await byte in bytes {
            if collected.count >= limit { break }
            collected.append(byte)
        }
        return String(bytes: collected, encoding: .utf8) ?? ""
    }
    #endif

    /// Internal so the delegate-driven path in `DelegateByteStream.swift` builds requests
    /// exactly the same way rather than growing a second, drifting copy.
    static func urlRequest(from spec: HTTPRequestSpec) throws -> URLRequest {
        guard let url = URL(string: spec.url) else {
            throw KBLLMError.invalidRequest(field: "url", reason: "request URL is not a valid URL: \(spec.url)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = spec.method.rawValue.uppercased()
        request.httpBody = spec.body
        for (name, value) in spec.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    private static func headers(_ response: HTTPURLResponse) -> [String: String] {
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let name = key as? String, let text = value as? String {
                headers[name] = text
            }
        }
        return headers
    }
}
