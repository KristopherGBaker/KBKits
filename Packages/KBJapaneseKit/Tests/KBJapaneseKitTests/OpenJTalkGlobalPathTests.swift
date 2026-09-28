#if canImport(Darwin)
import Foundation
import MisakiJapanese
import Synchronization
import Testing
@testable import KBJapaneseKit

extension OpenJTalkDictionaryTests {

    /// The one lock over MisakiSwift's process-global dictionary path.
    @Suite("the process-global dictionary path")
    struct GlobalDictionaryPathTests {

        /// Concurrent readers and writers of MisakiSwift's `nonisolated(unsafe)`
        /// `JapaneseG2PConfiguration.dictionaryDirectory`, all of them through Kits' one lock.
        ///
        /// Without the lock this is an unsynchronized read of a `URL?` while another thread
        /// writes it, and the value the reader then hands to the C frontend is whatever it
        /// caught mid assignment. With it, every read returns a directory some writer set.
        @Test("concurrent readers see a directory some writer set, never a torn one")
        func concurrentAccessIsSerialized() throws {
            let base = try openJTalkTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: base) }
            let candidates = try (0 ..< 8).map { index -> URL in
                let directory = base.appendingPathComponent("dict-\(index)", isDirectory: true)
                try FileManager.default.createDirectory(at: directory,
                                                        withIntermediateDirectories: true)
                return directory
            }

            // The gate, not `.serialized`: the suites outside this one that write the same
            // global take it too, which is the only way an assertion about a process-wide
            // variable is stable under a parallel test run.
            let observations = openJTalkConfigurationGate.withLock { _ -> [URL?] in
                let previous = JapaneseTextAnalysis.configuredDictionaryDirectory
                defer { JapaneseG2PConfiguration.dictionaryDirectory = previous }
                JapaneseTextAnalysis.useDictionary(at: candidates[0])

                let seen = Mutex<[URL?]>([])
                // Real threads rather than a task group: contention is the point, and
                // `concurrentPerform` gives it without a suspension the actor could serialize
                // for free.
                DispatchQueue.concurrentPerform(iterations: 128) { iteration in
                    let candidate = candidates[iteration % candidates.count]
                    switch iteration % 4 {
                    case 0:
                        JapaneseTextAnalysis.useDictionary(at: candidate)
                    case 1:
                        // The production read path: this hands a path to the C frontend.
                        _ = JapaneseReader()
                        seen.withLock {
                            $0.append(JapaneseTextAnalysis.configuredDictionaryDirectory)
                        }
                    case 2:
                        _ = JapaneseTextAnalysis.isDictionaryConfigured
                        seen.withLock {
                            $0.append(JapaneseTextAnalysis.configuredDictionaryDirectory)
                        }
                    default:
                        seen.withLock {
                            $0.append(JapaneseTextAnalysis.configuredDictionaryDirectory)
                        }
                    }
                }
                return seen.withLock { $0 }
            }

            #expect(!observations.isEmpty)
            // Every observation is one of the directories written here: never nil (one was set
            // before the burst), never a URL no one assigned.
            for observed in observations {
                let directory = try #require(observed, "a read observed no dictionary at all")
                #expect(candidates.contains(directory),
                        "observed an unwritten directory: \(directory)")
            }
        }

        @Test("pointing the analysis at the directory it already uses writes nothing new")
        func useDictionaryIsIdempotentPerDirectory() throws {
            let base = try openJTalkTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: base) }
            openJTalkConfigurationGate.withLock { _ in
                let previous = JapaneseTextAnalysis.configuredDictionaryDirectory
                defer { JapaneseG2PConfiguration.dictionaryDirectory = previous }

                #expect(!JapaneseTextAnalysis.isDictionaryConfigured || previous != nil)
                JapaneseTextAnalysis.useDictionary(at: base)
                #expect(JapaneseTextAnalysis.configuredDictionaryDirectory == base)
                #expect(JapaneseTextAnalysis.isDictionaryConfigured)
                JapaneseTextAnalysis.useDictionary(at: base)
                #expect(JapaneseTextAnalysis.configuredDictionaryDirectory == base)
            }
        }

        @Test("a successful install points the analysis at what it installed")
        func installPointsTheAnalysisAtTheDictionary() async throws {
            let base = try openJTalkTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: base) }
            let recorder = OpenJTalkFetchRecorder()
            recorder.archive = try openJTalkArchive(
                containing: OpenJTalkDictionary.requiredFiles)
            let previous = JapaneseTextAnalysis.configuredDictionaryDirectory
            defer { JapaneseG2PConfiguration.dictionaryDirectory = previous }

            let directory = try await makeOpenJTalkStore(base: base, recorder: recorder)
                .ensureAvailable()
            // The read takes the gate. A `Mutex` cannot be held across the `await` above, but it
            // does not have to be: the other suites that write this global hold the gate for
            // their whole region, and the suites that write it through `ensureAvailable` are
            // this one's siblings under a `.serialized` parent, so nothing else is mid-swap.
            let configured = openJTalkConfigurationGate.withLock { _ in
                JapaneseTextAnalysis.configuredDictionaryDirectory
            }
            #expect(configured == directory)
        }
    }
}
#endif
