public import Foundation
import ZIPFoundation

/// Writes an ``AnkiDeckDraft`` out as an `.apkg` that Anki can import.
///
/// Exported cards are NEW. This package writes no review history and no intervals:
/// an app may schedule with FSRS and Anki with its own scheduler, and the two do
/// not share a memory model, so any number written here would be a guess dressed as
/// data. A deck arrives in Anki ready to be learned, which is honest and reversible.
public struct AnkiPackageWriter: Sendable {
    public init() {}

    /// Write `draft` to `url`, replacing anything already there.
    ///
    /// - Parameters:
    ///   - timestamp: the clock the collection's ids are derived from. Injectable so
    ///     a test can assert the same draft always writes the same bytes.
    public func write(
        _ draft: AnkiDeckDraft,
        to url: URL,
        timestamp: Date = Date()
    ) throws(AnkiError) {
        try validate(draft)
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("KBAnkiKit-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let databaseURL = staging.appendingPathComponent("collection.anki2")
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            throw AnkiError.writeFailure(error.localizedDescription)
        }
        // Scoped so the database is closed, and its buffers flushed, before the file
        // is read back into the archive below.
        try buildCollection(draft, at: databaseURL, timestamp: timestamp)
        try archive(databaseURL: databaseURL, to: url, timestamp: timestamp)
    }

    private func validate(_ draft: AnkiDeckDraft) throws(AnkiError) {
        guard !draft.notes.isEmpty else { throw AnkiError.emptyDeck }
        let declared = draft.noteType.fieldNames.count
        for note in draft.notes where note.fields.count != declared {
            throw AnkiError.fieldCountMismatch(
                noteType: draft.noteType.name, declared: declared, found: note.fields.count)
        }
    }

    // MARK: Collection

    private func buildCollection(
        _ draft: AnkiDeckDraft,
        at databaseURL: URL,
        timestamp: Date
    ) throws(AnkiError) {
        let database = try SQLiteDatabase(path: databaseURL.path, access: .createOrOpen)
        try database.execute(AnkiCollectionSchema.ddl)

        // Ids in an Anki collection are epoch milliseconds that double as unique
        // keys, so they are allocated from one counter rather than computed. Two
        // rows sharing an id is a corrupt collection Anki reports much later.
        var nextID = Int64(timestamp.timeIntervalSince1970 * 1000)
        func allocate() -> Int64 {
            defer { nextID += 1 }
            return nextID
        }
        let modelID = allocate()
        let deckID = allocate()

        try insertCollectionRow(
            into: database, draft: draft, modelID: modelID, deckID: deckID, timestamp: timestamp)

        let modified = Int64(timestamp.timeIntervalSince1970)
        // Two notes with byte-identical fields would otherwise derive the same guid
        // and merge in the receiving collection, so a repeat gets a salt.
        var guidUses: [String: Int] = [:]
        for (position, note) in draft.notes.enumerated() {
            let noteID = allocate()
            let first = note.fields.first ?? ""
            try database.run(
                "INSERT INTO notes VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                [
                    .integer(noteID),
                    .text(note.guid ?? Self.guid(for: note, uses: &guidUses)),
                    .integer(modelID),
                    .integer(modified),
                    .integer(-1),
                    // Anki stores tags space-separated AND space-padded, so a search
                    // for " tag " matches whole tags rather than prefixes.
                    .text(note.tags.isEmpty ? "" : " \(note.tags.joined(separator: " ")) "),
                    .text(AnkiFields.join(note.fields)),
                    .text(AnkiFields.strippingHTML(first)),
                    .integer(AnkiFields.checksum(ofFirstField: first)),
                    .integer(0),
                    .text("")
                ])

            for ordinal in draft.noteType.templates.indices {
                try database.run(
                    "INSERT INTO cards VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                    [
                        .integer(allocate()), .integer(noteID), .integer(deckID),
                        .integer(Int64(ordinal)), .integer(modified), .integer(-1),
                        // type 0 / queue 0 is "new"; due is its position in the new
                        // queue. Everything after is the scheduling state we do not write.
                        .integer(0), .integer(0), .integer(Int64(position)),
                        .integer(0), .integer(0), .integer(0), .integer(0),
                        .integer(0), .integer(0), .integer(0), .integer(0), .text("")
                    ])
            }
        }
    }

    /// The guid for a note without one: derived from its content, salted only when an
    /// identical note has already been written in this deck.
    private static func guid(for note: AnkiNoteDraft, uses: inout [String: Int]) -> String {
        let key = AnkiFields.join(note.fields)
        let salt = uses[key] ?? 0
        uses[key] = salt + 1
        return AnkiFields.contentGUID(fields: note.fields, salt: salt)
    }

    private func insertCollectionRow(
        into database: SQLiteDatabase,
        draft: AnkiDeckDraft,
        modelID: Int64,
        deckID: Int64,
        timestamp: Date
    ) throws(AnkiError) {
        let millis = Int64(timestamp.timeIntervalSince1970 * 1000)
        // `crt` is the collection's day-zero in seconds, and Anki counts elapsed days
        // from it, so it must land on a day boundary rather than on "now".
        //
        // Anki itself uses the most recent LOCAL 04:00 rollover. This uses UTC
        // midnight deliberately: importing an .apkg merges its notes into the
        // destination collection, which counts days from ITS OWN crt, so this value
        // never reaches a scheduler. Following Anki exactly would make an export's
        // bytes depend on the exporting machine's time zone, trading reproducibility
        // for a number nothing reads. Revisit if this package ever writes a
        // standalone collection rather than an import payload.
        let created = Int64(timestamp.timeIntervalSince1970) / 86_400 * 86_400
        try database.run(
            "INSERT INTO col VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
            [
                .integer(1), .integer(created), .integer(millis), .integer(millis),
                .integer(Int64(AnkiCollectionSchema.version)), .integer(0),
                .integer(0), .integer(0),
                .text(AnkiCollectionSchema.configJSON(
                    modelID: modelID, deckID: deckID, noteCount: draft.notes.count)),
                .text(AnkiCollectionSchema.modelsJSON(draft.noteType, id: modelID, deckID: deckID)),
                .text(AnkiCollectionSchema.decksJSON(name: draft.deckName, id: deckID)),
                .text(AnkiCollectionSchema.deckConfigJSON),
                .text("{}")
            ])
    }

    // MARK: Archive

    /// `timestamp` reaches the ZIP entries, not just the collection rows.
    ///
    /// Both entries otherwise take their modification date from the wall clock: the manifest
    /// through `addEntry`'s `Date()` default, and the collection from the temp file's own mtime.
    /// ZIP stores dates at two-second resolution, so two writes usually matched and differed
    /// only when they straddled a boundary. That made `writesAreReproducible` a test that
    /// passed on timing rather than on the property, and it duly failed under load.
    private func archive(databaseURL: URL, to url: URL, timestamp: Date) throws(AnkiError) {
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            let archive = try Archive(url: url, accessMode: .create)
            // The fileURL overload takes no date, so stamp the file itself first.
            try FileManager.default.setAttributes([.modificationDate: timestamp],
                                                  ofItemAtPath: databaseURL.path)
            try archive.addEntry(
                with: "collection.anki2", fileURL: databaseURL, compressionMethod: .deflate)
            // The media manifest is required even with no media: Anki reads it first
            // and treats its absence as a malformed package.
            let manifest = Data("{}".utf8)
            try archive.addEntry(
                with: "media", type: .file, uncompressedSize: Int64(manifest.count),
                modificationDate: timestamp, compressionMethod: .deflate,
                provider: { position, size in
                    manifest.subdata(in: Int(position)..<Int(position) + size)
                })
        } catch {
            throw AnkiError.writeFailure(error.localizedDescription)
        }
    }
}
