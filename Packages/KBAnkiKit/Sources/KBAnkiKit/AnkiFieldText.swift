import Foundation

/// Turning one raw Anki field into text a card can use.
///
/// A field in a real deck is not plain text. It carries HTML, references to media
/// by filename, HTML entities, and in Japanese decks a reading written inline as
/// `漢字[かんじ]`. Every one of those has to be understood the way Anki writes it,
/// which is why this lives beside the rest of the format rather than in an app: a
/// second copy of these rules in a consumer is a copy that drifts.
///
/// It deliberately knows nothing about study cards. It reports media by NAME and
/// lets the caller decide what a reference means.
public enum AnkiFieldText {
    /// One field, taken apart.
    public struct Cleaned: Sendable, Hashable {
        /// The field with markup, media markers and entities resolved away.
        public let text: String
        /// Filenames from `[sound:NAME]` markers, in the order they appeared.
        public let audioFileNames: [String]
        /// Filenames from `<img src="NAME">` tags, in the order they appeared.
        public let imageFileNames: [String]

        public init(text: String, audioFileNames: [String] = [], imageFileNames: [String] = []) {
            self.text = text
            self.audioFileNames = audioFileNames
            self.imageFileNames = imageFileNames
        }
    }

    /// Take a raw field apart.
    ///
    /// The ORDER below is load-bearing:
    ///
    /// 1. Media markers come out FIRST. Strip the tags first and `[sound:x.mp3]`
    ///    survives as literal text in the middle of a meaning.
    /// 2. `<img>` is read before the general tag strip, for the same reason: its
    ///    filename is an attribute the strip would discard.
    /// 3. Tags become a LINE BREAK where they end a block, not nothing. Joining on
    ///    `</div>` runs two sentences into one word that no dictionary holds.
    /// 4. Entities are decoded AFTER tags are gone. Decoding first turns `&lt;b&gt;`
    ///    into a real tag that the strip then eats, silently losing content.
    /// 5. Trim last, once the steps above have created the whitespace.
    public static func cleaned(_ raw: String) -> Cleaned {
        var working = raw
        let audio = extract(&working, pattern: #"\[sound:([^\]]+)\]"#)
        let images = extract(&working, pattern: #"<img[^>]*\ssrc\s*=\s*["']([^"']+)["'][^>]*>"#)
        working = strippingTags(working)
        working = AnkiFields.strippingHTML(working)
        return Cleaned(
            text: working.trimmingCharacters(in: .whitespacesAndNewlines),
            audioFileNames: audio,
            imageFileNames: images)
    }

    /// Pull every capture of `pattern` out of `text`, removing the whole match.
    private static func extract(_ text: inout String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: range)
        var names: [String] = []
        for match in matches {
            guard match.numberOfRanges > 1, let captured = Range(match.range(at: 1), in: text)
            else { continue }
            names.append(String(text[captured]))
        }
        // Removed back to front so earlier ranges stay valid.
        for match in matches.reversed() {
            guard let whole = Range(match.range, in: text) else { continue }
            text.replaceSubrange(whole, with: " ")
        }
        return names
    }

    /// Replace block-ending tags with a newline and drop the rest, so a field built
    /// from several lines does not collapse into one run-on string.
    private static func strippingTags(_ text: String) -> String {
        let breaks = ["<br>", "<br/>", "<br />", "</div>", "</p>", "</li>"]
        var output = text
        for tag in breaks {
            output = output.replacingOccurrences(of: tag, with: "\n", options: .caseInsensitive)
        }
        return output
    }

    /// Split a field written in Anki's inline furigana convention.
    ///
    /// `先生[せんせい]` is one word plus its reading. A group attaches to the run of
    /// text before it, and Anki marks where that run starts with a SPACE, so
    /// `日本語[にほんご]を 勉強[べんきょう]します` is two groups and not one.
    ///
    /// A bracket that never closes is left alone and contributes no reading: a field
    /// that is merely odd should import as itself rather than throw away the word.
    ///
    /// - Returns: the base text with brackets removed, and the reading assembled from
    ///   the groups, or nil when the field carries none.
    public static func splittingFurigana(_ raw: String) -> (base: String, reading: String?) {
        guard raw.contains("[") else { return (raw, nil) }
        var base = ""
        var reading = ""
        var sawGroup = false
        // A group's base is the text since the last space, so the reading replaces
        // only that run rather than everything before the bracket.
        var pendingBase = ""

        var index = raw.startIndex
        while index < raw.endIndex {
            let character = raw[index]
            if character == "[" {
                guard let close = raw[index...].firstIndex(of: "]") else {
                    // Unclosed: treat the rest as ordinary text.
                    base += pendingBase + String(raw[index...])
                    reading += pendingBase + String(raw[index...])
                    return (base, sawGroup ? reading : nil)
                }
                let inner = String(raw[raw.index(after: index)..<close])
                base += pendingBase
                reading += inner
                pendingBase = ""
                sawGroup = true
                index = raw.index(after: close)
                continue
            }
            if character == " " {
                // The space marks a boundary and is not part of either output.
                base += pendingBase
                reading += pendingBase
                pendingBase = ""
                index = raw.index(after: index)
                continue
            }
            pendingBase.append(character)
            index = raw.index(after: index)
        }
        base += pendingBase
        reading += pendingBase
        return (base, sawGroup ? reading : nil)
    }
}
