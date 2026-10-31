import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import KBLLM

// A host `CredentialStore` that reads secrets from the process environment. It lives in the
// networking leaf beside `KBLLMURLSession` because both are host-supplied concretions of a
// core seam; where a secret lives is the host's business, and an environment variable is the
// portable default (a 12-factor deployment, a local `.env`, a CI secret).

/// A `CredentialStore` that resolves a key to an environment variable of the same name. It
/// reads the environment at lookup time (not at init) so a value exported after the store is
/// constructed is still seen. An absent or empty variable throws `KBLLMError.missingCredential`
/// naming the key, so a misconfigured deployment fails with the exact variable to set.
public struct EnvironmentCredentialStore: CredentialStore {
    /// The environment lookup. Injectable so a test can supply a deterministic map instead of
    /// the live process environment; the default reads `ProcessInfo` at each call.
    private let lookup: @Sendable (String) -> String?

    /// Read secrets from the live process environment, resolved fresh on every lookup via
    /// `getenv` so a variable exported after this store is built is still seen (unlike a
    /// cached `ProcessInfo.environment` snapshot).
    public init() {
        self.lookup = { key in
            guard let raw = getenv(key) else { return nil }
            return String(cString: raw)
        }
    }

    /// - Parameter environment: a fixed environment map, for deterministic tests.
    public init(environment: [String: String]) {
        self.lookup = { environment[$0] }
    }

    public func secret(forKey key: String) async throws -> String {
        guard let value = lookup(key), !value.isEmpty else {
            throw KBLLMError.missingCredential(key: key)
        }
        return value
    }
}
