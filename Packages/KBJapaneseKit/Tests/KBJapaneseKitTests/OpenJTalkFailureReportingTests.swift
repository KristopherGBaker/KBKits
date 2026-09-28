#if canImport(Darwin)
import Foundation
import KBCore
import Testing
@testable import KBJapaneseKit

extension OpenJTalkDictionaryTests {

    /// Cancellation, and errors a person can read.
    @Suite("cancellation and structured, describable errors")
    struct FailureReportingTests {

        @Test("a fetch that throws CancellationError surfaces it unchanged")
        func cancellationSurfacesUnchanged() async throws {
            let base = try openJTalkTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: base) }
            let recorder = OpenJTalkFetchRecorder()
            recorder.failure = CancellationError()
            let store = makeOpenJTalkStore(base: base, recorder: recorder)

            await #expect(throws: CancellationError.self) { try await store.ensureAvailable() }
            #expect(try FileManager.default.contentsOfDirectory(atPath: base.path).isEmpty)
        }

        /// URLSession reports a cancelled transfer as `URLError.cancelled`, not as
        /// `CancellationError`, so both doors have to lead to the same place.
        @Test("a URLSession cancellation surfaces as CancellationError")
        func urlSessionCancellationSurfacesAsCancellation() async throws {
            let base = try openJTalkTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: base) }
            let recorder = OpenJTalkFetchRecorder()
            recorder.failure = URLError(.cancelled)
            let store = makeOpenJTalkStore(base: base, recorder: recorder)

            await #expect(throws: CancellationError.self) { try await store.ensureAvailable() }
        }

        @Test("cancelling the task that is downloading surfaces CancellationError")
        func realTaskCancellationSurfacesCancellationError() async throws {
            let base = try openJTalkTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: base) }
            let recorder = OpenJTalkFetchRecorder()
            recorder.waitsForever = true
            let store = makeOpenJTalkStore(base: base, recorder: recorder)

            let task = Task { try await store.ensureAvailable() }
            // Wait until the fetch has actually started, so the cancellation lands mid-download
            // rather than before `ensureAvailable` reaches it.
            while recorder.calls.isEmpty { await Task.yield() }
            task.cancel()

            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(try FileManager.default.contentsOfDirectory(atPath: base.path).isEmpty)
        }

        @Test("a cancelled ensureAvailable never reaches the network")
        func alreadyCancelledTaskDoesNotFetch() async throws {
            let base = try openJTalkTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: base) }
            let recorder = OpenJTalkFetchRecorder()
            recorder.archive = try openJTalkArchive(
                containing: OpenJTalkDictionary.requiredFiles)
            let store = makeOpenJTalkStore(base: base, recorder: recorder)

            let task = Task {
                // Cancelled before the body runs, which is what a user tapping Cancel during
                // app launch produces.
                try await Task.sleep(for: .seconds(60))
                return try await store.ensureAvailable()
            }
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(recorder.calls.isEmpty)
        }

        @Test("a digest mismatch keeps its structure instead of becoming a sentence")
        func digestMismatchKeepsItsStructure() async throws {
            let base = try openJTalkTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: base) }
            let expected = String(repeating: "a", count: 64)
            let actual = String(repeating: "b", count: 64)
            let recorder = OpenJTalkFetchRecorder()
            recorder.failure = FileDownloader.DownloadError.digestMismatch(
                expected: expected, actual: actual, url: "https://example.invalid/d.tar.gz")
            let store = makeOpenJTalkStore(base: base, recorder: recorder)

            do {
                _ = try await store.ensureAvailable()
                Issue.record("expected a download failure")
            } catch let error as OpenJTalkDictionary.StoreError {
                #expect(error == .downloadFailed(
                    .digestMismatch(expected: expected, actual: actual)))
                let message = try #require(error.errorDescription)
                #expect(message.contains(expected))
                #expect(message.contains(actual))
            }
        }

        @Test("every StoreError case has a non-empty errorDescription", arguments: [
            OpenJTalkDictionary.StoreError
                .downloadFailed(.digestMismatch(expected: "a", actual: "b")),
            .downloadFailed(.http(status: 503)),
            .downloadFailed(.badURL("nope")),
            .downloadFailed(.other("the network went away")),
            .extractFailed(.incompleteDictionary(missing: ["unk.dic"])),
            .extractFailed(.unreadableArchive("not gzip")),
            .extractFailed(.installFailed("no space")),
            .unsupportedPlatform("no download path here"),
            .applicationSupportUnavailable("no Application Support")
        ])
        func everyErrorDescribesItself(error: OpenJTalkDictionary.StoreError) throws {
            let message = try #require(error.errorDescription, "\(error) has no errorDescription")
            #expect(!message.isEmpty)
            // `LocalizedError` is what a consumer reads, and `localizedDescription` must route
            // to it rather than to the type name Swift makes up for a bare `Error`.
            #expect(error.localizedDescription == message)
        }

        @Test("an unavailable Application Support surfaces an error, never the temp directory")
        func applicationSupportUnavailableThrows() throws {
            #expect(throws: OpenJTalkDictionary.StoreError.applicationSupportUnavailable(
                "Application Support is unavailable, so MyApp/openjtalk cannot be created")) {
                try OpenJTalkDictionary.resolveBaseDirectory(
                    subdirectory: "MyApp/openjtalk", applicationSupport: nil)
            }
            // And the available branch is the app's own folder under Application Support, with
            // no temp directory anywhere in it.
            let support = URL(fileURLWithPath: "/somewhere/Library/Application Support")
            let resolved = try OpenJTalkDictionary.resolveBaseDirectory(
                subdirectory: "MyApp/openjtalk", applicationSupport: support)
            #expect(resolved.path == "/somewhere/Library/Application Support/MyApp/openjtalk")
            #expect(!resolved.path.hasPrefix(URL.temporaryDirectory.path))
        }
    }
}
#endif
