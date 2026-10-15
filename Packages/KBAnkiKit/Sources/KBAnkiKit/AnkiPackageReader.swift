public import Foundation
import ZIPFoundation

/// Reads an Anki `.apkg` into an ``AnkiCollection``.
///
/// An `.apkg` is a zip holding a SQLite collection plus media. Anki has shipped
/// three names for that collection and two schemas behind them, and a reader that
/// assumes one meets the other in the wild:
///
/// - `collection.anki2`: the legacy schema (11), note types as JSON in `col.models`.
/// - `collection.anki21`: the newer schema (18), note types in their own tables.
/// - `collection.anki21b`: the same, zstd-compressed. This is what a current Anki
///   writes by default, so refusing it would refuse most decks people actually have.
///
/// Which schema a file uses is decided by looking for the tables, not by trusting a
/// version column: the version says what wrote the file, the tables say what is in it.
public struct AnkiPackageReader: Sendable {
    public init() {}

    /// Read the deck at `url`.
    public func read(contentsOf url: URL) throws(AnkiError) -> AnkiCollection {
        let databaseURL = try extractCollection(from: url)
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        let database = try SQLiteDatabase(path: databaseURL.path, access: .openExisting)
        let noteTypes = try readNoteTypes(from: database)
        return AnkiCollection(
            noteTypes: noteTypes,
            decks: try readDecks(from: database),
            notes: try readNotes(
                from: database, noteTypes: noteTypes, deckIDsByNote: try readCardDecks(from: database))
        )
    }

    // MARK: Archive

    /// Pull the collection database out of the archive and onto disk, because SQLite
    /// opens paths rather than bytes.
    private func extractCollection(from url: URL) throws(AnkiError) -> URL {
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw AnkiError.unreadableArchive(error.localizedDescription)
        }

        let names = archive.map(\.path)
        // Newest first: a package holding several is one Anki wrote for more than one
        // version, and the newest database is the complete one. `.anki21b` is the same
        // SQLite file compressed with zstd.
        let supported = ["collection.anki21b", "collection.anki21", "collection.anki2"]
        guard let name = supported.first(where: { names.contains($0) }), let entry = archive[name] else {
            throw AnkiError.notAnAnkiPackage(found: names)
        }
        let isCompressed = name == "collection.anki21b"

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KBAnkiKit-\(UUID().uuidString)", isDirectory: true)
        let destination = directory.appendingPathComponent(name)
        var extracted = Data()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var data = Data()
            _ = try archive.extract(entry) { data.append($0) }
            extracted = data
        } catch {
            throw AnkiError.unreadableArchive(error.localizedDescription)
        }
        // Decompress OUTSIDE the do/catch above: a zstd failure is its own error, and
        // wrapping it as an unreadable archive would blame the zip for the codec.
        let collection = isCompressed ? try ZstdDecompressor.decompress(extracted) : extracted
        do {
            try collection.write(to: destination)
        } catch {
            throw AnkiError.writeFailure(error.localizedDescription)
        }
        return destination
    }

    // MARK: Note types

    private func readNoteTypes(from database: SQLiteDatabase) throws(AnkiError) -> [AnkiNoteType] {
        if try database.hasTable("notetypes") {
            return try readModernNoteTypes(from: database)
        }
        return try readLegacyNoteTypes(from: database)
    }

    /// Schema 18: `notetypes` names them, `fields` orders them.
    private func readModernNoteTypes(from database: SQLiteDatabase) throws(AnkiError) -> [AnkiNoteType] {
        var fieldsByType: [Int64: [(ord: Int64, name: String)]] = [:]
        for row in try database.rows("SELECT ntid, ord, name FROM fields") {
            guard let ntid = row.int("ntid"), let ord = row.int("ord"), let name = row.text("name")
            else { continue }
            fieldsByType[ntid, default: []].append((ord, name))
        }
        return try database.rows("SELECT id, name FROM notetypes").compactMap { row in
            guard let id = row.int("id"), let name = row.text("name") else { return nil }
            let ordered = (fieldsByType[id] ?? []).sorted { $0.ord < $1.ord }.map(\.name)
            return AnkiNoteType(id: id, name: name, fieldNames: ordered)
        }
    }

    /// Schema 11: every note type is a value in the `col.models` JSON object.
    private func readLegacyNoteTypes(from database: SQLiteDatabase) throws(AnkiError) -> [AnkiNoteType] {
        // A collection with neither `notetypes` nor `col` describes no types; that is
        // an empty result, not an error, and the notes then simply map to nothing.
        guard try database.hasTable("col"),
              let json = try database.rows("SELECT models FROM col").first?.text("models"),
              let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
              let models = root as? [String: Any]
        else { return [] }

        let understood = models.values.compactMap { entry -> AnkiNoteType? in
            guard let model = entry as? [String: Any],
                  let name = model["name"] as? String,
                  let id = Self.int64(model["id"])
            else { return nil }
            return AnkiNoteType(id: id, name: name, fieldNames: Self.orderedFieldNames(of: model))
        }
        // A file that DESCRIBES note types and yields none is a parse failure, and it
        // must not be returned as the empty result above.
        //
        // The two look identical from outside and mean opposite things: a package with
        // 665 notes and 0 note types has nothing to map fields against, so the failure
        // surfaces at the far end as "this deck has no importable notes" - which points
        // at the deck's contents, and the contents are fine. That is what made the
        // stringified-id bug take a bespoke harness to find.
        //
        // The decision, stated once here: a TOTAL failure throws, a PARTIAL one does
        // not. Dropping some types stays tolerated because it is already visible - the
        // notes of a dropped type map to nothing and land in the caller's own
        // unmappable tally - and because refusing a whole deck over one junk entry
        // would be stricter than Anki, which reads these files.
        if understood.isEmpty, !models.isEmpty {
            throw AnkiError.unreadableNoteTypes(declared: models.count)
        }
        return understood.sorted { $0.id < $1.id }
    }

    /// A note type's field names in `ord` order.
    ///
    /// The fallback is the field's POSITION in the array, not zero. Defaulting an
    /// unreadable `ord` to 0 collapses every field onto the same sort key, and since
    /// fields are POSITIONAL in this format that does not drop anything - it scrambles
    /// the order, and every value in every note of that type is then read out of the
    /// wrong slot with nothing to report. Ties break on position for the same reason:
    /// `sorted` is not stable, so equal keys must not be left to reorder themselves.
    private static func orderedFieldNames(of model: [String: Any]) -> [String] {
        (model["flds"] as? [[String: Any]] ?? [])
            .enumerated()
            .sorted { left, right in
                let leftOrd = int64(left.element["ord"]) ?? Int64(left.offset)
                let rightOrd = int64(right.element["ord"]) ?? Int64(right.offset)
                if leftOrd != rightOrd { return leftOrd < rightOrd }
                return left.offset < right.offset
            }
            .compactMap { $0.element["name"] as? String }
    }

    /// A number out of decoded JSON, whether it was written as a number or as a string.
    ///
    /// Anki's own `col.models` / `col.decks` are hand-rolled JSON blobs, and the tools
    /// that write them do not agree on the type: genanki - which builds most generated
    /// and shared decks - writes note-type ids as STRINGS ("1607392319") while writing
    /// deck ids as numbers. Anki is lenient about it, which is why such a deck imports
    /// there and looked empty here.
    ///
    /// One helper used at every site rather than three separate rescues, so the next
    /// field read out of these blobs cannot be the one that was left strict.
    private static func int64(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let text = value as? String { return Int64(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    // MARK: Decks

    private func readDecks(from database: SQLiteDatabase) throws(AnkiError) -> [AnkiDeck] {
        // Which table to trust is decided by which EXISTS, never by whether it has
        // rows: a schema 18 collection with no decks still has no `col` to fall back
        // to, and treating "empty" as "look elsewhere" turns it into a hard failure.
        if try database.hasTable("decks") {
            return try database.rows("SELECT id, name FROM decks").compactMap { row in
                guard let id = row.int("id"), let name = row.text("name") else { return nil }
                return AnkiDeck(id: id, name: Self.normalizedDeckName(name))
            }
        }
        guard try database.hasTable("col"),
              let json = try database.rows("SELECT decks FROM col").first?.text("decks"),
              let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
              let decks = root as? [String: Any]
        else { return [] }
        // Lenient about the id's JSON type for the same reason as note types, even
        // though no writer seen in the wild stringifies a deck id today: it is the
        // same blob written by the same tools, and leaving one of the two strict is
        // leaving a bug that fires the day a writer changes its mind.
        //
        // A total failure here does NOT throw, unlike note types. Decks are used for
        // naming and source identity; a package whose decks all fail to parse still
        // imports every note under a fallback name, so refusing it would cost more
        // than it reports.
        return decks.values.compactMap { entry in
            guard let deck = entry as? [String: Any],
                  let name = deck["name"] as? String,
                  let id = Self.int64(deck["id"])
            else { return nil }
            return AnkiDeck(id: id, name: Self.normalizedDeckName(name))
        }
        .sorted { $0.id < $1.id }
    }

    /// Schema 18 separates nested deck names with US rather than `::`. Normalising
    /// here means a consumer sees one spelling of "Japanese::Core 2k" whichever
    /// schema the file used.
    private static func normalizedDeckName(_ name: String) -> String {
        name.replacingOccurrences(of: AnkiFields.separator, with: "::")
    }

    // MARK: Cards

    /// Deck membership lives on the `cards` table, the same in both schemas: a card
    /// points at its note (`nid`) and its deck (`did`). A note's decks are exactly the
    /// distinct decks ITS OWN cards sit in, so this maps note id to a sorted, deduped
    /// list rather than assigning every deck to every note.
    ///
    /// The table is read only when it EXISTS: an older or partial collection may carry
    /// notes with no `cards`, and those notes simply touch no deck rather than fail.
    private func readCardDecks(from database: SQLiteDatabase) throws(AnkiError) -> [Int64: [Int64]] {
        guard try database.hasTable("cards") else { return [:] }
        var decksByNote: [Int64: Set<Int64>] = [:]
        for row in try database.rows("SELECT nid, did FROM cards") {
            guard let nid = row.int("nid"), let did = row.int("did") else { continue }
            decksByNote[nid, default: []].insert(did)
        }
        return decksByNote.mapValues { $0.sorted() }
    }

    // MARK: Notes

    private func readNotes(
        from database: SQLiteDatabase,
        noteTypes: [AnkiNoteType],
        deckIDsByNote: [Int64: [Int64]]
    ) throws(AnkiError) -> [AnkiNote] {
        let declaredFields = Dictionary(uniqueKeysWithValues: noteTypes.map { ($0.id, $0.fieldNames.count) })
        let typeNames = Dictionary(uniqueKeysWithValues: noteTypes.map { ($0.id, $0.name) })

        var notes: [AnkiNote] = []
        for row in try database.rows("SELECT id, guid, mid, flds, tags FROM notes") {
            guard let id = row.int("id"), let guid = row.text("guid"), let mid = row.int("mid"),
                  let packed = row.text("flds")
            else { continue }
            let fields = AnkiFields.split(packed)
            // A note with MORE fields than its type declares means the two disagree
            // about the format, so every mapping past that point would be off by one.
            // Fewer is normal: a field added later leaves older notes short.
            if let declared = declaredFields[mid], fields.count > declared {
                throw AnkiError.fieldCountMismatch(
                    noteType: typeNames[mid] ?? String(mid), declared: declared, found: fields.count)
            }
            let tags = (row.text("tags") ?? "")
                .split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            notes.append(AnkiNote(
                guid: guid, noteTypeID: mid, fields: fields, tags: tags,
                deckIDs: deckIDsByNote[id] ?? []))
        }
        return notes
    }

    // MARK: Media

    /// List a package's media and open one file's bytes on demand.
    ///
    /// The returned ``AnkiMedia`` holds only the manifest (name to numbered entry) and
    /// a handle back to the package, not any media body: bodies are pulled one at a
    /// time by ``AnkiMedia/data(named:)``. The manifest is read in either of the two
    /// shapes Anki has shipped, the legacy JSON object and the current binary
    /// protobuf-wire form, without a protobuf dependency.
    public func readMedia(contentsOf url: URL) throws(AnkiError) -> AnkiMedia {
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw AnkiError.unreadableArchive(error.localizedDescription)
        }
        // A package with no `media` entry carries no media; that is an empty result,
        // not a failure. Anki itself writes an empty manifest rather than omitting it.
        guard let entry = archive["media"] else {
            return AnkiMedia(packageURL: url, entries: [])
        }
        var manifest = Data()
        do {
            _ = try archive.extract(entry) { manifest.append($0) }
        } catch {
            throw AnkiError.unreadableArchive(error.localizedDescription)
        }
        return AnkiMedia(packageURL: url, entries: try AnkiMediaManifest.parse(manifest))
    }
}
