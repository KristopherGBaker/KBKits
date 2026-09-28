import Foundation

/// Dictionary knowledge the `ReadingValidator` consumes — an injectable seam so the
/// policy stays pure and testable against fakes. `JMDictStore` conforms below.
public protocol ReadingDictionary: Sendable {
    /// All kana readings JMdict lists for the exact form (kanji headword or variant).
    func readings(forForm form: String) -> [String]
    /// Per-character furigana spans for the exact (form, reading) pair; empty when absent.
    func furiganaSegments(form: String, reading: String) -> [FuriganaSpan]
}

extension JMDictStore: ReadingDictionary {
    /// Every kana form of every entry listing `form` as a headword or variant — so
    /// 無暗 resolves to むやみ through the 無闇/無暗 entry's `entry_form` rows. Uses the
    /// lean single-query path (no senses decode); called per kanji token on the reader
    /// build hot path.
    public func readings(forForm form: String) -> [String] {
        kanaReadings(forForm: form)
    }
}

/// The repair payload carried by an `impossible` verdict: the dictionary reading to
/// apply, plus its segmentation only when the exact (form, reading) pair has a
/// JmdictFurigana row. 無暗 repairs to むやみ via the entry_form variant, but only the
/// sibling variant 無闇 has segmentation — it must not be borrowed, so 無暗 carries nil.
public struct ReadingRepair: Sendable, Hashable {
    public let reading: String
    public let segmentation: [FuriganaSpan]?

    public init(reading: String, segmentation: [FuriganaSpan]?) {
        self.reading = reading
        self.segmentation = segmentation
    }
}

/// The validator's classification of one OpenJTalk word reading.
public enum ReadingVerdict: Sendable, Hashable {
    /// The dictionary corroborates OpenJTalk's reading — keep it. Carries the exact
    /// (form, reading) segmentation when available, for per-kanji ruby placement only.
    case consistent(segmentation: [FuriganaSpan]?)
    /// The reading is impossible for a form the dictionary knows exactly — override
    /// with the repair (這入る, 行衛, 無暗: OpenJTalk's dictionary lacks the form).
    case impossible(repair: ReadingRepair?)
    /// The dictionary doesn't know the form — leave OpenJTalk's output untouched.
    case unknown
}

/// Validate/repair policy over OpenJTalk readings — the JMdict furigana tier's brain.
///
/// Trusts OpenJTalk whenever the dictionary corroborates its reading (`consistent`:
/// contextual choices like 行った→いった/おこなった are both correct), overrides ONLY when
/// the reading is impossible for an exactly-known form (`impossible`), and keeps hands
/// off everything else (`unknown`). A wrong override is worse than a missed fix, so
/// every ambiguity biases away from `impossible`: inflected surfaces (来た) are never
/// exact-form hits and therefore can never be overridden.
public struct ReadingValidator: Sendable {
    private let dictionary: any ReadingDictionary

    public init(dictionary: any ReadingDictionary) {
        self.dictionary = dictionary
    }

    /// Classifies one word: `surface` as it appears in the text, `baseForm` from
    /// OpenJTalk's morphology when available (行った → 行く), and OpenJTalk's reading
    /// (kana; katakana is normalized for comparison).
    public func validate(surface: String, baseForm: String?, ojtReading: String) -> ReadingVerdict {
        validate(surface: surface, ojtReading: ojtReading, baseForm: { baseForm })
    }

    /// Lazy-`baseForm` variant for the hot path: deriving the base form costs a second
    /// OpenJTalk frontend pass per token, but it's only consulted when the exact-form
    /// check misses — so callers pass a closure and step 1 short-circuits without it.
    public func validate(
        surface: String,
        ojtReading: String,
        baseForm: () -> String?
    ) -> ReadingVerdict {
        detailed(surface: surface, ojtReading: ojtReading, baseForm: baseForm).verdict
    }

    /// `validate` plus the candidate readings the dictionary lists for the exact surface.
    ///
    /// The candidates are fetched anyway on the way to the verdict (step 1 below), and were
    /// being discarded. A reader-facing affordance that offers alternative readings needs
    /// exactly that list, and re-querying for it would double the dictionary reads on the
    /// render path for information already in hand. `validate` delegates here, so no existing
    /// caller or pattern match changes.
    ///
    /// The list is EMPTY when the dictionary does not know the surface, which is also the
    /// `.unknown` case: no alternatives can be offered for a form nothing lists.
    public func detailed(
        surface: String,
        ojtReading: String,
        baseForm: () -> String?
    ) -> (verdict: ReadingVerdict, candidates: [String]) {
        guard !surface.isEmpty, !ojtReading.isEmpty else { return (.unknown, []) }
        // Kana-only tokens (する, コーヒー) read as themselves — nothing to fix, never override.
        guard surface.contains(where: Self.isKanji) else {
            return (.consistent(segmentation: nil), [])
        }
        let reading = Self.hiragana(ojtReading)

        // 1. Exact-form corroboration: the reading is one JMdict lists for the surface.
        let directReadings = dictionary.readings(forForm: surface)
        if let matched = directReadings.first(where: { Self.hiragana($0) == reading }) {
            let spans = dictionary.furiganaSegments(form: surface, reading: matched)
            return (.consistent(segmentation: spans.isEmpty ? nil : spans), directReadings)
        }

        // 2. Inflected corroboration: adjust base readings to the surface (行く+いく for
        //    行った → いった) and compare. An unsound transfer (ka-hen: 来る+くる → くた)
        //    simply fails the comparison, keeping 来た=きた out of the override path.
        var bases: [String] = []
        if let base = baseForm(), !base.isEmpty, base != surface { bases.append(base) }
        bases += Deinflector.candidates(for: surface)
        for base in bases {
            for baseReading in dictionary.readings(forForm: base)
            where Self.surfaceReading(base: base, baseReading: baseReading, surface: surface) == reading {
                return (.consistent(segmentation: nil), directReadings)
            }
        }

        // 2.5 Sandhi corroboration: the reading is one JMdict lists, with a regular
        //     alternation a NEIGHBOUR caused - rendaku/handakuon on the head (書き → がき in
        //     落書き, 分 → ぷん in 三十分) or gemination on the tail (八 → はっ in 八分).
        //     A dictionary lists citation forms, so these variants are never listed and step 3
        //     would call every one of them impossible and overwrite a CORRECT in-context
        //     reading with the citation form: 五時三十八分 rendered ごじさんじゅうはちぶ
        //     because 八[はっ] became はち and 分[ぷん] became ふん. Keeping OpenJTalk here is
        //     the policy this type already states - it has a real sandhi model and the
        //     dictionary has none, so a disagreement in exactly the position where a
        //     neighbour changes a reading is not evidence OpenJTalk is wrong.
        if let listed = Sandhi.source(of: reading, among: directReadings.map(Self.hiragana)),
           let original = directReadings.first(where: { Self.hiragana($0) == listed }) {
            let row = dictionary.furiganaSegments(form: surface, reading: original)
            let moved = row.isEmpty ? nil : Sandhi.transfer(row, from: listed, to: reading)
            return (.consistent(segmentation: moved), directReadings)
        }

        // 3. The dictionary knows the exact surface form, and the reading matches nothing
        //    it lists → impossible. Repair with the first dictionary reading, carrying
        //    segmentation only when the exact (form, reading) pair has a furigana row.
        if let repairReading = directReadings.first {
            let spans = dictionary.furiganaSegments(form: surface, reading: repairReading)
            let repair = ReadingRepair(reading: repairReading, segmentation: spans.isEmpty ? nil : spans)
            return (.impossible(repair: repair), directReadings)
        }

        // 4. No dictionary knowledge at all → hands off.
        return (.unknown, [])
    }

    /// A reading for a surface the ANALYSER could not read at all, taken from the dictionary.
    ///
    /// Distinct from `detailed`, which judges a reading that exists. Open JTalk knows nothing
    /// about a rare or old-form kanji - 啣, 縊, 瞠, 魘, 搔 - and answers with nothing (it used to
    /// answer with its pause symbol, which was worse; see `JapaneseReader.kanaOnly`). The reader
    /// then drew NO ruby over a kanji, which for a learner is the one thing furigana exists to
    /// prevent. 551 tokens across the 30-book corpus.
    ///
    /// The dictionary can read 268 of them, mostly through the INFLECTED form: the token is
    /// 啣え and JMdict knows 啣える(くわえる), so the reading transfers back to the surface by
    /// the same `surfaceReading` rule the inflected-corroboration step uses. Nothing is invented
    /// here - a form the dictionary does not know returns nil and the token stays bare.
    ///
    /// Spans ride along only for an exact (form, reading) pair, as everywhere else.
    ///
    /// The CANDIDATES come back too, and that is what makes this safe to ship. Measured over the
    /// corpus, the rescued readings match the author 67 times and differ 34 - 曝 read さらし where
    /// the author wanted さ, 咏 read えい where the author wanted よ. Both are real readings of
    /// the kanji, and this app's answer to a defensible disagreement is to OFFER the alternative
    /// rather than to decline: with candidates attached the reader taps the word and picks. A
    /// blank kanji offers nothing to correct.
    public func readingWhenUnreadable(surface: String) -> (repair: ReadingRepair, candidates: [String])? {
        guard !surface.isEmpty, surface.contains(where: Self.isKanji) else { return nil }
        let exactReadings = dictionary.readings(forForm: surface)
        if let exact = exactReadings.first {
            let spans = dictionary.furiganaSegments(form: surface, reading: exact)
            return (ReadingRepair(reading: Self.hiragana(exact),
                                  segmentation: spans.isEmpty ? nil : spans),
                    exactReadings.map(Self.hiragana))
        }
        // The token is inflected: find a base the dictionary knows and carry its reading back.
        for base in Deinflector.candidates(for: surface) + Self.stemForms(of: surface) {
            let baseReadings = dictionary.readings(forForm: base)
            let transferred = baseReadings.compactMap {
                Self.surfaceReading(base: base, baseReading: $0, surface: surface)
            }
            guard let first = transferred.first else { continue }
            return (ReadingRepair(reading: first, segmentation: nil), transferred)
        }
        return nil
    }

    /// Dictionary forms to try for a surface the dictionary does not list as it stands: 啣え ->
    /// 啣える, 縊っ -> 縊る, and the BARE kanji 啣 -> 啣える too. `Deinflector` handles the common
    /// conjugations; this covers the rest by re-attaching an ending to the kanji stem, and a
    /// wrong ending simply finds nothing.
    ///
    /// The bare case is not an edge case: the tokenizer splits 啣えた into 啣 + えた, so the
    /// surface reaching here is usually the kanji ALONE. Requiring okurigana to strip left 啣
    /// with no ruby on screen while every other rare kanji around it gained one.
    static func stemForms(of surface: String) -> [String] {
        let characters = Array(surface)
        var stemEnd = characters.count
        while stemEnd > 0, !isKanji(characters[stemEnd - 1]) { stemEnd -= 1 }
        guard stemEnd > 0 else { return [] }
        let stem = String(characters[0..<stemEnd])
        return ["る", "む", "う", "く", "ぐ", "す", "つ", "ぶ", "ぬ", "い",
                "える", "きる", "ける", "げる", "せる", "てる", "める", "れる", "ねる", "べる"]
            .map { stem + $0 }
    }

    /// Adjusts a base-form dictionary reading to an inflected surface by swapping the
    /// kana tails after the shared stem (行く+いく, surface 行った → いった). Returns nil
    /// when the transfer isn't structurally sound: no shared stem, a kanji tail (the
    /// words merely share a prefix), or a base reading that doesn't end in the base's
    /// kana tail. Ka-hen mistransfers (来る → くた for 来た) survive this check but are
    /// rejected by the caller's equality comparison — they can only fail to match.
    static func surfaceReading(base: String, baseReading: String, surface: String) -> String? {
        let baseChars = Array(base)
        let surfaceChars = Array(surface)
        var shared = 0
        while shared < baseChars.count, shared < surfaceChars.count, baseChars[shared] == surfaceChars[shared] {
            shared += 1
        }
        guard shared > 0 else { return nil }
        let baseTail = String(baseChars[shared...])
        let surfaceTail = String(surfaceChars[shared...])
        guard !baseTail.contains(where: isKanji), !surfaceTail.contains(where: isKanji) else { return nil }
        let baseKana = hiragana(baseReading)
        guard baseKana.hasSuffix(hiragana(baseTail)) else { return nil }
        return String(baseKana.dropLast(baseTail.count)) + hiragana(surfaceTail)
    }

    /// Katakana → hiragana (the katakana block maps down by 0x60); everything else as-is,
    /// so OpenJTalk's katakana pron compares against JMdict's hiragana readings.
    static func hiragana(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            guard (0x30A1...0x30F6).contains(scalar.value),
                  let hira = Unicode.Scalar(scalar.value - 0x60) else { return scalar }
            return hira
        }))
    }

    /// CJK ideographs (URO + Extension A) and the iteration mark 々.
    static func isKanji(_ char: Character) -> Bool {
        char.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)
                || (0x3400...0x4DBF).contains(scalar.value)
                || scalar.value == 0x3005
        }
    }
}
