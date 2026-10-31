import Foundation
import KBLLM
#if canImport(Security)
import Security
#endif

/// A `CredentialStore` backed by the platform's secret vault, for a key the user typed and the
/// app has to keep. It sits beside `EnvironmentCredentialStore` because those are the two real
/// cases: a key in the environment for a tool run from a shell, and a key in a vault for a
/// shipped app.
///
/// Shaped the way `AppleModel` is shaped, and for the same reason: the SURFACE names no
/// Apple-only type, so the module vends it everywhere `KBLLM` builds, and only the
/// Keychain-backed implementation sits behind `canImport(Security)`. KBLLM is on the Android
/// list, so a file that imported Security unguarded would fail `make check-portability`.
///
/// Where there is no vault, this store does not pretend to be one. `isAvailable` is false,
/// `store` returns false, and `secret(forKey:)` throws `.missingCredential`. A host on such a
/// platform supplies its own `CredentialStore`; silently accepting a secret it cannot keep is
/// the one behaviour ruled out, because the caller would believe the key was saved.
public struct KeychainCredentialStore: CredentialStore {
    private let service: String

    /// - Parameter service: the vault service the items live under. Injected rather than fixed,
    ///   so two apps in one account do not share a slot and a test can use a name it may delete.
    public init(service: String) {
        self.service = service
    }

    /// Whether this platform has a vault behind the store at all.
    public var isAvailable: Bool {
        #if canImport(Security)
        true
        #else
        false
        #endif
    }

    public func secret(forKey key: String) async throws -> String {
        guard let value = read(key), !value.isEmpty else {
            throw KBLLMError.missingCredential(key: key)
        }
        return value
    }

    /// Whether a secret is present, WITHOUT returning it.
    ///
    /// A settings screen needs to show "a key is set" and must not hold the key to do it, which
    /// is how a secret ends up in a view's state and then in a crash log.
    public func hasSecret(forKey key: String) -> Bool {
        read(key)?.isEmpty == false
    }

    /// Stores a secret, or removes it when handed nil or blank.
    /// - Returns: whether the vault took it. False only where there is no vault.
    @discardableResult
    public func store(_ value: String?, forKey key: String) -> Bool {
        #if canImport(Security)
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else {
            SecItemDelete(query(key) as CFDictionary)
            return true
        }
        let data = Data(trimmed.utf8)
        let status = SecItemUpdate(query(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query(key)
            insert[kSecValueData as String] = data
            return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
        #else
        return false
        #endif
    }

    private func read(_ key: String) -> String? {
        #if canImport(Security)
        var lookup = query(key)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
        #else
        return nil
        #endif
    }

    #if canImport(Security)
    private func query(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
    }
    #endif
}
