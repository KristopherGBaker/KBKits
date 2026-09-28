// The download-stage-extract-install path exists only on Apple platforms (SWCompression does
// not cross-compile for Android; see the note at the top of `OpenJTalkDictionary`), and these
// tests BUILD a real tar.gz so the production path runs rather than a lookalike. So unlike the
// suites that merely need data, these files cannot skip where the dependency is absent: they
// would not compile.
#if canImport(Darwin)
import Foundation
import SWCompression
import Testing
@testable import KBJapaneseKit

/// The Open JTalk dictionary store: what it fetches, what counts as installed, and what it
/// leaves behind when the extraction does not finish.
///
/// `.serialized` is load-bearing, and it is on this OUTER suite so it covers every nested one.
/// `ensureAvailable` points the PROCESS-GLOBAL analyser configuration at whatever it installed,
/// so two of these running at once would each be asserting about a global the other is writing;
/// `.serialized` is recursive, so one suite here means one at a time across all four groups.
/// The groups are nested (in extensions, a file each) only to keep each body and file inside the
/// house length limits while staying ONE serialized suite. Suites outside this one take
/// `openJTalkConfigurationGate` for the same reason.
@Suite("OpenJTalkDictionary: pinned fetch, atomic install, honest failures", .serialized)
struct OpenJTalkDictionaryTests {}

/// What the store hands its fetcher, recorded per call.
final class OpenJTalkFetchRecorder: @unchecked Sendable {
    /// One recorded fetch. A named struct rather than a 3-tuple, which trips the house
    /// `large_tuple` limit; every call site already reads these by name.
    struct Call {
        let url: String
        let destination: URL
        let sha256: String?
    }

    private let lock = NSLock()
    private(set) var calls: [Call] = []
    /// Bytes to write at the destination so the caller's unpack step can proceed.
    var archive: Data?
    /// Thrown instead of writing, so the failure paths (cancellation, a digest mismatch, a
    /// dead network) run through the real `ensureAvailable`.
    var failure: (any Error)?
    /// Awaited before throwing, so a REAL task cancellation can be observed rather than
    /// simulated by throwing `CancellationError` directly.
    var waitsForever = false

    var fetch: OpenJTalkDictionary.Fetch {
        { url, destination, sha256, _ in
            self.lock.withLock {
                self.calls.append(Call(url: url, destination: destination, sha256: sha256))
            }
            if self.waitsForever {
                try await Task.sleep(for: .seconds(60))
            }
            if let failure = self.failure { throw failure }
            if let archive = self.archive { try archive.write(to: destination) }
        }
    }
}

let openJTalkDictionaryName = "open_jtalk_dic_utf_8-1.11"

func openJTalkTemporaryDirectory() throws -> URL {
    let directory = URL.temporaryDirectory
        .appendingPathComponent("ojt-pin-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

/// A `.tar.gz` holding `files` under a top-level `open_jtalk_dic_utf_8-1.11/` folder, which is
/// the shape the real r9y9 release has. Naming the files individually is what lets a test
/// deliver a deliberately INCOMPLETE dictionary.
func openJTalkArchive(containing files: [String]) throws -> Data {
    let entries = files.map { name in
        TarEntry(info: TarEntryInfo(name: "\(openJTalkDictionaryName)/\(name)", type: .regular),
                 data: Data("\(name) contents".utf8))
    }
    return try GzipArchive.archive(data: TarContainer.create(from: entries))
}

/// Plant a dictionary directory by hand: `files` present, plus the completion marker when
/// `marked`. Used to describe the states a half-finished extraction can leave behind.
@discardableResult
func plantOpenJTalkDictionary(in base: URL, files: [String], marked: Bool) throws -> URL {
    let directory = base.appendingPathComponent(openJTalkDictionaryName, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for name in files {
        try Data("\(name) contents".utf8).write(to: directory.appendingPathComponent(name))
    }
    if marked {
        try Data().write(
            to: directory.appendingPathComponent(OpenJTalkDictionary.completionMarker))
    }
    return directory
}

/// A complete, installed dictionary planted by hand: all four files plus the marker.
func plantCompleteOpenJTalkDictionary(in base: URL) throws -> URL {
    try plantOpenJTalkDictionary(in: base, files: OpenJTalkDictionary.requiredFiles, marked: true)
}

func makeOpenJTalkStore(base: URL, recorder: OpenJTalkFetchRecorder) -> OpenJTalkDictionary {
    OpenJTalkDictionary(applicationSupportSubdirectory: "test/openjtalk",
                        baseDirectoryOverride: base, fetch: recorder.fetch)
}
#endif
