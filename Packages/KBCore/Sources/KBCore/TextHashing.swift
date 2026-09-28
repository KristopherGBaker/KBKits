import Foundation
// swift-crypto is API-identical to CryptoKit and produces the same digests, so this
// fork changes nothing about the hash; it exists only because CryptoKit is Apple-only.
// The dependency is declared for non-Apple platforms alone (see Package.swift), so an
// Apple build still links nothing beyond the SDK.
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Stable content hashing for text. Used to derive `DocumentID`, to validate
/// persisted `ReadingPosition`s against the live document, and as
/// `TimingProvenance.textHash` so cached timing invalidates when the exact
/// normalized text changes (§3.2).
public enum TextHashing {
    /// Lowercase-hex SHA-256 of the UTF-8 bytes of `text`.
    public static func sha256Hex(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
