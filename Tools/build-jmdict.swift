#!/usr/bin/env swift
//
// Builds the JMdict SQLite behind in-reader word lookup (the kanji /
// word meaning popover) and, later, the katakana→English gloss.
//
// Adapted from an earlier `build-jmdict.swift` tool. Two modes:
//
//   swift Tools/build-jmdict.swift [output.sqlite]          full build (needs data/JMdict_e.gz)
//   swift Tools/build-jmdict.swift --seed [output.sqlite]   small curated seed (no source file)
//
// Full pipeline:
//   1. gunzip `data/JMdict_e.gz` to a temp XML file (system `gunzip`, no SPM dep).
//   2. Stream-parse with Foundation's `XMLParser`, accumulating one entry at a time.
//   3. Write each entry to SQLite via the raw sqlite3 C API (no GRDB at build time).
//
// Seed mode emits a few dozen common entries embedded below, so a fresh checkout
// ships a working dictionary (bundled as a package resource) without the ~40 MB
// full build. `make dict` produces the full dictionary into Application Support,
// which the runtime store prefers over the bundled seed.
//
// Schema (denormalized for read-only fast lookup):
//   entry(id, senses_json)
//   entry_form(entry_id, form, is_kanji)            -- INDEX form
//   furigana(form, reading, segmentation)           -- INDEX form
// One entry has many forms (kanji + readings) and one denormalized JSON blob of senses.
// `furigana` carries the JmdictFurigana per-kanji ruby segmentation (Doublevil,
// CC BY-SA 4.0): full mode ingests data/JmdictFurigana.txt (override the path with the
// JMDICT_FURIGANA_PATH env var); seed mode embeds a few fixture rows.
//
// JMdict is licensed CC-BY-SA-4.0 (the Electronic Dictionary Research and Development
// Group, James Breen) — the app surfaces this attribution in About.

import Foundation
import SQLite3

// MARK: - Domain models

struct Sense: Encodable {
    let pos: [String]      // parts of speech (n, v1, adj-na, …)
    let glosses: [String]  // English meanings
}

struct Entry {
    var id: Int = 0        // JMdict ent_seq
    var kanjiForms: [String] = []
    var kanaForms: [String] = []
    var senses: [Sense] = []
    /// The English source word for a loanword (from <lsource xml:lang="eng">, not
    /// wasei). Powers the katakana→English gloss; nil for everything else, so wasei-eigo
    /// and non-English loans are never glossed (silent miss beats a wrong gloss).
    var englishGloss: String?
}

// MARK: - XML parser

/// Streams JMdict XML, emitting one fully-built `Entry` at a time via `onEntry`.
final class JMdictParser: NSObject, XMLParserDelegate {
    var onEntry: (Entry) -> Void = { _ in }

    private var current: Entry?
    private var elementStack: [String] = []
    private var text = ""

    // sense-in-progress (one entry can have many)
    private var currentPOS: [String] = []
    private var currentGlosses: [String] = []
    // English-loanword detection (entry-level). JMdict OMITS <lsource> for English
    // loanwords (English is the assumed default), so the positive signal is the
    // gai1/gai2 reading-priority tag (gairaigo); <lsource> instead flags NON-English
    // origins (パン=Portuguese) and wasei-eigo, which we must exclude.
    private var entryIsGairaigo = false        // any reading tagged gai1/gai2
    private var entryHasForeignOrWasei = false // any <lsource> non-English or wasei
    private var entryEnglishLsource: String?   // explicit English source word, if noted
    private var currentLsourceIsEng = false    // the <lsource> being read is English, non-wasei

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes: [String: String]) {
        elementStack.append(elementName)
        text = ""
        switch elementName {
        case "entry":
            current = Entry()
            entryIsGairaigo = false
            entryHasForeignOrWasei = false
            entryEnglishLsource = nil
        case "sense":
            currentPOS = []
            currentGlosses = []
        case "lsource":
            // xml:lang defaults to "eng" when omitted (JMdict DTD); ls_wasei="y" marks
            // wasei-eigo (Japanese-made pseudo-English). A non-English or wasei source
            // disqualifies the entry from the English gloss.
            let lang = attributes["xml:lang"] ?? "eng"
            let wasei = attributes["ls_wasei"] == "y"
            currentLsourceIsEng = (lang == "eng" && !wasei)
            if lang != "eng" || wasei { entryHasForeignOrWasei = true }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        defer { _ = elementStack.popLast(); text = "" }
        guard current != nil else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "ent_seq":
            if let id = Int(trimmed) { current?.id = id }
        case "keb":
            if !trimmed.isEmpty { current?.kanjiForms.append(trimmed) }
        case "reb":
            if !trimmed.isEmpty { current?.kanaForms.append(trimmed) }
        case "pos":
            if !trimmed.isEmpty { currentPOS.append(trimmed) }
        case "gloss":
            if !trimmed.isEmpty { currentGlosses.append(trimmed) }
        case "re_pri":
            // "gai1"/"gai2" mark a common loanword (gairaigo) — the positive English-loan
            // signal, since English <lsource> is usually omitted.
            if trimmed == "gai1" || trimmed == "gai2" { entryIsGairaigo = true }
        case "lsource":
            if currentLsourceIsEng, entryEnglishLsource == nil, !trimmed.isEmpty {
                entryEnglishLsource = trimmed   // an explicit English source word
            }
        case "sense":
            current?.senses.append(Sense(pos: currentPOS, glosses: currentGlosses))
            currentPOS = []
            currentGlosses = []
        case "entry":
            if var entry = current, entry.id > 0, !entry.senses.isEmpty {
                // Gloss a loanword (gai-tagged or explicit English source) unless it's a
                // non-English loan or wasei. Source = explicit <lsource> word, else the
                // first gloss.
                if entryIsGairaigo || entryEnglishLsource != nil, !entryHasForeignOrWasei {
                    entry.englishGloss = entryEnglishLsource ?? entry.senses.first?.glosses.first
                }
                onEntry(entry)
            }
            current = nil
        default:
            break
        }
    }
}

// MARK: - SQLite writer

final class JMdictWriter {
    private var db: OpaquePointer?
    private var insertEntry: OpaquePointer?
    private var insertForm: OpaquePointer?
    private var insertFurigana: OpaquePointer?
    // Sorted keys so consecutive builds emit identical senses_json (seed determinism).
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    init(at path: String) {
        try? FileManager.default.removeItem(atPath: path)
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            fatalError("Could not open SQLite at \(path)")
        }
        exec("PRAGMA journal_mode = OFF;")
        exec("PRAGMA synchronous = OFF;")
        exec("PRAGMA temp_store = MEMORY;")
        exec("""
        CREATE TABLE entry (
          id INTEGER PRIMARY KEY,
          senses_json TEXT NOT NULL,
          gloss_eng TEXT
        );
        """)
        exec("""
        CREATE TABLE entry_form (
          entry_id INTEGER NOT NULL,
          form TEXT NOT NULL,
          is_kanji INTEGER NOT NULL
        );
        """)
        exec("CREATE INDEX idx_entry_form_form ON entry_form(form);")
        // entry_id side of form→forms self-joins (kanaReadings) and the per-entry form
        // fetch in lookup(form:); without it each is a full entry_form scan.
        exec("CREATE INDEX idx_entry_form_entry ON entry_form(entry_id);")
        exec("""
        CREATE TABLE furigana (
          form TEXT NOT NULL,
          reading TEXT NOT NULL,
          segmentation TEXT NOT NULL
        );
        """)
        exec("CREATE INDEX idx_furigana_form ON furigana(form);")
        exec("BEGIN TRANSACTION;")

        sqlite3_prepare_v2(db, "INSERT INTO entry (id, senses_json, gloss_eng) VALUES (?, ?, ?)", -1,
                           &insertEntry, nil)
        sqlite3_prepare_v2(db, "INSERT INTO entry_form (entry_id, form, is_kanji) VALUES (?, ?, ?)", -1,
                           &insertForm, nil)
        sqlite3_prepare_v2(db, "INSERT INTO furigana (form, reading, segmentation) VALUES (?, ?, ?)", -1,
                           &insertFurigana, nil)
    }

    deinit {
        if insertEntry != nil { sqlite3_finalize(insertEntry) }
        if insertForm != nil { sqlite3_finalize(insertForm) }
        if insertFurigana != nil { sqlite3_finalize(insertFurigana) }
        if db != nil { sqlite3_close(db) }
    }

    func write(_ entry: Entry) {
        let json = (try? encoder.encode(entry.senses)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        bindEntry(id: entry.id, sensesJSON: json, glossEng: entry.englishGloss)
        for form in entry.kanjiForms { bindForm(entryID: entry.id, form: form, isKanji: 1) }
        for form in entry.kanaForms { bindForm(entryID: entry.id, form: form, isKanji: 0) }
    }

    func writeFurigana(form: String, reading: String, segmentation: String) {
        sqlite3_reset(insertFurigana)
        sqlite3_bind_text(insertFurigana, 1, (form as NSString).utf8String, -1, nil)
        sqlite3_bind_text(insertFurigana, 2, (reading as NSString).utf8String, -1, nil)
        sqlite3_bind_text(insertFurigana, 3, (segmentation as NSString).utf8String, -1, nil)
        if sqlite3_step(insertFurigana) != SQLITE_DONE {
            print("INSERT furigana failed: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    func finish() {
        exec("COMMIT;")
        exec("VACUUM;")
    }

    private func bindEntry(id: Int, sensesJSON: String, glossEng: String?) {
        sqlite3_reset(insertEntry)
        sqlite3_bind_int(insertEntry, 1, Int32(id))
        sqlite3_bind_text(insertEntry, 2, (sensesJSON as NSString).utf8String, -1, nil)
        if let glossEng {
            sqlite3_bind_text(insertEntry, 3, (glossEng as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(insertEntry, 3)
        }
        if sqlite3_step(insertEntry) != SQLITE_DONE {
            print("INSERT entry failed: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    private func bindForm(entryID: Int, form: String, isKanji: Int32) {
        sqlite3_reset(insertForm)
        sqlite3_bind_int(insertForm, 1, Int32(entryID))
        sqlite3_bind_text(insertForm, 2, (form as NSString).utf8String, -1, nil)
        sqlite3_bind_int(insertForm, 3, isKanji)
        if sqlite3_step(insertForm) != SQLITE_DONE {
            print("INSERT form failed: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    private func exec(_ sql: String) {
        var errmsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errmsg) != SQLITE_OK {
            let msg = errmsg.map { String(cString: $0) } ?? "?"
            sqlite3_free(errmsg)
            fatalError("SQLite error on `\(sql.prefix(80))…`: \(msg)")
        }
    }
}

// MARK: - JmdictFurigana ingestion
//
// Mirrors `JmdictFuriganaParser` in KBDictionaryKit (the canonical, unit-tested
// implementation) — this script runs standalone via `swift Tools/build-jmdict.swift`
// and cannot import the SPM package, so the validation is duplicated here. Keep in sync.

/// Parses one JmdictFurigana line (`kanji|reading|segmentation`), stripping a UTF-8 BOM
/// if present; nil (never a crash) for malformed lines.
func parseFuriganaLine(_ rawLine: String) -> (form: String, reading: String, segmentation: String)? {
    var line = rawLine
    if line.hasPrefix("\u{FEFF}") { line.removeFirst() }
    let fields = line.split(separator: "|", omittingEmptySubsequences: false)
    guard fields.count == 3 else { return nil }
    let form = String(fields[0])
    let reading = String(fields[1])
    let segmentation = String(fields[2])
    guard !form.isEmpty, !reading.isEmpty,
          isValidSegmentation(segmentation, formLength: form.count) else { return nil }
    return (form, reading, segmentation)
}

/// Validates a `;`-separated `<idx>(-<endIdx>):<kana>` segmentation against the form's
/// character count: numeric in-range indices, non-empty kana, no overlapping spans.
func isValidSegmentation(_ segmentation: String, formLength: Int) -> Bool {
    guard !segmentation.isEmpty, formLength > 0 else { return false }
    var ranges: [Range<Int>] = []
    for item in segmentation.split(separator: ";", omittingEmptySubsequences: false) {
        guard let colon = item.firstIndex(of: ":"), !item[item.index(after: colon)...].isEmpty else { return false }
        let indexPart = item[..<colon]
        let start: Int
        let end: Int
        if let dash = indexPart.firstIndex(of: "-") {
            guard let lower = Int(indexPart[..<dash]),
                  let upper = Int(indexPart[indexPart.index(after: dash)...]) else { return false }
            start = lower
            end = upper
        } else {
            guard let only = Int(indexPart) else { return false }
            start = only
            end = only
        }
        guard start >= 0, end >= start, end < formLength else { return false }
        ranges.append(start..<(end + 1))
    }
    var cursor = 0
    for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
        guard range.lowerBound >= cursor else { return false }  // overlap
        cursor = range.upperBound
    }
    return true
}

/// Streams the JmdictFurigana dataset into the `furigana` table, skipping malformed
/// lines. Missing file = warning, not failure — `make dict` keeps working without the
/// download; the furigana tier just has no data.
func ingestFurigana(from path: String, into writer: JMdictWriter) {
    guard FileManager.default.fileExists(atPath: path) else {
        print("WARN: missing \(path) — skipping furigana ingestion "
            + "(download JmdictFurigana.txt into data/ or set JMDICT_FURIGANA_PATH).")
        return
    }
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        print("WARN: could not read \(path) as UTF-8 — skipping furigana ingestion.")
        return
    }
    var rows = 0
    var skipped = 0
    for line in text.split(whereSeparator: \.isNewline) {
        if let parsed = parseFuriganaLine(String(line)) {
            writer.writeFurigana(form: parsed.form, reading: parsed.reading, segmentation: parsed.segmentation)
            rows += 1
        } else {
            skipped += 1
        }
    }
    print("  \(rows) furigana rows (\(skipped) malformed lines skipped)")
}

// MARK: - Seed data

/// A small, hand-curated set of common entries so a fresh checkout has a working
/// dictionary out of the box (bundled as a package resource). Real coverage comes
/// from `make dict`. Ids are synthetic (negative range) so they never collide with
/// real JMdict ent_seq values if both are ever merged.
func seedEntries() -> [Entry] {
    func entry(_ id: Int, kanji: [String], kana: [String], _ senses: [(String, [String])],
               englishGloss: String? = nil) -> Entry {
        Entry(id: id, kanjiForms: kanji, kanaForms: kana,
              senses: senses.map { Sense(pos: [$0.0], glosses: $0.1) }, englishGloss: englishGloss)
    }
    var id = -1
    func next() -> Int { defer { id -= 1 }; return id }
    return [
        entry(next(), kanji: ["日本語"], kana: ["にほんご"], [("n", ["Japanese (language)"])]),
        entry(next(), kanji: ["言葉"], kana: ["ことば"], [("n", ["language", "word", "words", "speech"])]),
        entry(next(), kanji: ["本"], kana: ["ほん"], [("n", ["book", "volume"])]),
        entry(next(), kanji: ["読む"], kana: ["よむ"], [("v5m", ["to read"])]),
        entry(next(), kanji: ["食べる"], kana: ["たべる"], [("v1", ["to eat"])]),
        entry(next(), kanji: ["水"], kana: ["みず"], [("n", ["water (cold, fresh)"])]),
        entry(next(), kanji: ["猫"], kana: ["ねこ"], [("n", ["cat"])]),
        entry(next(), kanji: ["犬"], kana: ["いぬ"], [("n", ["dog"])]),
        entry(next(), kanji: ["人"], kana: ["ひと"], [("n", ["person", "human being"])]),
        entry(next(), kanji: ["学校"], kana: ["がっこう"], [("n", ["school"])]),
        entry(next(), kanji: ["先生"], kana: ["せんせい"], [("n", ["teacher", "instructor", "master"])]),
        entry(next(), kanji: ["学生"], kana: ["がくせい"], [("n", ["student (esp. a university student)"])]),
        entry(next(), kanji: ["時間"], kana: ["じかん"], [("n", ["time", "hour"])]),
        entry(next(), kanji: ["今日"], kana: ["きょう"], [("n", ["today", "this day"])]),
        entry(next(), kanji: ["明日"], kana: ["あした"], [("n", ["tomorrow"])]),
        entry(next(), kanji: ["国"], kana: ["くに"], [("n", ["country", "state", "region"])]),
        entry(next(), kanji: ["山"], kana: ["やま"], [("n", ["mountain", "hill"])]),
        entry(next(), kanji: ["川"], kana: ["かわ"], [("n", ["river", "stream"])]),
        entry(next(), kanji: ["手"], kana: ["て"], [("n", ["hand", "arm"])]),
        entry(next(), kanji: ["目"], kana: ["め"], [("n", ["eye", "eyeball"])]),
        entry(next(), kanji: ["心"], kana: ["こころ"], [("n", ["mind", "heart", "spirit"])]),
        entry(next(), kanji: ["力"], kana: ["ちから"], [("n", ["force", "strength", "power"])]),
        entry(next(), kanji: ["美しい"], kana: ["うつくしい"], [("adj-i", ["beautiful", "lovely"])]),
        entry(next(), kanji: ["大きい"], kana: ["おおきい"], [("adj-i", ["big", "large", "great"])]),
        entry(next(), kanji: ["小さい"], kana: ["ちいさい"], [("adj-i", ["small", "little", "tiny"])]),
        entry(next(), kanji: ["新しい"], kana: ["あたらしい"], [("adj-i", ["new", "fresh"])]),
        entry(next(), kanji: ["古い"], kana: ["ふるい"], [("adj-i", ["old", "aged", "ancient"])]),
        entry(next(), kanji: ["高い"], kana: ["たかい"], [("adj-i", ["high", "tall", "expensive"])]),
        entry(next(), kanji: ["行く"], kana: ["いく"], [("v5k-s", ["to go", "to move toward"])]),
        entry(next(), kanji: ["来る"], kana: ["くる"], [("vk", ["to come", "to approach"])]),
        entry(next(), kanji: ["見る"], kana: ["みる"], [("v1", ["to see", "to look", "to watch"])]),
        entry(next(), kanji: ["聞く"], kana: ["きく"], [("v5k", ["to hear", "to listen", "to ask"])]),
        entry(next(), kanji: ["話す"], kana: ["はなす"], [("v5s", ["to talk", "to speak"])]),
        entry(next(), kanji: ["書く"], kana: ["かく"], [("v5k", ["to write", "to compose"])]),
        entry(next(), kanji: ["一生懸命"], kana: ["いっしょうけんめい"],
              [("adj-na", ["with utmost effort", "as hard as one can"])]),
        // Furigana-tier fixtures: forms OpenJTalk's dictionary lacks (這入る, 行衛, 無暗)
        // plus the readings the ReadingValidator tests corroborate against.
        entry(next(), kanji: ["這入る"], kana: ["はいる"], [("v5r", ["to enter", "to come in"])]),
        entry(next(), kanji: ["行衛"], kana: ["ゆくえ"], [("n", ["(one's) whereabouts"])]),
        entry(next(), kanji: ["行う"], kana: ["おこなう"], [("v5u", ["to perform", "to conduct", "to carry out"])]),
        // 無闇/無暗 are variant kanji forms of ONE entry — the 無暗 repair reading resolves
        // through this entry_form row even though JmdictFurigana has no 無暗 segmentation.
        entry(next(), kanji: ["無闇", "無暗"], kana: ["むやみ"],
              [("adj-na", ["thoughtless", "reckless", "excessive"])]),
        entry(next(), kanji: ["俄か"], kana: ["にわか"], [("adj-na", ["sudden", "abrupt", "improvised"])]),
        entry(next(), kanji: ["一つ"], kana: ["ひとつ"], [("n", ["one", "one thing"])]),
        entry(next(), kanji: ["大人"], kana: ["おとな"], [("n", ["adult", "grown-up"])]),
        // コーヒー is from Dutch "koffie", not English — deliberately left un-glossed to
        // demonstrate the English-only gate (silent miss beats a wrong gloss).
        entry(next(), kanji: [], kana: ["コーヒー"], [("n", ["coffee"])]),
        entry(next(), kanji: [], kana: ["コミュニケーション"], [("n", ["communication"])],
              englishGloss: "communication"),
        entry(next(), kanji: [], kana: ["テレビ"], [("n", ["television", "TV"])],
              englishGloss: "television"),
        entry(next(), kanji: [], kana: ["コンピューター"], [("n", ["computer"])],
              englishGloss: "computer")
    ]
}

// MARK: - Driver

/// Decompress the JMdict archive, flattening its DTD entity references on the way through.
///
/// JMdict writes parts of speech as entity references: `<pos>&adj-i;</pos>`, declared in the
/// file's internal DTD. `XMLParser` does not deliver those as character data, so
/// `foundCharacters` never fires for `<pos>` and every sense came out with an empty `pos`
/// array: 218,527 entries, not one with a part of speech, and a blank label beside every
/// sense in the lookup panel.
///
/// The schema wants the entity NAME (`n`, `v1`, `adj-na`), which is exactly what the
/// reference already spells, so rewriting `&adj-i;` to `adj-i` is all that is needed. The
/// five XML built-ins are parked behind control characters first and restored afterwards,
/// since those must survive as real references for the parser to decode.
func gunzip(_ source: URL, to destination: URL) {
    try? FileManager.default.removeItem(at: destination)
    let protectBuiltins = "s/&(amp|lt|gt|quot|apos);/\\x01\\1\\x02/g"
    let flattenEntities = "s/&([a-zA-Z0-9-]+);/\\1/g"
    let restoreBuiltins = "s/\\x01([a-z]+)\\x02/\\&\\1;/g"
    let rewrite = "sed -E '\(protectBuiltins); \(flattenEntities); \(restoreBuiltins)'"
    let proc = Process()
    proc.launchPath = "/bin/sh"
    proc.arguments = [
        // `pipefail` matters: without it the pipeline reports SED's status, so a failed
        // gunzip would sail past the check below and leave an empty XML to parse.
        "-c", "set -o pipefail; gunzip -c \"\(source.path)\" | \(rewrite) > \"\(destination.path)\""
    ]
    try? proc.run()
    proc.waitUntilExit()
    guard proc.terminationStatus == 0 else {
        fatalError("gunzip failed (status \(proc.terminationStatus))")
    }
}

var args = Array(CommandLine.arguments.dropFirst())
let seedMode = args.first == "--seed"
if seedMode { args.removeFirst() }

if seedMode {
    let outputPath = args.first ?? "Packages/KBDictionaryKit/Sources/KBDictionaryKit/Resources/jmdict-seed.sqlite"
    let outURL = URL(fileURLWithPath: outputPath)
    try? FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    print("seed → \(outputPath)")
    let writer = JMdictWriter(at: outputPath)
    let entries = seedEntries()
    for entry in entries { writer.write(entry) }
    // Fixture furigana rows only (verified against JmdictFurigana 2.3.1) — the seed
    // never bundles the full dataset. 無暗 deliberately has NO row: the dataset lacks
    // it, and tests pin that the sibling variant 無闇's segmentation is not borrowed.
    let seedFurigana: [(form: String, reading: String, segmentation: String)] = [
        ("這入る", "はいる", "0:は;1:い"),
        ("行衛", "ゆくえ", "0:ゆく;1:え"),
        ("俄かに", "にわかに", "0:にわ"),
        ("一つ", "ひとつ", "0:ひと"),
        ("大人", "おとな", "0-1:おとな")
    ]
    for row in seedFurigana {
        writer.writeFurigana(form: row.form, reading: row.reading, segmentation: row.segmentation)
    }
    writer.finish()
    let size = (try? FileManager.default.attributesOfItem(atPath: outputPath)[.size] as? Int) ?? 0
    print("done — \(entries.count) seed entries, \(size / 1024) KB at \(outputPath)")
    exit(0)
}

let outputPath = args.first ?? "build/jmdict.sqlite"
let inputGZ = URL(fileURLWithPath: "data/JMdict_e.gz")
guard FileManager.default.fileExists(atPath: inputGZ.path) else {
    fatalError("Missing \(inputGZ.path) — download JMdict_e.gz into data/ and run from the repo root.")
}

let tempXML = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("JMdict_e.\(getpid()).xml")
print("gunzip → \(tempXML.lastPathComponent)")
gunzip(inputGZ, to: tempXML)
defer { try? FileManager.default.removeItem(at: tempXML) }

let outURL = URL(fileURLWithPath: outputPath)
try? FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)
print("writing → \(outputPath)")

let writer = JMdictWriter(at: outputPath)
let delegate = JMdictParser()
var written = 0
delegate.onEntry = { entry in
    writer.write(entry)
    written += 1
    if written % 20_000 == 0 { print("  \(written) entries") }
}

guard let parser = XMLParser(contentsOf: tempXML) else {
    fatalError("Could not open parser for \(tempXML.path)")
}
parser.delegate = delegate
parser.shouldResolveExternalEntities = false
let ok = parser.parse()
if !ok, let err = parser.parserError {
    print("WARN: XML parser ended with \(err) at line \(parser.lineNumber) col \(parser.columnNumber)")
}

let furiganaPath = ProcessInfo.processInfo.environment["JMDICT_FURIGANA_PATH"] ?? "data/JmdictFurigana.txt"
print("furigana ← \(furiganaPath)")
ingestFurigana(from: furiganaPath, into: writer)

writer.finish()

let size = (try? FileManager.default.attributesOfItem(atPath: outputPath)[.size] as? Int) ?? 0
print("done — \(written) entries, \(size / 1_000_000) MB at \(outputPath)")
