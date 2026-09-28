import Testing
import Foundation
@testable import KBCore

@Suite("DocumentSource.FileKind codec (M8)")
struct DocumentSourceTests {

    @Test("the new .md FileKind has raw value \"md\"")
    func mdRawValue() {
        #expect(DocumentSource.FileKind(rawValue: "md") == .md)
        #expect(DocumentSource.FileKind.md.rawValue == "md")
    }

    @Test("existing FileKind raw values are unchanged")
    func existingRawValuesUnchanged() {
        #expect(DocumentSource.FileKind.txt.rawValue == "txt")
        #expect(DocumentSource.FileKind.epub.rawValue == "epub")
        #expect(DocumentSource.FileKind.pdf.rawValue == "pdf")
    }

    @Test(".md encodes to its raw string")
    func mdEncodesToString() throws {
        let data = try JSONEncoder().encode(DocumentSource.FileKind.md)
        #expect(String(data: data, encoding: .utf8) == "\"md\"")
    }

    @Test("DocumentSource.imported(.md) round-trips through Codable")
    func importedMdRoundTrips() throws {
        let source = DocumentSource.imported(.md)
        let data = try JSONEncoder().encode(source)
        let decoded = try JSONDecoder().decode(DocumentSource.self, from: data)
        #expect(decoded == source)
    }

    @Test("a pre-M8 DocumentSource JSON (frozen literal) still decodes")
    func oldJSONStillDecodes() throws {
        // FROZEN pre-M8 payloads — the exact synthesized shape captured before .md was
        // added (verified by encoding on a pre-M8 tree). Using literals, not the current
        // encoder, so this genuinely proves old persisted JSON still decodes.
        let txtJSON = Data(#"{"imported":{"_0":"txt"}}"#.utf8)
        let noteJSON = Data(#"{"userNote":{}}"#.utf8)
        #expect(try JSONDecoder().decode(DocumentSource.self, from: txtJSON) == .imported(.txt))
        #expect(try JSONDecoder().decode(DocumentSource.self, from: noteJSON) == .userNote)
    }
}

@Suite("DocumentSource.web codec (issue 055)")
struct DocumentSourceWebTests {

    @Test("a .web source round-trips its URL and retrieval date")
    func webRoundTrips() throws {
        let url = try #require(URL(string: "https://www3.nhk.or.jp/news/easy/k100.html"))
        // Whole seconds: JSON encodes a Date as a Double, so a sub-second fixture would
        // fail on float formatting rather than on the thing under test.
        let source = DocumentSource.web(url: url, retrievedAt: Date(timeIntervalSince1970: 1_757_000_000))
        let decoded = try JSONDecoder().decode(
            DocumentSource.self, from: JSONEncoder().encode(source))
        #expect(decoded == source)
        #expect(decoded.webURL == url)
    }

    @Test("a .web source is not a user note, so it files as an imported document")
    func webIsNotANote() throws {
        let url = try #require(URL(string: "https://example.com/a"))
        #expect(DocumentSource.web(url: url, retrievedAt: .now).isUserNote == false)
    }

    @Test("webURL is nil for the sources that have no page")
    func webURLIsNilOtherwise() {
        #expect(DocumentSource.imported(.epub).webURL == nil)
        #expect(DocumentSource.userNote.webURL == nil)
    }

    @Test("adding .web did not disturb the frozen pre-055 encodings")
    func priorEncodingsUnchanged() throws {
        let txtJSON = Data(#"{"imported":{"_0":"txt"}}"#.utf8)
        let noteJSON = Data(#"{"userNote":{}}"#.utf8)
        #expect(try JSONDecoder().decode(DocumentSource.self, from: txtJSON) == .imported(.txt))
        #expect(try JSONDecoder().decode(DocumentSource.self, from: noteJSON) == .userNote)
    }
}
