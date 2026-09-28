import Foundation
import Testing
@testable import KBCore

/// The one claim the digest suite structurally cannot make: that the SWAP itself is
/// atomic. Every failure a test can provoke from the outside (a missing source, a
/// read-only directory, an immutable destination) stops the downloader at or before
/// the staging move, so it never reaches the replacement and says nothing about it.
/// These tests break the swap and nothing else.

/// A real file system with one thing broken: the swap of the staged file onto the
/// destination. Everything else - the directory creation, the staging rename, the
/// cleanup - runs against `FileManager` for real, so the downloader arrives at the
/// swap having genuinely hashed, accepted and staged the new bytes.
///
/// It fails BOTH spellings of the swap - `replaceItemAt`, and a `moveItem` onto the
/// destination - which is what makes it a guard rather than a mirror of the current
/// implementation: a delete-then-move version unlinks the good install, hits the same
/// failure on the move, and loses it. `removeItem` is deliberately NOT broken, so that
/// unlinking succeeds and the damage is visible.
private final class SwapFailsFileSystem: FileOperating, @unchecked Sendable {
    enum Failure: Error, Equatable { case theSwapFailed }

    private let real = FileManager.default
    private let destination: URL
    private(set) var swapAttempts = 0
    private(set) var unlinkedTheDestination = false

    init(destination: URL) { self.destination = destination }

    private func isDestination(_ url: URL) -> Bool {
        url.standardizedFileURL == destination.standardizedFileURL
    }

    func fileExists(atPath path: String) -> Bool { real.fileExists(atPath: path) }

    func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]?
    ) throws {
        try real.createDirectory(at: url, withIntermediateDirectories: createIntermediates,
                                 attributes: attributes)
    }

    func moveItem(at srcURL: URL, to dstURL: URL) throws {
        guard !isDestination(dstURL) else {
            swapAttempts += 1
            throw Failure.theSwapFailed
        }
        try real.moveItem(at: srcURL, to: dstURL)
    }

    func removeItem(at url: URL) throws {
        if isDestination(url) { unlinkedTheDestination = true }
        try real.removeItem(at: url)
    }

    func replaceItemAt(
        _ originalItemURL: URL,
        withItemAt newItemURL: URL,
        backupItemName: String?,
        options: FileManager.ItemReplacementOptions
    ) throws -> URL? {
        swapAttempts += 1
        throw Failure.theSwapFailed
    }
}

@Suite("FileDownloader: the swap itself is atomic")
struct FileDownloaderAtomicSwapTests {

    private func temporaryDirectory() throws -> URL {
        let directory = URL.temporaryDirectory
            .appendingPathComponent("kbcore-swap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func write(_ bytes: Data, named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    @Test("a swap that fails AFTER staging keeps the previous good file byte-identical")
    func failedSwapKeepsTheOldFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sentinel = Data("the previous good install".utf8)
        let destination = try write(sentinel, named: "installed.bin", in: directory)
        let incoming = try write(Data("the new install".utf8), named: "incoming.bin", in: directory)
        // A real digest, so the bytes are hashed AND accepted: execution gets all the way
        // past staging and dies on the swap, the only moment at which a non-atomic
        // replacement can destroy a good install.
        let digest = try FileDownloader.fileDigest(incoming)
        let files = SwapFailsFileSystem(destination: destination)

        #expect(throws: SwapFailsFileSystem.Failure.theSwapFailed) {
            try FileDownloader.verifyAndMove(incoming, to: destination, sha256: digest,
                                             url: "https://example.invalid/x", fileManager: files)
        }

        // The swap really was reached. Without this the test asserts nothing, which is
        // precisely how its predecessor passed against a delete-then-move implementation.
        #expect(files.swapAttempts == 1)
        #expect(!FileManager.default.fileExists(atPath: incoming.path), "the bytes were staged")
        // `contents(atPath:)` rather than `Data(contentsOf:)`: a destroyed destination has
        // to read as a failed expectation, not as a throw out of the assertion itself.
        #expect(FileManager.default.contents(atPath: destination.path) == sentinel)
        // Nothing was unlinked on the way, and the staging sibling did not survive.
        #expect(!files.unlinkedTheDestination)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path)
                == ["installed.bin"])
    }

    @Test("a swap that fails with no previous install leaves nothing behind")
    func failedSwapOnFirstInstallLeavesNothing() throws {
        // The other branch of the swap: nothing to replace, so the staged file is moved
        // straight onto the destination. When that fails there is no good install to
        // protect, but there must also be no staging debris.
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("installed.bin")
        let incoming = try write(Data("the first install".utf8), named: "incoming.bin", in: directory)
        let files = SwapFailsFileSystem(destination: destination)

        #expect(throws: SwapFailsFileSystem.Failure.theSwapFailed) {
            try FileDownloader.verifyAndMove(incoming, to: destination, sha256: nil,
                                             url: "https://example.invalid/x", fileManager: files)
        }
        #expect(files.swapAttempts == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test("the seam is a test seam: the default path is the real FileManager")
    func defaultPathUsesTheRealFileSystem() throws {
        // Guards the injection point itself. If the default ever stopped being the real
        // file system, every other test in this package would pass against a fiction.
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload = Data("the new install".utf8)
        let destination = try write(Data("the old install".utf8), named: "installed.bin",
                                    in: directory)
        let incoming = try write(payload, named: "incoming.bin", in: directory)

        try FileDownloader.verifyAndMove(incoming, to: destination,
                                         sha256: try FileDownloader.fileDigest(incoming),
                                         url: "https://example.invalid/x")

        #expect(FileManager.default.contents(atPath: destination.path) == payload)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path)
                == ["installed.bin"])
    }
}
