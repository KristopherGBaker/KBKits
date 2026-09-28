public import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
// URLSession and friends live outside Foundation in swift-corelibs.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Byte progress of a download. `expected` is -1 when the server doesn't report a
/// content length; `fraction` is nil then (indeterminate).
public struct DownloadProgress: Equatable, Sendable {
    public var received: Int64
    public var expected: Int64

    public init(received: Int64, expected: Int64) {
        self.received = received
        self.expected = expected
    }

    public var fraction: Double? {
        guard expected > 0 else { return nil }
        return min(1, Double(received) / Double(expected))
    }

    /// Megabytes, rounded, for display (1 MB = 1_000_000 bytes to match Finder).
    public var receivedMB: Int { Int((Double(received) / 1_000_000).rounded()) }

    /// Total megabytes, rounded, or nil when the server didn't report a length.
    public var expectedMB: Int? { expected > 0 ? Int((Double(expected) / 1_000_000).rounded()) : nil }
}

/// The handful of `FileManager` calls the atomic replacement makes, behind a protocol
/// so a test can fail ONE of them. `FileManager` conforms as-is - every requirement is
/// spelled with its real signature, so there is no adapter to drift - and it is the
/// default everywhere, which keeps this a test seam rather than a configuration knob.
///
/// Internal, not public: nothing outside KBCore should be swapping the file system out
/// from under a download.
protocol FileOperating {
    func fileExists(atPath path: String) -> Bool
    func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]?
    ) throws
    func moveItem(at srcURL: URL, to dstURL: URL) throws
    func removeItem(at url: URL) throws
    func replaceItemAt(
        _ originalItemURL: URL,
        withItemAt newItemURL: URL,
        backupItemName: String?,
        options: FileManager.ItemReplacementOptions
    ) throws -> URL?
}

/// The two-argument spellings the downloader actually writes. They live here rather than
/// in the protocol body so `FileManager`'s own defaulted parameters still satisfy the
/// requirements above without an adapter.
extension FileOperating {
    func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool) throws {
        try createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: nil)
    }

    func replaceItemAt(_ originalItemURL: URL, withItemAt newItemURL: URL) throws -> URL? {
        try replaceItemAt(originalItemURL, withItemAt: newItemURL, backupItemName: nil, options: [])
    }
}

extension FileManager: FileOperating {}

/// Shared file downloader for on-first-use fetches (speech-model weights, the Open
/// JTalk dictionary, a book from a catalog): one place for the URLSession download,
/// the HTTP status check, the atomic move into place, and throttled byte-progress
/// reporting, so no store carries its own near-identical copy and progress delegate.
///
/// It lives in KBCore because three unrelated kits need it and none of them should
/// depend on another just to fetch a file. Foundation only — KBCore's zero-dependency
/// rule still holds.
public enum FileDownloader {
    public enum DownloadError: Error, Sendable, Equatable, LocalizedError {
        case badURL(String)
        case http(Int, String)
        /// The bytes that arrived are not the bytes the caller pinned. Both digests
        /// ride in the error because the only useful thing a person can do with a
        /// mismatch is compare them (and, if the upstream really did republish,
        /// deliberately update the pin).
        case digestMismatch(expected: String, actual: String, url: String)

        /// `LocalizedError` rather than `CustomStringConvertible`: a download failure is shown
        /// to a person, and a consumer surfacing it reads `errorDescription` like it does for
        /// every other user-facing error in these packages.
        public var errorDescription: String? { description }

        public var description: String {
            switch self {
            case .badURL(let url): return "bad url \(url)"
            case .http(let code, let url): return "HTTP \(code) for \(url)"
            case .digestMismatch(let expected, let actual, let url):
                return "digest mismatch for \(url): expected \(expected), got \(actual)"
            }
        }
    }

    /// Download `urlString` to `destination` (atomic move from URLSession's temp
    /// file), reporting throttled byte progress of the transfer.
    ///
    /// `sha256` is the digest the downloaded bytes MUST have, lowercase hex. It has
    /// no default so every call site states its trust: a pinned artifact passes its
    /// digest, and something genuinely unpinnable (a book the user chose from a
    /// catalog) passes nil deliberately rather than by omission. When it is set the
    /// file is hashed and compared BEFORE anything at `destination` is touched, so a
    /// tampered or corrupted download can never replace a good install.
    public static func download(
        _ urlString: String,
        to destination: URL,
        sha256: String?,
        onProgress: (@Sendable (DownloadProgress) -> Void)? = nil
    ) async throws {
        // A scheme is required, not merely a parseable string: modern Foundation
        // happily reads "not a url" as a RELATIVE url, which then fails deep
        // inside URLSession as an opaque -1002 instead of here, where the caller
        // can see what it asked for. A network scheme additionally needs a host;
        // file: URLs legitimately have none (the Aozora import fetches a local
        // zip through this same path).
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased() else {
            throw DownloadError.badURL(urlString)
        }
        if scheme == "http" || scheme == "https", url.host()?.isEmpty != false {
            throw DownloadError.badURL(urlString)
        }
        let delegate = onProgress.map(ProgressDelegate.init)
        let (tempURL, response) = try await URLSession.shared.download(from: url, delegate: delegate)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw DownloadError.http(http.statusCode, urlString)
        }
        try verifyAndMove(tempURL, to: destination, sha256: sha256, url: urlString)
    }

    /// The single verify-then-move choke point every download goes through: hash the
    /// fetched file, compare, and only then replace the destination. Package-internal
    /// so tests drive the very code path `download` runs rather than a lookalike.
    ///
    /// The replacement is ATOMIC, and that is the whole point of the two-step dance below.
    /// Deleting the destination and then moving onto it leaves a window in which neither
    /// the old file nor the new one is there, and any failure inside that window (a full
    /// disk, a cross-volume move, a killed process) destroys a good install to install
    /// nothing. So the fetched bytes are first moved to a sibling of the destination -
    /// same directory, hence same volume, hence a rename rather than a copy - and only
    /// then swapped in with one `replaceItemAt`/`moveItem`. Every failure path removes
    /// OUR staging file and leaves whatever was already installed byte-identical.
    ///
    /// `fileManager` is the seam that makes that last claim testable. The swap is the one
    /// step whose failure a test cannot provoke through the real file system - the staging
    /// file and the destination are siblings, so any permission or volume trick that breaks
    /// the swap has already broken the staging move - so a test hands in a `FileOperating`
    /// that fails exactly there and asserts the old bytes survived. Production never passes
    /// it: the default IS `FileManager.default`, and `download` above runs that path.
    static func verifyAndMove(
        _ temporary: URL,
        to destination: URL,
        sha256 expected: String?,
        url: String,
        fileManager: any FileOperating = FileManager.default
    ) throws {
        if let expected {
            let actual = try fileDigest(temporary)
            guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
                // Remove OUR temp file, never the destination: a failed download
                // must leave whatever was already installed exactly as it was.
                try? fileManager.removeItem(at: temporary)
                throw DownloadError.digestMismatch(expected: expected, actual: actual, url: url)
            }
        }
        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let staged = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).download-\(UUID().uuidString)")
        do {
            try fileManager.moveItem(at: temporary, to: staged)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
        do {
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: staged)
            } else {
                try fileManager.moveItem(at: staged, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: staged)
            throw error
        }
    }

    /// Lowercase-hex SHA-256 of a file, streamed so a 300 MB model never lands in
    /// memory whole.
    static func fileDigest(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Per-task download delegate that forwards throttled (~1 MB) byte progress.
/// URLSession calls `didWriteData` off the main actor, so the handler must be
/// `Sendable`. `didFinishDownloadingTo` is required by the protocol but the async
/// `download(from:delegate:)` returns the temp file itself, so it's a no-op.
/// Internal (not private) so a test can drive the real throttling logic.
final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (DownloadProgress) -> Void
    private var nextReport: Int64 = 0

    init(_ onProgress: @escaping @Sendable (DownloadProgress) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesWritten >= nextReport || totalBytesWritten == totalBytesExpectedToWrite else { return }
        nextReport = totalBytesWritten + 1_000_000
        onProgress(DownloadProgress(received: totalBytesWritten,
                                    expected: totalBytesExpectedToWrite))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}
}
