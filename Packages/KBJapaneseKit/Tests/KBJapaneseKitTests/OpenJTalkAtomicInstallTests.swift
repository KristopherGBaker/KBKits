#if canImport(Darwin)
import Foundation
import KBCore
import Testing
@testable import KBJapaneseKit

extension OpenJTalkDictionaryTests {

    /// Staging, the single-rename install, and what is left on disk when it fails.
    @Suite("staging and the atomic install")
    struct AtomicInstallTests {

        @Test("a complete archive installs, marks, and leaves no staging directory")
        func completeArchiveInstallsAtomically() async throws {
            let base = try openJTalkTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: base) }
            let recorder = OpenJTalkFetchRecorder()
            recorder.archive = try openJTalkArchive(
                containing: OpenJTalkDictionary.requiredFiles)

            let directory = try await makeOpenJTalkStore(base: base, recorder: recorder)
                .ensureAvailable()

            #expect(directory
                    == base.appendingPathComponent(openJTalkDictionaryName, isDirectory: true))
            #expect(OpenJTalkDictionary.isInstalled(at: directory))
            // The base holds the dictionary and nothing else: no staging directory, no tarball,
            // no intermediate `.tar`.
            #expect(try FileManager.default.contentsOfDirectory(atPath: base.path)
                    == [openJTalkDictionaryName])
            // The installed directory holds the four files and the marker, and nothing from the
            // staging step.
            let installed = try FileManager.default
                .contentsOfDirectory(atPath: directory.path).sorted()
            #expect(installed == ([OpenJTalkDictionary.completionMarker]
                                  + OpenJTalkDictionary.requiredFiles).sorted())
        }

        @Test("an archive missing one of the four installs nothing and names what was missing")
        func incompleteArchiveInstallsNothing() async throws {
            let base = try openJTalkTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: base) }
            let recorder = OpenJTalkFetchRecorder()
            recorder.archive = try openJTalkArchive(containing: ["sys.dic", "matrix.bin"])
            let store = makeOpenJTalkStore(base: base, recorder: recorder)

            await #expect(throws: OpenJTalkDictionary.StoreError.extractFailed(
                .incompleteDictionary(missing: ["char.bin", "unk.dic"]))) {
                try await store.ensureAvailable()
            }
            // Nothing was published: no dictionary directory at all, and no staging leftovers.
            #expect(try FileManager.default.contentsOfDirectory(atPath: base.path).isEmpty)
            #expect(await store.existingDictionaryDirectory == nil)
        }

        @Test("a retry after a failed extraction succeeds")
        func retryAfterAFailedExtractionSucceeds() async throws {
            let base = try openJTalkTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: base) }
            let recorder = OpenJTalkFetchRecorder()
            recorder.archive = try openJTalkArchive(containing: ["sys.dic"])
            let store = makeOpenJTalkStore(base: base, recorder: recorder)

            await #expect(throws: (any Error).self) { try await store.ensureAvailable() }
            #expect(await store.existingDictionaryDirectory == nil)

            // The upstream artifact is fine on the second attempt. The first attempt must not
            // have left anything behind that poisons it.
            recorder.archive = try openJTalkArchive(
                containing: OpenJTalkDictionary.requiredFiles)
            let directory = try await store.ensureAvailable()
            #expect(OpenJTalkDictionary.isInstalled(at: directory))
            #expect(recorder.calls.count == 2)
            #expect(try FileManager.default.contentsOfDirectory(atPath: base.path)
                    == [openJTalkDictionaryName])
        }

        @Test("a stale staging directory is cleaned rather than reused")
        func staleStagingDirectoryIsCleaned() async throws {
            let base = try openJTalkTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: base) }
            // What a killed process leaves: a staging directory holding half an extraction,
            // marker and all, from a build that wrote the marker in the wrong order.
            let staging = base.appendingPathComponent("\(openJTalkDictionaryName).staging",
                                                      isDirectory: true)
            let stale = staging.appendingPathComponent(openJTalkDictionaryName, isDirectory: true)
            try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
            for name in OpenJTalkDictionary.requiredFiles {
                try Data("stale \(name)".utf8).write(to: stale.appendingPathComponent(name))
            }
            try Data().write(to: stale.appendingPathComponent("junk-from-the-last-run"))

            let recorder = OpenJTalkFetchRecorder()
            recorder.archive = try openJTalkArchive(
                containing: OpenJTalkDictionary.requiredFiles)
            let directory = try await makeOpenJTalkStore(base: base, recorder: recorder)
                .ensureAvailable()

            #expect(OpenJTalkDictionary.isInstalled(at: directory))
            #expect(!FileManager.default.fileExists(atPath: staging.path))
            // The stale bytes were not reused: this run's archive wrote the contents, and the
            // previous run's junk file is nowhere in the installed dictionary.
            #expect(try Data(contentsOf: directory.appendingPathComponent("sys.dic"))
                    == Data("sys.dic contents".utf8))
            #expect(!FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("junk-from-the-last-run").path))
        }

        @Test("a failed fetch leaves no staging directory behind")
        func failedFetchLeavesNoStaging() async throws {
            let base = try openJTalkTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: base) }
            let recorder = OpenJTalkFetchRecorder()
            recorder.failure = FileDownloader.DownloadError.http(
                503, "https://example.invalid/d.tar.gz")
            let store = makeOpenJTalkStore(base: base, recorder: recorder)

            await #expect(throws: OpenJTalkDictionary.StoreError
                .downloadFailed(.http(status: 503))) {
                try await store.ensureAvailable()
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: base.path).isEmpty)
        }

        /// An install already in place must survive a failed re-install. The staged directory is
        /// swapped in whole, so there is no window in which the old one is gone and the new one
        /// is not there yet.
        @Test("a failed re-extraction leaves an existing install untouched")
        func failedReextractionKeepsTheExistingInstall() async throws {
            let base = try openJTalkTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: base) }
            let installed = try plantCompleteOpenJTalkDictionary(in: base)
            let sentinel = Data("the previously installed sys.dic".utf8)
            try sentinel.write(to: installed.appendingPathComponent("sys.dic"))

            let recorder = OpenJTalkFetchRecorder()
            recorder.archive = try openJTalkArchive(containing: ["sys.dic"])
            // A store pointed at the same base, but told the cache is stale by removing the
            // marker: it will re-download, and the archive it gets is incomplete.
            try FileManager.default.removeItem(
                at: installed.appendingPathComponent(OpenJTalkDictionary.completionMarker))
            let store = makeOpenJTalkStore(base: base, recorder: recorder)

            await #expect(throws: (any Error).self) { try await store.ensureAvailable() }
            #expect(try Data(contentsOf: installed.appendingPathComponent("sys.dic")) == sentinel)
            #expect(!FileManager.default.fileExists(
                atPath: base.appendingPathComponent("\(openJTalkDictionaryName).staging").path))
        }
    }
}
#endif
