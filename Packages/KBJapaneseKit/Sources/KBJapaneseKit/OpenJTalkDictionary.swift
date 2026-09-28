public import Foundation
public import KBCore
#if canImport(Darwin)
// SWCompression only where the download/extract path exists. Its TarReader and TarWriter
// call `autoreleasepool` unguarded, which resolves on Darwin and on Linux (corelibs shims
// it) but not against the Android SDK's Foundation, so the package will not cross-compile.
// Rather than fork it, note that Android has no download-and-untar story anyway: the host
// ships the dictionary and points `dictionaryDirectory` at it.
import SWCompression
#endif

/// Locates (and on first use, downloads + extracts) the Open JTalk UTF-8 dictionary
/// that the OpenJTalk-backed Japanese analysis needs. The ~23 MB tarball is fetched
/// from the r9y9/open_jtalk release, extracted under Application Support, and reused
/// thereafter. When absent, `JapaneseReader()` returns nil and callers fall back —
/// for synthesis, to the pure-Apple G2P (no download required).
///
/// **Installation is all-or-nothing.** "Installed" means the four files the frontend loads
/// (``requiredFiles``) AND the completion marker, and the marker is written in a staging
/// directory beside the final one and moved into place in a single rename. A download killed
/// halfway therefore leaves the final directory either absent or exactly as it was, never a
/// partial dictionary that answers the presence check and then fails to load. This matters
/// because it happened: the check was `sys.dic` alone, which is the FIRST file the tarball
/// unpacks, so any interruption produced a dictionary that counted as installed forever.
///
/// Licensing: the dictionary (naist-jdic) is BSD and the Open JTalk frontend is
/// modified-BSD — neither carries the GPL distribution risk that parked eSpeak.
public actor OpenJTalkDictionary {

    /// What went wrong, structured rather than flattened into a sentence.
    ///
    /// The payloads are typed because a caller does act on them differently: a digest
    /// mismatch means the pin or the upstream artifact changed and no retry will help, an
    /// HTTP or transport failure is worth retrying, and an incomplete extraction names the
    /// files that did not arrive. `LocalizedError` because these reach a person: a consumer
    /// shows `errorDescription` for this the same way it does for every other error in these
    /// packages.
    public enum StoreError: Error, Sendable, Equatable, LocalizedError {
        /// The tarball could not be fetched.
        case downloadFailed(DownloadFailure)
        /// The tarball arrived but did not become a usable dictionary.
        case extractFailed(ExtractFailure)
        /// This platform has no bundled download/extract path; the host must place the
        /// dictionary itself and point the analysis at it.
        case unsupportedPlatform(String)
        /// Application Support could not be resolved, so there is nowhere durable to install
        /// to. This used to fall back to the temporary directory silently, which installs
        /// ~100 MB somewhere the OS may reclaim between launches and re-downloads it, on
        /// cellular, with no one the wiser.
        case applicationSupportUnavailable(String)

        public var errorDescription: String? {
            switch self {
            case .downloadFailed(let failure):
                return "Could not download the Japanese dictionary: \(failure.description)."
            case .extractFailed(let failure):
                return "Could not unpack the Japanese dictionary: \(failure.description)."
            case .unsupportedPlatform(let detail):
                return "The Japanese dictionary cannot be downloaded on this platform: \(detail)."
            case .applicationSupportUnavailable(let detail):
                return "There is nowhere to install the Japanese dictionary: \(detail)."
            }
        }
    }

    /// Why the fetch failed, preserving the download layer's own structure where it had some.
    /// `other` carries a description because an arbitrary transport error has no shape worth
    /// reproducing here. A sibling of ``StoreError`` rather than a member of it, because the
    /// house nesting limit is one level and a three-deep case name reads worse anyway.
    public enum DownloadFailure: Sendable, Equatable {
        case digestMismatch(expected: String, actual: String)
        case http(status: Int)
        case badURL(String)
        case other(String)

        init(_ error: any Error) {
            switch error {
            case let error as FileDownloader.DownloadError:
                switch error {
                case .digestMismatch(let expected, let actual, _):
                    self = .digestMismatch(expected: expected, actual: actual)
                case .http(let status, _):
                    self = .http(status: status)
                case .badURL(let url):
                    self = .badURL(url)
                }
            default:
                self = .other(String(describing: error))
            }
        }
    }

    /// Why the archive did not become a dictionary.
    public enum ExtractFailure: Sendable, Equatable {
        /// The archive unpacked, but these of ``requiredFiles`` were not in it.
        case incompleteDictionary(missing: [String])
        /// gunzip or tar could not read the archive.
        case unreadableArchive(String)
        /// Staging, or the move into place, failed (no space, no permission).
        case installFailed(String)
    }

    /// The four files the Open JTalk frontend loads. All of them, or the dictionary is not
    /// installed: `sys.dic` alone is the first entry in the tarball and so is present in
    /// every interrupted extraction.
    public static let requiredFiles = ["sys.dic", "matrix.bin", "char.bin", "unk.dic"]

    /// Written INSIDE the dictionary directory, in staging, after the four files are verified,
    /// and carried into place by the same rename that installs them. Its presence is therefore
    /// proof that a complete extraction was moved in whole.
    static let completionMarker = ".kits-openjtalk-complete"

    private let dictName = "open_jtalk_dic_utf_8-1.11"
    private let archiveURL =
        "https://github.com/r9y9/open_jtalk/releases/download/v1.11.1/open_jtalk_dic_utf_8-1.11.tar.gz"
    /// The bytes that URL must serve. A dictionary is data the analysis executes
    /// against for every reading in the app; an unverified one is a trust hole with
    /// a network in it. Re-derivable from the URL (see the unit's derive-digests.sh).
    static let archiveSHA256 =
        "fe6ba0e43542cef98339abdffd903e062008ea170b04e7e2a35da805902f382a"
    /// Application Support subdirectory the dictionary is cached under. Each app names
    /// its own folder, since a shared kit has no business writing to another app's.
    private let subdirectory: String

    /// How the archive is fetched. Production forwards to `FileDownloader.download`;
    /// a test injects a recorder so the (url, destination, digest) actually passed can
    /// be observed offline.
    typealias Fetch = @Sendable (
        _ url: String, _ to: URL, _ sha256: String?,
        _ onProgress: (@Sendable (DownloadProgress) -> Void)?
    ) async throws -> Void

    private let fetch: Fetch
    /// Overrides the Application Support location, so a test can point the whole
    /// store at a temp directory instead of the user's real one.
    private let baseDirectoryOverride: URL?

    /// - Parameter applicationSupportSubdirectory: path under Application Support to
    ///   cache in, e.g. `"MyApp/openjtalk"`.
    public init(applicationSupportSubdirectory: String) {
        self.init(applicationSupportSubdirectory: applicationSupportSubdirectory,
                  baseDirectoryOverride: nil, fetch: nil)
    }

    init(
        applicationSupportSubdirectory: String,
        baseDirectoryOverride: URL?,
        fetch: Fetch?
    ) {
        self.subdirectory = applicationSupportSubdirectory
        self.baseDirectoryOverride = baseDirectoryOverride
        self.fetch = fetch ?? { url, destination, sha256, onProgress in
            try await FileDownloader.download(url, to: destination, sha256: sha256,
                                              onProgress: onProgress)
        }
    }

    /// The user's Application Support directory, or nil when it cannot be resolved.
    static var applicationSupportDirectory: URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: true)
    }

    /// Where this store caches, or nil when Application Support cannot be resolved.
    private var baseDirectory: URL? {
        if let baseDirectoryOverride { return baseDirectoryOverride }
        return Self.applicationSupportDirectory?
            .appendingPathComponent(subdirectory, isDirectory: true)
    }

    /// The cache directory, or a thrown error.
    ///
    /// There is deliberately NO temp-directory fallback. The old one was silent, and it
    /// installed ~100 MB where the OS may reclaim it between launches: the next launch found
    /// nothing, downloaded it again, and no one ever learned that Application Support was the
    /// problem. Static and injectable so the unavailable branch is actually testable, rather
    /// than being the one branch that only ever runs on a stranger's device.
    static func resolveBaseDirectory(subdirectory: String, applicationSupport: URL?) throws -> URL {
        guard let applicationSupport else {
            throw StoreError.applicationSupportUnavailable(
                "Application Support is unavailable, so \(subdirectory) cannot be created")
        }
        return applicationSupport.appendingPathComponent(subdirectory, isDirectory: true)
    }

    private func resolvedBaseDirectory() throws -> URL {
        if let baseDirectoryOverride { return baseDirectoryOverride }
        return try Self.resolveBaseDirectory(
            subdirectory: subdirectory, applicationSupport: Self.applicationSupportDirectory)
    }

    /// The dictionary directory, if a COMPLETE one has already been downloaded + extracted.
    /// Cheap, non-downloading check used to decide whether to prefer OpenJTalk.
    public var existingDictionaryDirectory: URL? {
        guard let directory = baseDirectory?.appendingPathComponent(dictName, isDirectory: true)
        else { return nil }
        return Self.isInstalled(at: directory) ? directory : nil
    }

    /// Whether `directory` holds a complete, completely-installed dictionary: the marker AND
    /// every one of ``requiredFiles``. Both halves matter. The marker alone would pass for a
    /// directory someone pruned; the files alone would pass for an extraction that was moved
    /// in by an older build without one.
    static func isInstalled(at directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(completionMarker).path)
            && missingFiles(in: directory).isEmpty
    }

    /// Which of ``requiredFiles`` are absent from `directory`, in the declared order.
    static func missingFiles(in directory: URL) -> [String] {
        requiredFiles.filter {
            !FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    /// Ensure the dictionary exists locally (downloading + extracting on first use) and
    /// point the Open JTalk frontend at it, returning its directory. `onProgress`
    /// reports byte progress of the tarball download.
    ///
    /// Cancellation surfaces as `CancellationError`, unchanged: the caller asked for it, so it
    /// is not a `StoreError` and must not be shown as a download failure.
    @discardableResult
    public func ensureAvailable(
        onProgress: (@Sendable (DownloadProgress) -> Void)? = nil
    ) async throws -> URL {
        if let existing = existingDictionaryDirectory {
            JapaneseTextAnalysis.useDictionary(at: existing)
            return existing
        }

        #if !canImport(Darwin)
        // No fetcher here on purpose. See the SWCompression note at the top: off Apple the
        // dictionary arrives with the app (an Android asset, say) and the host calls
        // `JapaneseTextAnalysis.useDictionary(at:)`. Failing loudly beats pretending.
        throw StoreError.unsupportedPlatform(
            "no bundled Open JTalk download on this platform; supply the dictionary directory")
        #else
        let fileManager = FileManager.default
        let base = try resolvedBaseDirectory()
        let staging = base.appendingPathComponent("\(dictName).staging", isDirectory: true)
        let installed = base.appendingPathComponent(dictName, isDirectory: true)

        // Staging is this run's scratch space and never outlives it: whether the extraction
        // succeeds, fails, or is cancelled, the directory is gone by the time this returns.
        // One left over from an earlier run (a crash, a kill, an older build) is deleted
        // before it is recreated rather than reused, because reusing half an extraction is
        // exactly how a partial dictionary came to count as installed.
        try? fileManager.removeItem(at: staging)
        defer { try? fileManager.removeItem(at: staging) }

        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            throw StoreError.extractFailed(.installFailed(String(describing: error)))
        }

        try Task.checkCancellation()
        let archive = staging.appendingPathComponent("\(dictName).tar.gz")
        try await download(archiveURL, to: archive, sha256: Self.archiveSHA256,
                           onProgress: onProgress)
        try extract(archive: archive, into: staging)
        try? fileManager.removeItem(at: archive)
        try install(from: staging, to: installed)

        guard Self.isInstalled(at: installed) else {
            throw StoreError.extractFailed(
                .incompleteDictionary(missing: Self.missingFiles(in: installed)))
        }
        JapaneseTextAnalysis.useDictionary(at: installed)
        return installed
        #endif
    }

    #if canImport(Darwin)
    private func download(
        _ urlString: String,
        to destination: URL,
        sha256: String?,
        onProgress: (@Sendable (DownloadProgress) -> Void)? = nil
    ) async throws {
        do {
            try await fetch(urlString, destination, sha256, onProgress)
        } catch is CancellationError {
            // Cancellation is the caller's own decision, not a failure of the store. Wrapping
            // it in `downloadFailed` is what made tapping Cancel produce an error alert, and
            // it also hid cancellation from any `catch is CancellationError` upstream.
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            // URLSession reports a cancelled transfer as `URLError.cancelled` rather than as
            // `CancellationError`, so the two arrive by different doors and leave by one.
            throw CancellationError()
        } catch let error as StoreError {
            throw error
        } catch {
            throw StoreError.downloadFailed(DownloadFailure(error))
        }
    }

    /// Extract the `.tar.gz` (gunzip → untar) into `directory`, writing each entry
    /// under its archived path (the archive has a top-level `open_jtalk_dic_utf_8-1.11/`
    /// folder). Pure-Swift via SWCompression, so it works on macOS *and* iOS (no
    /// `Process`/`tar`).
    ///
    /// The tar is streamed one entry at a time (`TarReader`) rather than parsed whole
    /// (`TarContainer.open`), which would resurrect every entry's bytes in memory — a
    /// few-hundred-MB transient spike on iPhone for the ~100 MB dictionary.
    ///
    /// `directory` is always a staging directory, never the installed one, so a failure here
    /// is thrown away wholesale by the caller.
    private func extract(archive: URL, into directory: URL) throws {
        do {
            let fileManager = FileManager.default
            // Gunzip to a temp `.tar` on disk, then release the decompressed buffer
            // before the streaming pass so only one entry is resident at a time.
            let tarURL = directory.appendingPathComponent("\(dictName).tar")
            try autoreleasepool {
                let tarData = try GzipArchive.unarchive(archive: try Data(contentsOf: archive))
                try tarData.write(to: tarURL)
            }
            defer { try? fileManager.removeItem(at: tarURL) }

            let handle = try FileHandle(forReadingFrom: tarURL)
            defer { try? handle.close() }
            var reader = TarReader(fileHandle: handle)
            while let entry = try reader.read() {
                // Unpacking ~100 MB is the long pole, so cancellation is checked per entry
                // rather than only before the download.
                try Task.checkCancellation()
                let name = entry.info.name
                // Guard against path traversal from a malformed archive.
                guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("..") else { continue }
                let destination = directory.appendingPathComponent(name)
                switch entry.info.type {
                case .directory:
                    try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
                case .regular, .contiguous:
                    try fileManager.createDirectory(
                        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try (entry.data ?? Data()).write(to: destination)
                default:
                    continue   // skip symlinks/special entries (the dictionary has none)
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as StoreError {
            throw error
        } catch {
            throw StoreError.extractFailed(.unreadableArchive(String(describing: error)))
        }
    }

    /// Move the extracted dictionary out of `staging` and into `destination` in ONE filesystem
    /// operation, after verifying it is complete and marking it so.
    ///
    /// The order is the whole fix. The four files are checked, and the marker written, while
    /// everything is still in staging; the rename then publishes all five together. There is
    /// no instant at which `destination` holds a marker beside an incomplete dictionary, and
    /// no failure mode that can leave one, because nothing is ever written into `destination`
    /// piece by piece.
    private func install(from staging: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        // The tarball carries a top-level `open_jtalk_dic_utf_8-1.11/` folder, so the payload
        // is normally one level down. An archive that unpacked flat is accepted too, which is
        // what lets a test drive this with a small fixture.
        let nested = staging.appendingPathComponent(dictName, isDirectory: true)
        let payload = fileManager.fileExists(atPath: nested.path) ? nested : staging
        // Reported against the directory the archive really created, so an incomplete tarball
        // names the files IT was missing rather than all four.
        let missing = Self.missingFiles(in: payload)
        guard missing.isEmpty else {
            throw StoreError.extractFailed(.incompleteDictionary(missing: missing))
        }
        do {
            try Data().write(to: payload.appendingPathComponent(Self.completionMarker))
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: payload)
            } else {
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
                try fileManager.moveItem(at: payload, to: destination)
            }
        } catch {
            throw StoreError.extractFailed(.installFailed(String(describing: error)))
        }
    }
    #endif
}

extension OpenJTalkDictionary.DownloadFailure {
    /// The half-sentence `errorDescription` drops into. Separate from the case so the
    /// wording lives beside the data it describes.
    var description: String {
        switch self {
        case .digestMismatch(let expected, let actual):
            return "the bytes that arrived are not the ones pinned (expected \(expected), got \(actual))"
        case .http(let status):
            return "the server answered HTTP \(status)"
        case .badURL(let url):
            return "\(url) is not a usable URL"
        case .other(let detail):
            return detail
        }
    }
}

extension OpenJTalkDictionary.ExtractFailure {
    var description: String {
        switch self {
        case .incompleteDictionary(let missing):
            return "the archive did not contain \(missing.joined(separator: ", "))"
        case .unreadableArchive(let detail):
            return "the archive could not be read (\(detail))"
        case .installFailed(let detail):
            return "it could not be moved into place (\(detail))"
        }
    }
}
