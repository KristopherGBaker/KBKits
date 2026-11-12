import Foundation

// The provider-neutral plumbing every HTTP adapter needs: the bounded raw-body tap, the
// secret's redaction, the endpoint join, the credential fetch and the body serializer. An
// adapter module never imports another, so the core is the one place they can be shared
// rather than copied. `package` access: the adapter targets of this package reach them and
// the public surface does not grow.

/// Retains a bounded prefix of a byte stream so the adapter can name a fragment of the raw
/// body when a 2xx drain yields zero usable events (the observed unknown-path case: a 200
/// whose body is an error object, not an event stream). Reference-typed and lock-guarded so
/// the tapping task and the draining task share one buffer safely.
package final class BodyPrefix: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []
    private let limit = 512

    package init() {}

    package func append(_ byte: UInt8) {
        lock.lock()
        defer { lock.unlock() }
        if bytes.count < limit { bytes.append(byte) }
    }

    package var fragment: String {
        lock.lock()
        defer { lock.unlock() }
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }
}

/// Forward a byte stream unchanged while retaining a bounded prefix in `prefix`, so the SSE
/// parser sees an ordinary byte sequence and the adapter can still describe the raw body if
/// the drain produced nothing usable. A free function so the drain loop reads as one line.
package func tapping(
    _ upstream: AsyncThrowingStream<UInt8, any Error>,
    into prefix: BodyPrefix
) -> AsyncThrowingStream<UInt8, any Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            do {
                for try await byte in upstream {
                    prefix.append(byte)
                    continuation.yield(byte)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

/// The request-side helpers the adapters share.
package enum AdapterPlumbing {
    /// Compose the endpoint from the base URL and the adapter's fixed path, joined as written
    /// (a trailing slash on the base is the caller's to remove), and validate it. A base that
    /// cannot form a valid URL is rejected as `.invalidRequest` naming the base, rather than
    /// concatenated into a broken request the transport would fail on opaquely.
    package static func composeEndpoint(base: String, suffix: String) throws -> String {
        let endpoint = base + suffix
        guard URL(string: endpoint) != nil else {
            throw KBLLMError.invalidRequest(field: "baseURL", reason: "malformed base URL: \(base)")
        }
        return endpoint
    }

    /// Replace any occurrence of the secret with a fixed marker so a host-supplied error
    /// message can never smuggle the key into a `.transport` value.
    package static func redact(_ text: String, secret: String?) -> String {
        guard let secret, !secret.isEmpty else { return text }
        return text.replacingOccurrences(of: secret, with: "[redacted]")
    }

    /// A request body as JSON, keys always sorted: a Swift dictionary's order follows a hash
    /// seed that changes with every process, so unsorted, the same request would be different
    /// bytes after a relaunch, and a provider caching prompt prefixes (a byte-prefix match) or a
    /// test comparing two requests would never see one stable body. `options` adds the
    /// caller's own (an adapter's slash policy). A body JSON cannot carry fails as
    /// `.invalidRequest` naming the body; it is checked before writing because Foundation
    /// documents that writing such an object (a NaN or infinite number, a non-JSON value)
    /// raises rather than throws, which no Swift caller could catch.
    package static func serialize(
        _ object: [String: Any],
        options: JSONSerialization.WritingOptions = []
    ) throws -> Data {
        let unserializable = KBLLMError.invalidRequest(field: "body", reason: "request body could not be serialized")
        guard JSONSerialization.isValidJSONObject(object) else { throw unserializable }
        do {
            return try JSONSerialization.data(withJSONObject: object, options: options.union(.sortedKeys))
        } catch {
            throw unserializable
        }
    }
}

extension CredentialStore {
    /// The secret for `credentialKey`, or `.missingCredential` naming that key when the store
    /// cannot supply it. The caller's key names what to configure; the store's raw error never
    /// escapes. An empty secret is returned as is: what it means is the adapter's call (the
    /// OpenAI adapters send no Authorization header for one).
    package func resolvedSecret(forKey credentialKey: String) async throws -> String {
        do {
            return try await secret(forKey: credentialKey)
        } catch {
            throw KBLLMError.missingCredential(key: credentialKey)
        }
    }
}
