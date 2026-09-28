import Foundation

/// One sense (meaning group) of a JMdict entry: a list of parts of speech and English glosses.
public struct JMDictSense: Codable, Sendable, Hashable {
    public let pos: [String]
    public let glosses: [String]

    public init(pos: [String], glosses: [String]) {
        self.pos = pos
        self.glosses = glosses
    }
}

/// A JMdict entry as the reader uses it: identifier, any kanji forms, any kana readings,
/// and one or more senses with English meanings.
public struct JMDictEntry: Codable, Sendable, Hashable, Identifiable {
    public let id: Int
    public let kanjiForms: [String]
    public let kanaForms: [String]
    public let senses: [JMDictSense]

    public init(id: Int, kanjiForms: [String], kanaForms: [String], senses: [JMDictSense]) {
        self.id = id
        self.kanjiForms = kanjiForms
        self.kanaForms = kanaForms
        self.senses = senses
    }

    /// The headword to display: the first kanji form when present, else the first reading.
    public var headword: String { kanjiForms.first ?? kanaForms.first ?? "" }

    /// The reading to show under/next to the headword (a kana form). `nil` for kana-only
    /// entries, where the reading would just duplicate the headword.
    public var primaryReading: String? {
        guard !kanjiForms.isEmpty, let kana = kanaForms.first else { return nil }
        return kana
    }
}
