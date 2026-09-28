// This builds its own SQLite fixtures with GRDB and drives the two SQLite storages directly, so
// like `MalformedDatabaseTests` it cannot merely skip where GRDB is absent: it would not compile.
#if canImport(GRDB)
import Foundation
import GRDB
import Testing
@testable import KBDictionaryKit

/// No lookup term and no database path may reach stdout.
///
/// A term is what a person is reading and a path carries their home directory, and a `print` in
/// a library writes both to every consuming app's console, in release, with no way to turn it
/// off. Diagnostics now go to `Logger` with `privacy: .private`.
///
/// The check has to be behavioural. `Logger` and `print` are indistinguishable to a test that
/// only inspects return values, so these tests force a real open failure and a real query
/// failure with a distinctive path and distinctive terms in them, capture the process's stdout
/// for the duration by `dup2`ing fd 1 onto a pipe, and assert that none of those strings came
/// back. Every one of the seven removed `print` statements is covered: restoring any single one
/// of them, in `SQLiteJMDictStorage` or in `SQLiteKanjiStorage`, fails a test here.
///
/// `.serialized` because fd 1 is process-wide: two of these running at once would each capture
/// part of the other's window.
@Suite("Lookup terms and paths never reach stdout", .serialized)
struct StdoutPrivacyTests {

    // MARK: The strings that must not appear

    /// Distinctive enough that finding it in stdout cannot be a coincidence, and shaped like a
    /// real lookup, because that is the point: a word someone typed is not diagnostics.
    private let kanjiTerm = "禁帯出語ZKBTERM"
    private let katakanaTerm = "カタカナZKBGLOSS"
    private let readingTerm = "きんたいしゅつごZKBREADING"
    /// A real prefix of `kanjiTerm`, so the prefix scan below has something to find before the
    /// file breaks and its empty answer afterwards means the same thing the others do.
    private let kanjiPrefix = "禁帯出語ZKB"

    /// A fixture under its own directory, so the DIRECTORY name is a distinctive string too:
    /// a real path leaks someone's home directory, and a test can only stand in for that with a
    /// component nothing else would produce.
    private func fixtureDirectory() throws -> (url: URL, token: String) {
        let token = "kb-stdout-privacy-\(UUID().uuidString)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(token)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return (url, token)
    }

    /// Fails the test for each string that reached stdout, naming it.
    ///
    /// The search is over BYTES, not over a decoded string: decoding whatever else happened to
    /// be on stdout can fail, and a decode that can fail is one that could turn a leak into "no
    /// output at all". The decode is used only to quote the bytes back in a failure.
    private func expect(_ output: Data, mentionsNoneOf strings: [String]) {
        // The prefixes the removed `print`s carried, in both storages. These catch a restored
        // one even if its interpolated term happened to be spelled differently.
        for string in strings + ["SQLiteJMDictStorage: ", "SQLiteKanjiStorage: "] {
            #expect(output.range(of: Data(string.utf8)) == nil,
                    """
                    stdout carried "\(string)"; diagnostics must not name it. \
                    stdout was: \(render(output))
                    """)
        }
    }

    private func render(_ output: Data) -> String {
        String(bytes: output, encoding: .utf8) ?? "\(output.count) bytes that are not UTF-8"
    }

    // MARK: Opening

    @Test("a dictionary that cannot be opened does not print its path")
    func openFailureKeepsThePathOffStdout() throws {
        let (directory, token) = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("jmdict-not-a-database.sqlite")
        // Opens as a file, fails as SQLite: the `catch` in `init` is what used to print the path.
        try Data(repeating: 0x7f, count: 4096).write(to: url)

        var storage: SQLiteJMDictStorage?
        let output = try capturingStandardOutput {
            storage = SQLiteJMDictStorage(url: url)
        }

        #expect(storage?.isReady == false, "a garbage file must not report itself ready")
        expect(output, mentionsNoneOf: [url.path, directory.path, token])
    }

    @Test("a dictionary with the wrong schema does not print its path")
    func schemaRejectionKeepsThePathOffStdout() throws {
        let (directory, token) = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("jmdict-wrong-schema.sqlite")
        try build(url, ["CREATE TABLE unrelated (x INTEGER)"])

        var storage: SQLiteJMDictStorage?
        let output = try capturingStandardOutput {
            storage = SQLiteJMDictStorage(url: url)
        }

        #expect(storage?.isReady == false, "a database without the schema must not report ready")
        expect(output, mentionsNoneOf: [url.path, directory.path, token])
    }

    // MARK: The kanji database, the same rule

    /// `SQLiteKanjiStorage` printed its path from the same shape of `catch`, so it is the same
    /// regression and it gets the same check. Its lookup never printed the character and still
    /// does not, which is why there is no query test for it here: `entry(for:)` swallows with
    /// `try?` and says nothing anywhere.
    @Test("a kanji database that cannot be opened does not print its path")
    func kanjiOpenFailureKeepsThePathOffStdout() throws {
        let (directory, token) = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("kanjidic-not-a-database.sqlite")
        try Data(repeating: 0x7f, count: 4096).write(to: url)

        var storage: SQLiteKanjiStorage?
        let output = try capturingStandardOutput {
            storage = SQLiteKanjiStorage(url: url)
        }

        #expect(storage?.isReady == false, "a garbage file must not report itself ready")
        expect(output, mentionsNoneOf: [url.path, directory.path, token])
    }

    @Test("a kanji database with the wrong schema does not print its path")
    func kanjiSchemaRejectionKeepsThePathOffStdout() throws {
        let (directory, token) = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("kanjidic-wrong-schema.sqlite")
        try build(url, ["CREATE TABLE unrelated (x INTEGER)"])

        var storage: SQLiteKanjiStorage?
        let output = try capturingStandardOutput {
            storage = SQLiteKanjiStorage(url: url)
        }

        #expect(storage?.isReady == false, "a database without the kanji table is not ready")
        expect(output, mentionsNoneOf: [url.path, directory.path, token])
    }

    // MARK: Querying

    /// Every query method at once, because each one used to print its own term.
    ///
    /// Forcing a query failure takes a database that opens, validates, answers, and THEN breaks:
    /// the storage is opened against a whole dictionary (so `isReady`, the gloss column and the
    /// furigana table are all live and no guard short-circuits a call), the file is then
    /// overwritten with non-SQLite bytes, and every method is called inside the capture window.
    /// No production seam is needed, and none was added.
    @Test("a failing query does not print the term that was looked up")
    func queryFailureKeepsTheTermOffStdout() throws {
        let (directory, token) = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("jmdict-breaks-mid-flight.sqlite")
        try build(url, wholeDictionary)

        let storage = SQLiteJMDictStorage(url: url)
        // The control: before the file breaks, these terms really do resolve, so the empty
        // answers below are the `catch` blocks and not a database that never had the rows.
        #expect(storage.isReady)
        #expect(!storage.entries(matchingForm: kanjiTerm, limit: 5).isEmpty)
        #expect(storage.englishGloss(forKatakana: katakanaTerm) == "restricted")
        #expect(storage.kanaReadings(forForm: kanjiTerm) == [readingTerm])
        #expect(storage.kanaReadings(forKanjiFormsStartingWith: kanjiPrefix, limit: 5)
                == [readingTerm])
        #expect(storage.furiganaSegmentation(form: kanjiTerm, reading: readingTerm) != nil)

        let breaker = try readOnlyConnection(to: url)
        // In place, NOT atomically: an atomic replacement would leave both connections on the
        // old unlinked inode, still answering perfectly.
        let garbage = Data(repeating: 0x5a, count: try Data(contentsOf: url).count)
        try garbage.write(to: url)
        // Proof that the queries below now FAIL rather than return nothing: the same SQL on an
        // equally warmed-up connection throws.
        let term = kanjiTerm
        #expect(throws: (any Error).self) {
            try breaker.read { db in
                try Row.fetchAll(db, sql: "SELECT entry_id FROM entry_form WHERE form = ?",
                                 arguments: [term])
            }
        }

        var results: [String] = []
        let output = try capturingStandardOutput {
            results.append("\(storage.entries(matchingForm: kanjiTerm, limit: 5).count)")
            results.append("\(storage.englishGloss(forKatakana: katakanaTerm) ?? "nil")")
            results.append("\(storage.kanaReadings(forForm: kanjiTerm).count)")
            results.append("\(storage.kanaReadings(forKanjiFormsStartingWith: kanjiPrefix, limit: 5).count)")
            results.append("\(storage.furiganaSegmentation(form: kanjiTerm, reading: readingTerm) ?? "nil")")
        }

        #expect(results == ["0", "nil", "0", "0", "nil"], "a broken file must answer nothing")
        expect(output, mentionsNoneOf: [kanjiTerm, katakanaTerm, readingTerm, kanjiPrefix,
                                        url.path, directory.path, token])
    }

    // MARK: Fixtures

    /// A dictionary with everything these queries can reach: the required schema, the optional
    /// `gloss_eng` column, and the optional `furigana` table.
    private var wholeDictionary: [String] {
        ["""
         CREATE TABLE entry (id INTEGER PRIMARY KEY, senses_json TEXT NOT NULL,
                             gloss_eng TEXT)
         """,
         """
         CREATE TABLE entry_form (entry_id INTEGER NOT NULL, form TEXT NOT NULL,
                                  is_kanji INTEGER NOT NULL)
         """,
         "CREATE TABLE furigana (form TEXT NOT NULL, reading TEXT NOT NULL, segmentation TEXT)",
         """
         INSERT INTO entry (id, senses_json, gloss_eng)
         VALUES (1, '[]', 'restricted')
         """,
         "INSERT INTO entry_form (entry_id, form, is_kanji) VALUES (1, '\(kanjiTerm)', 1)",
         "INSERT INTO entry_form (entry_id, form, is_kanji) VALUES (1, '\(katakanaTerm)', 1)",
         "INSERT INTO entry_form (entry_id, form, is_kanji) VALUES (1, '\(readingTerm)', 0)",
         """
         INSERT INTO furigana (form, reading, segmentation)
         VALUES ('\(kanjiTerm)', '\(readingTerm)', '\(kanjiTerm)[\(readingTerm)]')
         """]
    }

    private func build(_ url: URL, _ statements: [String]) throws {
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            for sql in statements { try db.execute(sql: sql) }
        }
        try queue.close()
    }

    /// A read-only connection that has already read the schema, so it is as warmed up as the
    /// storage's own is when the file underneath them both is replaced.
    private func readOnlyConnection(to url: URL) throws -> DatabaseQueue {
        var config = Configuration()
        config.readonly = true
        let queue = try DatabaseQueue(path: url.path, configuration: config)
        _ = try queue.read { db in try db.tableExists("entry_form") }
        return queue
    }
}

// MARK: - Capturing stdout

/// Whatever the process writes to file descriptor 1 while `body` runs.
///
/// fd 1 is duplicated to a spare descriptor, replaced with the write end of a pipe, and restored in a `defer`
/// that runs before the captured bytes are read, so an assertion failure or a throw inside
/// `body` cannot leave the test run without a console. A thread drains the pipe while `body`
/// runs rather than after it, because a pipe holds only about 64 KB and anything else writing to
/// stdout in the meantime would otherwise be able to wedge the writer.
private func capturingStandardOutput(_ body: () throws -> Void) throws -> Data {
    var ends: [Int32] = [-1, -1]
    guard pipe(&ends) == 0 else { throw StdoutCaptureFailure(call: "pipe", code: errno) }
    let (readEnd, writeEnd) = (ends[0], ends[1])

    let collected = CapturedOutput()
    let drained = DispatchSemaphore(value: 0)
    let drain = Thread {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(readEnd, &buffer, buffer.count)
            if count <= 0 { break }
            collected.append(Data(buffer.prefix(count)))
        }
        drained.signal()
    }
    drain.start()

    fflush(stdout)
    let saved = dup(STDOUT_FILENO)
    guard saved >= 0 else {
        close(readEnd)
        close(writeEnd)
        throw StdoutCaptureFailure(call: "dup", code: errno)
    }
    guard dup2(writeEnd, STDOUT_FILENO) >= 0 else {
        close(saved)
        close(readEnd)
        close(writeEnd)
        throw StdoutCaptureFailure(call: "dup2", code: errno)
    }

    do {
        defer {
            fflush(stdout)
            dup2(saved, STDOUT_FILENO)
            close(saved)
            // The last write end: closing it is what ends the drain thread's read loop.
            close(writeEnd)
            _ = drained.wait(timeout: .now() + 30)
            close(readEnd)
        }
        try body()
    }
    return collected.bytes
}

/// The drain thread's buffer. A class with a lock because the thread fills it and the test
/// reads it.
private final class CapturedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
    }

    var bytes: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

private struct StdoutCaptureFailure: Error, CustomStringConvertible {
    let call: String
    let code: Int32

    var description: String { "\(call) failed with errno \(code)" }
}
#endif
