#if canImport(Darwin)
import Foundation
import Testing
@testable import KBJapaneseKit

extension OpenJTalkDictionaryTests {

    /// The pinned artifact, and what the cheap presence check accepts.
    @Suite("the pin, and what counts as installed")
    struct InstalledStateTests {

        @Test("an uncached ensureAvailable fetches the pinned URL with the pinned digest")
        func pinReachesFetch() async throws {
            let base = try openJTalkTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: base) }
            let recorder = OpenJTalkFetchRecorder()
            // No archive bytes: extraction will fail AFTER the fetch, which is fine -
            // what this test is about is what the fetch was ASKED for, recorded at
            // call time, on the uncached branch.
            let store = makeOpenJTalkStore(base: base, recorder: recorder)

            // The base dir is empty, so there is no cached dictionary to short-circuit on.
            #expect(await store.existingDictionaryDirectory == nil)
            _ = try? await store.ensureAvailable()

            let calls = recorder.calls
            #expect(calls.count == 1)
            let call = try #require(calls.first)
            #expect(call.url ==
                    "https://github.com/r9y9/open_jtalk/releases/download/v1.11.1/open_jtalk_dic_utf_8-1.11.tar.gz")
            // The load-bearing half: a `sha256: nil` fetch fails right here.
            #expect(call.sha256 == OpenJTalkDictionary.archiveSHA256)
            #expect(call.sha256 ==
                    "fe6ba0e43542cef98339abdffd903e062008ea170b04e7e2a35da805902f382a")
        }

        /// Every state a half-finished extraction can leave behind. `sys.dic` is the FIRST entry
        /// in the tarball, so "sys.dic exists" is true of nearly every interrupted download, and
        /// it was the whole presence check: the dictionary then counted as installed forever and
        /// the frontend failed to load it on every launch.
        @Test("a partially extracted dictionary is not installed", arguments: [
            (files: [], marked: true),
            (files: ["sys.dic"], marked: false),
            (files: ["sys.dic"], marked: true),
            (files: ["sys.dic", "matrix.bin"], marked: true),
            (files: ["sys.dic", "matrix.bin", "char.bin"], marked: true),
            (files: ["matrix.bin", "char.bin", "unk.dic"], marked: true),
            (files: OpenJTalkDictionary.requiredFiles, marked: false)
        ])
        func partialExtractionIsNotInstalled(state: (files: [String], marked: Bool)) async throws {
            let base = try openJTalkTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: base) }
            let directory = try plantOpenJTalkDictionary(
                in: base, files: state.files, marked: state.marked)

            #expect(!OpenJTalkDictionary.isInstalled(at: directory))
            let store = makeOpenJTalkStore(base: base, recorder: OpenJTalkFetchRecorder())
            #expect(await store.existingDictionaryDirectory == nil)
        }

        @Test("all four files plus the marker is installed, and nothing less is")
        func completeExtractionIsInstalled() async throws {
            let base = try openJTalkTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: base) }
            let directory = try plantCompleteOpenJTalkDictionary(in: base)
            #expect(OpenJTalkDictionary.isInstalled(at: directory))
            let store = makeOpenJTalkStore(base: base, recorder: OpenJTalkFetchRecorder())
            #expect(await store.existingDictionaryDirectory == directory)

            // Remove any ONE of the four and it stops being installed.
            for name in OpenJTalkDictionary.requiredFiles {
                let file = directory.appendingPathComponent(name)
                let saved = try Data(contentsOf: file)
                try FileManager.default.removeItem(at: file)
                #expect(!OpenJTalkDictionary.isInstalled(at: directory), "removing \(name)")
                try saved.write(to: file)
            }
            #expect(OpenJTalkDictionary.isInstalled(at: directory))

            // Remove the MARKER and the four files are not enough either: an older build that
            // moved a complete extraction in without one does not get to answer yes.
            let marker = directory.appendingPathComponent(OpenJTalkDictionary.completionMarker)
            try FileManager.default.removeItem(at: marker)
            #expect(!OpenJTalkDictionary.isInstalled(at: directory))
            #expect(await store.existingDictionaryDirectory == nil)
        }

        @Test("a partial cache is re-downloaded rather than trusted")
        func partialCacheIsRedownloaded() async throws {
            let base = try openJTalkTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: base) }
            try plantOpenJTalkDictionary(in: base, files: ["sys.dic"], marked: false)
            let recorder = OpenJTalkFetchRecorder()
            recorder.archive = try openJTalkArchive(
                containing: OpenJTalkDictionary.requiredFiles)

            let directory = try await makeOpenJTalkStore(base: base, recorder: recorder)
                .ensureAvailable()

            #expect(recorder.calls.count == 1)
            #expect(OpenJTalkDictionary.isInstalled(at: directory))
        }

        @Test("ensureAvailable returns the cached directory with zero fetches")
        func cachedDictionaryBypassesTheNetwork() async throws {
            let base = try openJTalkTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: base) }
            let installed = try plantCompleteOpenJTalkDictionary(in: base)

            let recorder = OpenJTalkFetchRecorder()
            let directory = try await makeOpenJTalkStore(base: base, recorder: recorder)
                .ensureAvailable()

            #expect(directory == installed)
            #expect(recorder.calls.isEmpty)
        }
    }
}
#endif
