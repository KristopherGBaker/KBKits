import Foundation
// Anki's note checksum and guid are both SHA-1. CryptoKit does not exist off Apple
// platforms, so swift-crypto supplies the same `Insecure.SHA1` API there. The dependency
// is declared for non-Apple platforms alone (see Package.swift), matching KBCore.
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// The small format details a collection's `notes` table depends on: how fields are
/// packed into one column, and the two derived values Anki stores beside them.
enum AnkiFields {
    /// Anki packs a note's fields into a single column separated by US (U+001F).
    /// A field may contain newlines and HTML, so no printable character would do.
    static let separator = "\u{1f}"

    /// Pack fields for storage, removing any separator a value already contains.
    ///
    /// A field holding US would split into two on the way back out, silently shifting
    /// every field after it by one. The character has no business in note text, so it
    /// is dropped rather than escaped: there is nothing to round-trip.
    static func join(_ fields: [String]) -> String {
        fields.map { $0.replacingOccurrences(of: separator, with: "") }
            .joined(separator: separator)
    }

    static func split(_ packed: String) -> [String] {
        packed.components(separatedBy: separator)
    }

    /// The `csum` column: the first 8 hex digits of the SHA-1 of the first field,
    /// as an integer. Anki uses it to find duplicates, so it must be computed the
    /// same way or an imported note will not match one already in a collection.
    static func checksum(ofFirstField field: String) -> Int64 {
        let stripped = strippingHTML(field)
        let digest = Insecure.SHA1.hash(data: Data(stripped.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return Int64(hex.prefix(8), radix: 16) ?? 0
    }

    /// Anki strips HTML before hashing, so plain text and the same text wrapped in
    /// markup are one note for duplicate purposes. This handles the tag stripping
    /// that matters for text notes; it is not a general HTML parser.
    static func strippingHTML(_ text: String) -> String {
        var output = ""
        var insideTag = false
        for character in text {
            switch character {
            case "<": insideTag = true
            case ">": insideTag = false
            default: if !insideTag { output.append(character) }
            }
        }
        return decodingEntities(output)
    }

    /// Anki decodes HTML entities before hashing, so `&amp;` and `&` are one note for
    /// duplicate purposes. Without this a field written by Anki and the same text
    /// typed here produce different checksums and fail to match.
    ///
    /// The five XML entities plus the non-breaking space, which is what note text
    /// carries in practice. `&amp;` is decoded LAST so `&amp;lt;` yields `&lt;`
    /// rather than being decoded twice into `<`.
    private static func decodingEntities(_ text: String) -> String {
        var output = text
        for (entity, replacement) in [
            ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
            ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", "\u{a0}"), ("&amp;", "&")
        ] {
            output = output.replacingOccurrences(of: entity, with: replacement)
        }
        return output
    }

    /// Anki's guid alphabet: every printable ASCII character except the quotes,
    /// backslash and space that would need escaping in the formats it travels in.
    private static let base91 = Array(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        + "!#$%&()*+,-./:;<=>?@[]^_`{|}~"
    )

    /// A guid derived from the note's own content.
    ///
    /// Deriving it from the export clock and the row position instead, as this once
    /// did, is wrong twice over: two different decks exported in the same millisecond
    /// mint the SAME guid, so Anki merges unrelated notes; and re-exporting one card
    /// later mints a DIFFERENT guid, so the receiving collection duplicates a note it
    /// already has. Hashing the fields fixes both, and keeps exports reproducible.
    ///
    /// `salt` disambiguates two notes whose fields are byte-identical, which is the
    /// only case where content alone cannot tell them apart.
    static func contentGUID(fields: [String], salt: Int) -> String {
        var seed = join(fields)
        if salt > 0 { seed += "\u{0}\(salt)" }
        let digest = Insecure.SHA1.hash(data: Data(seed.utf8))
        let number = digest.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return makeGUID(number)
    }

    /// A note guid in Anki's own shape, so an exported deck looks native and a
    /// re-import can match on it.
    static func makeGUID(_ number: UInt64) -> String {
        var value = number
        var characters: [Character] = []
        let radix = UInt64(base91.count)
        repeat {
            characters.append(base91[Int(value % radix)])
            value /= radix
        } while value > 0
        return String(characters.reversed())
    }
}
