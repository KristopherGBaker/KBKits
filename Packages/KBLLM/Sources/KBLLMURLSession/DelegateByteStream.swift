import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import KBLLM

// The streaming path for platforms without `URLSession.AsyncBytes`, which is Darwin-only:
// swift-corelibs (Linux, Android) ships `URLSession` but not that sequence, so the bytes
// are driven by the delegate API instead. See docs/ANDROID.md.
//
// This file is compiled on EVERY platform, not just the ones that need it. That is
// deliberate: it is the only way the path gets tested, because the suites run on macOS,
// where it is not the default. Code that only compiles where no test ever runs is code
// nobody has run.

extension KBLLMURLSession {
    /// Open a byte stream using `URLSessionDataDelegate` callbacks.
    ///
    /// Honors the same non-success obligation as the `AsyncBytes` path: a non-2xx status
    /// never yields its body as content, but accumulates it (bounded) as the message of a
    /// thrown `KBLLMError.httpStatus`.
    func openBytesViaDelegate(_ request: HTTPRequestSpec) -> AsyncThrowingStream<UInt8, any Error> {
        let configuration = self.configuration
        let reportsRetryAfter = self.reportsRetryAfter
        return AsyncThrowingStream { continuation in
            let urlRequest: URLRequest
            do {
                urlRequest = try Self.urlRequest(from: request)
            } catch {
                continuation.finish(throwing: error)
                return
            }
            let delegate = ByteStreamDelegate(
                continuation: continuation, url: request.url, reportsRetryAfter: reportsRetryAfter
            )
            // A delegate session retains its delegate until the task completes, so the
            // delegate is not captured here; `finishTasksAndInvalidate` releases it.
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            let task = session.dataTask(with: urlRequest)
            continuation.onTermination = { _ in
                task.cancel()
                session.finishTasksAndInvalidate()
            }
            task.resume()
        }
    }
}

/// Bridges `URLSessionDataDelegate` callbacks into an `AsyncThrowingStream`.
///
/// `@unchecked Sendable` with an explicit lock rather than relying on the delegate queue:
/// the callbacks are serialized among themselves, but `onTermination` can fire from any
/// task at any moment, so the status and the buffered error body are guarded.
final class ByteStreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let continuation: AsyncThrowingStream<UInt8, any Error>.Continuation
    private let url: String
    private let lock = NSLock()
    private let reportsRetryAfter: Bool
    private var status: Int?
    private var retryAfterHeader: String?
    private var errorBody: [UInt8] = []

    /// Matches the `AsyncBytes` path's bound, so a pathological error body cannot buffer
    /// without limit on either platform.
    private static let errorBodyLimit = 4096

    init(continuation: AsyncThrowingStream<UInt8, any Error>.Continuation, url: String, reportsRetryAfter: Bool = false) {
        self.continuation = continuation
        self.url = url
        self.reportsRetryAfter = reportsRetryAfter
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            continuation.finish(throwing: KBLLMError.transport(
                url: url, underlying: "response was not an HTTP response"))
            completionHandler(.cancel)
            return
        }
        lock.lock()
        status = http.statusCode
        retryAfterHeader = http.value(forHTTPHeaderField: "Retry-After")
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let code = status
        lock.unlock()

        guard let code, (200...299).contains(code) else {
            // Non-success: hold the body back as the eventual thrown message. Yielding it
            // would let an adapter mistake a provider's error payload for a model frame.
            lock.lock()
            let remaining = Self.errorBodyLimit - errorBody.count
            if remaining > 0 { errorBody.append(contentsOf: data.prefix(remaining)) }
            lock.unlock()
            return
        }
        for byte in data { continuation.yield(byte) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        defer { session.finishTasksAndInvalidate() }

        if let error {
            // A cancelled task is the consumer letting go, not a transport failure; the
            // stream is already terminating, and finishing again is a no-op.
            let code = (error as NSError).code
            if code == NSURLErrorCancelled {
                continuation.finish()
            } else {
                continuation.finish(throwing: KBLLMError.transport(
                    url: url, underlying: String(describing: error)))
            }
            return
        }

        lock.lock()
        let code = status
        let body = errorBody
        let retryAfter = retryAfterHeader
        lock.unlock()

        guard let code else {
            continuation.finish(throwing: KBLLMError.transport(
                url: url, underlying: "response carried no HTTP status"))
            return
        }
        if (200...299).contains(code) {
            continuation.finish()
        } else {
            continuation.finish(throwing: KBLLMURLSession.statusError(
                code: code, message: String(bytes: body, encoding: .utf8) ?? "",
                retryAfterHeader: retryAfter, reportsRetryAfter: reportsRetryAfter))
        }
    }
}
