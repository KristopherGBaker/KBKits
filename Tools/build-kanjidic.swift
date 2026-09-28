#!/usr/bin/env swift
//
// Builds the KANJIDIC SQLite behind kanji study cards (issue 033).
//
//   swift Tools/build-kanjidic.swift [output.sqlite]
//
// Unlike JMdict, the output is small enough to SHIP: JMdict is ~66 MB and lives in
// Application Support, while the kanji a learner actually meets fit in a few hundred
// kilobytes. So this writes a package resource that is committed, and a fresh clone has
// working kanji cards with no `make` step and nothing to download at runtime.
//
// Pipeline:
//   1. gunzip `data/kanjidic2.xml.gz` to a temp XML file (system `gunzip`, no SPM dep).
//   2. Stream-parse with Foundation's `XMLParser`, one <character> at a time.
//   3. Write to SQLite via the raw sqlite3 C API (no GRDB at build time), matching
//      `build-jmdict.swift`.
//
// **What is deliberately dropped.** KANJIDIC2 carries thirty-odd dictionary index numbers
// per character (Nelson, Halpern, Heisig, Morohashi...), every non-English meaning, radical
// decompositions and codepoints. None of it belongs on a study card, and keeping it would
// multiply the file for data nothing reads.
//
// **And which characters are kept.** Only those with a school grade, a frequency rank or an
// old-JLPT level - about 3,000 of the 13,000. The rest are historical variants and personal
// name characters that a reader will not meet in a book, and a card offered for one would be
// noise at exactly the moment the reader is trying to read.
//
// KANJIDIC2 is licensed CC BY-SA 4.0 by the Electronic Dictionary Research and Development
// Group, the same group and the same licence as the JMdict this app already ships.
//
// Schema (one row per character, read-only):
//   kanji(character TEXT PRIMARY KEY, on_readings TEXT, kun_readings TEXT,
//         meanings TEXT, stroke_count INTEGER, grade INTEGER, frequency INTEGER)
// The three list columns are JSON arrays of strings, decoded on read.
import Foundation
import SQLite3

// MARK: - Model

struct Kanji {
    var character = ""
    var onReadings: [String] = []
    var kunReadings: [String] = []
    var meanings: [String] = []
    var strokeCount: Int?
    var grade: Int?
    var frequency: Int?
    var oldJLPT: Int?

    /// Whether this character is one a reader plausibly meets. See the note at the top:
    /// everything else is a historical variant or a name-only character.
    var isWorthShipping: Bool {
        guard !meanings.isEmpty else { return false }
        return grade != nil || frequency != nil || oldJLPT != nil
    }
}

// MARK: - Parsing

final class KanjidicParser: NSObject, XMLParserDelegate {
    private var current: Kanji?
    private var text = ""
    /// The `r_type` of the reading being read, so a Pinyin or Korean reading is not filed
    /// as Japanese. KANJIDIC2 puts every language's reading in the same element.
    private var readingType: String?
    /// True while inside a `<meaning>` with an `m_lang`, i.e. a non-English gloss. English
    /// meanings carry NO attribute, so "has no m_lang" is the test rather than `m_lang="en"`.
    private var skippingMeaning = false
    /// `<stroke_count>` can appear more than once (the first is the accepted count, the rest
    /// are miscounts recorded for lookup); only the first is kept.
    private var seenStrokeCount = false

    private(set) var kanji: [Kanji] = []

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        text = ""
        switch name {
        case "character":
            current = Kanji()
            seenStrokeCount = false
        case "reading":
            readingType = attributes["r_type"]
        case "meaning":
            skippingMeaning = attributes["m_lang"] != nil
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { text = "" }
        switch name {
        case "literal":
            current?.character = value
        case "reading":
            switch readingType {
            case "ja_on": current?.onReadings.append(value)
            case "ja_kun": current?.kunReadings.append(value)
            default: break
            }
            readingType = nil
        case "meaning":
            if !skippingMeaning, !value.isEmpty { current?.meanings.append(value) }
            skippingMeaning = false
        case "stroke_count":
            if !seenStrokeCount { current?.strokeCount = Int(value); seenStrokeCount = true }
        case "grade":
            current?.grade = Int(value)
        case "freq":
            current?.frequency = Int(value)
        case "jlpt":
            current?.oldJLPT = Int(value)
        case "character":
            if let entry = current, !entry.character.isEmpty, entry.isWorthShipping {
                kanji.append(entry)
            }
            current = nil
        default:
            break
        }
    }
}

// MARK: - Writing

final class KanjiWriter {
    private var db: OpaquePointer?
    private var insert: OpaquePointer?

    init(path: String) {
        try? FileManager.default.removeItem(atPath: path)
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            fatalError("could not open \(path)")
        }
        exec("PRAGMA journal_mode = OFF")
        exec("PRAGMA synchronous = OFF")
        exec("""
            CREATE TABLE kanji (
              character TEXT PRIMARY KEY,
              on_readings TEXT NOT NULL,
              kun_readings TEXT NOT NULL,
              meanings TEXT NOT NULL,
              stroke_count INTEGER,
              grade INTEGER,
              frequency INTEGER
            )
            """)
        exec("BEGIN")
        sqlite3_prepare_v2(db, """
            INSERT OR REPLACE INTO kanji
            (character, on_readings, kun_readings, meanings, stroke_count, grade, frequency)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """, -1, &insert, nil)
    }

    private func exec(_ sql: String) {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK, let error {
            fatalError("sqlite: \(String(cString: error))")
        }
    }

    private func json(_ values: [String]) -> String {
        let data = (try? JSONEncoder().encode(values)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    func write(_ entry: Kanji) {
        guard let insert else { return }
        sqlite3_reset(insert)
        // SQLITE_TRANSIENT: sqlite must copy these strings, because the Swift temporaries
        // backing them are gone by the time the statement steps.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(insert, 1, entry.character, -1, transient)
        sqlite3_bind_text(insert, 2, json(entry.onReadings), -1, transient)
        sqlite3_bind_text(insert, 3, json(entry.kunReadings), -1, transient)
        sqlite3_bind_text(insert, 4, json(entry.meanings), -1, transient)
        bind(insert, 5, entry.strokeCount)
        bind(insert, 6, entry.grade)
        bind(insert, 7, entry.frequency)
        guard sqlite3_step(insert) == SQLITE_DONE else {
            fatalError("insert failed for \(entry.character)")
        }
    }

    private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: Int?) {
        if let value {
            sqlite3_bind_int(statement, index, Int32(value))
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    func finish() {
        exec("COMMIT")
        exec("VACUUM")
        sqlite3_finalize(insert)
        sqlite3_close(db)
    }
}

// MARK: - Driver

let arguments = CommandLine.arguments
let output = arguments.count > 1 ? arguments[1] : "kanjidic.sqlite"
let sourceGzip = ProcessInfo.processInfo.environment["KANJIDIC_PATH"] ?? "data/kanjidic2.xml.gz"

guard FileManager.default.fileExists(atPath: sourceGzip) else {
    FileHandle.standardError.write(Data("""
        Missing \(sourceGzip) — download it from http://www.edrdg.org/kanjidic/kanjidic2.xml.gz
        into data/, or set KANJIDIC_PATH.

        """.utf8))
    exit(1)
}

let temporaryXML = NSTemporaryDirectory() + "kanjidic2-\(UUID().uuidString).xml"
let gunzip = Process()
gunzip.executableURL = URL(fileURLWithPath: "/usr/bin/env")
gunzip.arguments = ["sh", "-c", "gunzip -c \(sourceGzip) > \(temporaryXML)"]
try gunzip.run()
gunzip.waitUntilExit()
guard gunzip.terminationStatus == 0 else { fatalError("gunzip failed") }
defer { try? FileManager.default.removeItem(atPath: temporaryXML) }

let parser = XMLParser(contentsOf: URL(fileURLWithPath: temporaryXML))!
// KANJIDIC2 ships a large internal DTD. Resolving entities is unnecessary here (unlike
// JMdict, whose part-of-speech tags ARE entities) and pulling in external ones would make
// the build reach the network.
parser.shouldResolveExternalEntities = false
let delegate = KanjidicParser()
parser.delegate = delegate
guard parser.parse() else {
    fatalError("parse failed: \(parser.parserError.map(String.init(describing:)) ?? "unknown")")
}

let writer = KanjiWriter(path: output)
for entry in delegate.kanji { writer.write(entry) }
writer.finish()

let size = (try? FileManager.default.attributesOfItem(atPath: output))?[.size] as? Int ?? 0
print("Wrote \(delegate.kanji.count) kanji to \(output) (\(size / 1024) KB)")
