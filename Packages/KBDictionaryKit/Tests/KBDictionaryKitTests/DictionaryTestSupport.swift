import Foundation
@testable import KBDictionaryKit

/// Whether this platform can actually open the bundled SQLite seed.
///
/// True everywhere GRDB builds, which today is every Apple platform. False on Android,
/// where `JMDictStore` falls back to `EmptyJMDictStorage` because SQLite is unreachable
/// from the NDK. Suites that assert against real dictionary DATA carry
/// `.enabled(if: seedIsAvailable)` so they SKIP there and stay visible in the run, rather
/// than being compiled out with `#if` and quietly disappearing.
///
/// Everything that tests policy rather than data drives `JMDictStore` with a fake storage
/// instead (see `JMDictStorageSeamTests`) and needs no gate at all.
enum DictionaryTestSupport {
    static let seedIsAvailable = JMDictStore(databaseURL: JMDictStore.bundledSeedURL).isReady

    /// A FULL JMdict, when `KB_FULL_JMDICT` names one (`Tools/build-jmdict.swift` prints the
    /// path it writes). Nil on CI, on a fresh clone, and before the 66 MB build has been run.
    ///
    /// Lives here rather than on the suite that uses it because a suite's own `.enabled(if:)`
    /// cannot reference its own static member - that is a circular reference, and the compiler
    /// reports it as `unknown attribute 'Suite'`, which reads like anything but what it is.
    static var fullDictionary: JMDictStore? {
        guard let path = ProcessInfo.processInfo.environment["KB_FULL_JMDICT"],
              FileManager.default.fileExists(atPath: path) else { return nil }
        let store = JMDictStore(databaseURL: URL(fileURLWithPath: path))
        return store.isReady && !store.isUsingBundledSeed ? store : nil
    }
}
