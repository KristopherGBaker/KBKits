import Foundation

/// Splits a sentence into maximal **Japanese** vs **English** runs so a mixed
/// JA/EN segment can be code-switched at synthesis time: each run is phonemized by
/// (and optionally voiced by) the engine for its own script instead of forcing the
/// whole string through one G2P. Without this, a Japanese Kokoro voice sends
/// embedded English to OpenJTalk, which reads unknown Latin words **letter by
/// letter** (Speechify → エス・ピー・…); the pure-Apple fallback drops them silently.
/// Both are wrong — this is the split that lets English be pronounced as English.
///
/// The split is purely script-based (no dictionary), so it's deterministic and
/// cheap. Neutral characters (spaces, shared punctuation) and digits carry no
/// script of their own and attach to a neighbouring run. **Short all-uppercase
/// initialisms** (API, NASA, JR) are treated as Japanese content when they sit
/// among Japanese, so OpenJTalk spells them as letter-name katakana (エーピーアイ) —
/// how they're read aloud in Japanese — rather than as English words.
public enum MixedScriptSegmenter {

    /// Which engine/G2P a run should be synthesized with.
    public enum Script: Sendable, Equatable { case japanese, english }

    /// One contiguous same-script run within the source text.
    public struct Run: Sendable, Equatable {
        /// The run's substring (covers its share of neutral/space characters).
        public let text: String
        /// Which script/G2P to synthesize it with.
        public let script: Script
        /// UTF-16 offset of the run's first character within the source string, so
        /// callers can map per-run results back onto the full segment.
        public let utf16Start: Int

        public init(text: String, script: Script, utf16Start: Int) {
            self.text = text
            self.script = script
            self.utf16Start = utf16Start
        }
    }

    /// All-uppercase ASCII tokens up to this length read as letter-name katakana
    /// (kept on the Japanese side) instead of being pronounced as an English word.
    /// Four covers the common initialisms (API, HTML, NASA, JAXA) while leaving
    /// genuine all-caps words (rare in prose) to the English path.
    public static let acronymMaxLength = 4

    /// Whether `text` mixes Japanese and Latin-word scripts — i.e. whether
    /// code-switching has anything to do. Callers use this to keep the common
    /// single-script path on the existing fast path.
    public static func isMixed(_ text: String) -> Bool {
        let runs = runs(in: text)
        return runs.contains { $0.script == .japanese } && runs.contains { $0.script == .english }
    }

    /// Segment `text` into ordered Japanese/English runs whose concatenation is
    /// exactly `text` (no characters dropped). A single-script string returns one
    /// run; an empty string returns none.
    public static func runs(in text: String) -> [Run] {
        let atoms = atomize(text)
        guard !atoms.isEmpty else { return [] }
        let scripts = resolveScripts(atoms)

        var runs: [Run] = []
        var current = ""
        var currentScript: Script?
        var currentStart = 0
        for (atom, script) in zip(atoms, scripts) {
            if script == currentScript {
                current += atom.text
            } else {
                if let currentScript, !current.isEmpty {
                    runs.append(Run(text: current, script: currentScript, utf16Start: currentStart))
                }
                current = atom.text
                currentScript = script
                currentStart = atom.utf16Start
            }
        }
        if let currentScript, !current.isEmpty {
            runs.append(Run(text: current, script: currentScript, utf16Start: currentStart))
        }
        return runs
    }

    // MARK: - Atoms

    /// A maximal same-category chunk of the source, with its UTF-16 start.
    private struct Atom {
        let text: String
        let category: Category
        let utf16Start: Int
    }

    /// Character categories before script resolution. `cjk`/`latinWord` carry a
    /// definite script; the rest defer to a neighbour.
    private enum Category {
        case cjk          // Japanese/CJK script → always Japanese
        case latinWord    // a run of Latin letters → English (unless an acronym)
        case acronym      // short ALL-CAPS Latin token → Japanese among Japanese
        case other        // digits, spaces, punctuation → follow a neighbour
    }

    /// Break the string into maximal same-category atoms. Latin-letter runs become
    /// `.acronym` when short + all-uppercase, else `.latinWord`; CJK scalars group
    /// as `.cjk`; everything else groups as `.other`.
    private static func atomize(_ text: String) -> [Atom] {
        var atoms: [Atom] = []
        var buffer = ""
        var bufferCategory: Category?
        var bufferStart = 0
        var offset = 0

        func flush() {
            if let bufferCategory, !buffer.isEmpty {
                let category = bufferCategory == .latinWord && isAcronym(buffer) ? .acronym : bufferCategory
                atoms.append(Atom(text: buffer, category: category, utf16Start: bufferStart))
            }
            buffer = ""
            bufferCategory = nil
        }

        for scalar in text.unicodeScalars {
            let category = baseCategory(scalar)
            if category != bufferCategory {
                flush()
                bufferCategory = category
                bufferStart = offset
            }
            buffer.unicodeScalars.append(scalar)
            offset += scalar.utf16Width
        }
        flush()
        return atoms
    }

    /// The pre-resolution category of a single scalar. Latin letters are `.latinWord`
    /// (acronym promotion happens per-atom); CJK is `.cjk`; all else `.other`.
    private static func baseCategory(_ scalar: Unicode.Scalar) -> Category {
        if isCJKScalar(scalar) { return .cjk }
        if isLatinLetter(scalar) { return .latinWord }
        return .other
    }

    /// True for a short token that's entirely ASCII uppercase letters — an
    /// initialism kept on the Japanese side (spelled as letter-name katakana).
    private static func isAcronym(_ token: String) -> Bool {
        let scalars = token.unicodeScalars
        guard scalars.count <= acronymMaxLength, !scalars.isEmpty else { return false }
        return scalars.allSatisfy { (0x41...0x5A).contains($0.value) }
    }

    // MARK: - Script resolution

    /// Assign every atom a final `Script`. Definite atoms (`cjk`→JA, `latinWord`→EN)
    /// resolve directly; deferred atoms (`acronym`, `other`) take the script of the
    /// nearest definite atom — preferring Japanese on ties / when isolated, so a lone
    /// "API" or an all-symbol string reads on the (default Japanese) base voice.
    private static func resolveScripts(_ atoms: [Atom]) -> [Script] {
        // Definite script per atom, or nil for deferred atoms.
        let definite: [Script?] = atoms.map { atom in
            switch atom.category {
            case .cjk: return .japanese
            case .latinWord: return .english
            case .acronym, .other: return nil
            }
        }

        // Nearest definite script to the left / right of each index (distance-tagged).
        var leftScript = [Script?](repeating: nil, count: atoms.count)
        var leftDistance = [Int](repeating: .max, count: atoms.count)
        var lastScript: Script?
        var lastIndex = -1
        for index in atoms.indices {
            if let script = definite[index] { lastScript = script; lastIndex = index }
            leftScript[index] = lastScript
            leftDistance[index] = lastScript == nil ? .max : index - lastIndex
        }
        var rightScript = [Script?](repeating: nil, count: atoms.count)
        var rightDistance = [Int](repeating: .max, count: atoms.count)
        lastScript = nil
        lastIndex = atoms.count
        for index in atoms.indices.reversed() {
            if let script = definite[index] { lastScript = script; lastIndex = index }
            rightScript[index] = lastScript
            rightDistance[index] = lastScript == nil ? .max : lastIndex - index
        }

        return atoms.indices.map { index in
            if let script = definite[index] { return script }
            // Deferred: take the closer definite neighbour; tie or none → Japanese.
            let left = leftDistance[index], right = rightDistance[index]
            if left == .max && right == .max { return .japanese }
            if right < left { return rightScript[index] ?? .japanese }
            // left <= right → prefer the left (and Japanese on a tie via ?? default).
            return leftScript[index] ?? rightScript[index] ?? .japanese
        }
    }

    // MARK: - Scalar classification

    /// True for a Latin-script letter (ASCII or extended Latin) — the characters that
    /// make up an English word. CJK is excluded by `atomize` ordering (CJK checked
    /// first), so this is purely the Latin alphabet test.
    private static func isLatinLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x41...0x5A, 0x61...0x7A,   // ASCII A–Z a–z
             0xC0...0x24F:               // Latin-1 Supplement + Latin Extended-A/B
            return scalar.properties.isAlphabetic
        default:
            return false
        }
    }

    /// Japanese/CJK scalar test — kana, CJK ideographs and CJK punctuation, i.e. a
    /// script written without inter-word spaces. Mirrors `WordTokenizer`'s table.
    private static func isCJKScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x303F,   // CJK symbols & punctuation
             0x3040...0x309F,   // Hiragana
             0x30A0...0x30FF,   // Katakana
             0x31F0...0x31FF,   // Katakana phonetic extensions
             0x3400...0x4DBF,   // CJK Unified Ideographs Extension A
             0x4E00...0x9FFF,   // CJK Unified Ideographs
             0xF900...0xFAFF,   // CJK Compatibility Ideographs
             0xFF65...0xFF9F,   // Halfwidth katakana
             0x20000...0x2FFFF: // CJK Unified Ideographs Extensions B–F
            return true
        default:
            return false
        }
    }
}

private extension Unicode.Scalar {
    /// UTF-16 code-unit width (1 for the BMP, 2 for astral scalars) — to track
    /// offsets that match `String.utf16` without materializing it.
    var utf16Width: Int { value > 0xFFFF ? 2 : 1 }
}
