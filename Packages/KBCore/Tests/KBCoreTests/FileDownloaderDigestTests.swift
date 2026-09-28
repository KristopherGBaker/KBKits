import Foundation
import Testing
@testable import KBCore

/// The digest check at the heart of every self-provisioned download: the same
/// verify-then-move choke point `download` runs, driven over local files so the
/// tests need no network and no real artifact.
/// One canned HTTP response on loopback, so the REAL download path (status
/// check, digest, move) runs without reaching the network. Deliberately a
/// plain socket: no test dependency, and it is the same shape the Android
/// downloader's tests use.
private final class CannedServer: @unchecked Sendable {
    private let listener: Int32
    private var worker: Thread?
    let port: Int

    init(status: String, body: Data) throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        self.listener = listener
        var yes: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0  // any free port
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(listener, 4) == 0 else {
            Darwin.close(listener)
            throw CannedServerError.couldNotListen
        }
        var boundAddress = sockaddr_in()
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                getsockname(listener, rebound, &size)
            }
        }
        self.port = Int(UInt16(bigEndian: boundAddress.sin_port))

        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        let response = Data(head.utf8) + body
        let thread = Thread {
            while true {
                let client = accept(listener, nil, nil)
                if client < 0 { return }
                // Drain the request head so the client is not reset mid-write.
                var scratch = [UInt8](repeating: 0, count: 4096)
                _ = recv(client, &scratch, scratch.count, 0)
                response.withUnsafeBytes { raw in
                    var sent = 0
                    while sent < raw.count {
                        let wrote = send(client, raw.baseAddress!.advanced(by: sent),
                                         raw.count - sent, 0)
                        if wrote <= 0 { break }
                        sent += wrote
                    }
                }
                Darwin.close(client)
            }
        }
        thread.start()
        self.worker = thread
    }

    enum CannedServerError: Error { case couldNotListen }

    func close() {
        Darwin.close(listener)
        worker?.cancel()
    }
}

@Suite("FileDownloaderDigest: pinned bytes, or nothing lands")
struct FileDownloaderDigestTests {

    private func temporaryDirectory() throws -> URL {
        let directory = URL.temporaryDirectory
            .appendingPathComponent("kbcore-digest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func write(_ bytes: Data, named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    @Test("a matching digest moves the bytes into place")
    func matchingDigestLands() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload = Data((0 ..< 4096).map { UInt8($0 % 251) })
        let source = try write(payload, named: "incoming.bin", in: directory)
        let digest = try FileDownloader.fileDigest(source)
        let destination = directory.appendingPathComponent("installed.bin")

        try FileDownloader.verifyAndMove(source, to: destination, sha256: digest,
                                         url: "https://example.invalid/a.bin")

        #expect(try Data(contentsOf: destination) == payload)
        #expect(!FileManager.default.fileExists(atPath: source.path))
    }

    @Test("a mismatch names both digests and the url in the surfaced message")
    func mismatchMessageNamesBoth() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try write(Data("the wrong bytes".utf8), named: "incoming.bin", in: directory)
        let actual = try FileDownloader.fileDigest(source)
        let expected = String(repeating: "a", count: 64)
        let url = "https://example.invalid/model.safetensors"

        #expect(throws: FileDownloader.DownloadError.self) {
            try FileDownloader.verifyAndMove(source, to: directory.appendingPathComponent("out.bin"),
                                             sha256: expected, url: url)
        }
        // The message a person actually sees carries everything they need to act.
        do {
            try FileDownloader.verifyAndMove(
                try write(Data("the wrong bytes".utf8), named: "again.bin", in: directory),
                to: directory.appendingPathComponent("out.bin"), sha256: expected, url: url)
            Issue.record("expected a digest mismatch")
        } catch let error as FileDownloader.DownloadError {
            let message = error.errorDescription ?? ""
            #expect(message.contains(expected))
            #expect(message.contains(actual))
            #expect(message.contains(url))
        }
    }

    @Test("a mismatch leaves an existing install byte-for-byte untouched")
    func mismatchNeverReplacesTheDestination() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sentinel = Data("the previous good install".utf8)
        let destination = try write(sentinel, named: "installed.bin", in: directory)
        let source = try write(Data("tampered".utf8), named: "incoming.bin", in: directory)

        #expect(throws: FileDownloader.DownloadError.self) {
            try FileDownloader.verifyAndMove(source, to: destination,
                                             sha256: String(repeating: "b", count: 64),
                                             url: "https://example.invalid/x")
        }
        #expect(try Data(contentsOf: destination) == sentinel)
    }

    @Test("a mismatch leaves no partial behind")
    func mismatchLeavesNoPartial() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try write(Data("tampered".utf8), named: "incoming.bin", in: directory)
        let destination = directory.appendingPathComponent("installed.bin")

        #expect(throws: FileDownloader.DownloadError.self) {
            try FileDownloader.verifyAndMove(source, to: destination,
                                             sha256: String(repeating: "c", count: 64),
                                             url: "https://example.invalid/x")
        }
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(leftovers.isEmpty)
    }

    @Test("a nil pin keeps the unverified path working")
    func nilPinSkipsVerification() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload = Data("a book the reader chose".utf8)
        let source = try write(payload, named: "incoming.epub", in: directory)
        let destination = directory.appendingPathComponent("book.epub")

        try FileDownloader.verifyAndMove(source, to: destination, sha256: nil,
                                         url: "https://example.invalid/book.epub")
        #expect(try Data(contentsOf: destination) == payload)
    }

    @Test("a staging move that fails keeps the previous good file byte-identical")
    func failedStagingKeepsTheOldFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sentinel = Data("the previous good install".utf8)
        let destination = try write(sentinel, named: "installed.bin", in: directory)
        // A fetched file that is not there is the cheapest deterministic stand-in for
        // every way STAGING can fail (a vanished temp dir, a revoked sandbox extension).
        // Note what this does NOT reach: the swap. It throws on the very first move, so
        // it says nothing about whether the swap is atomic - that is
        // `FileDownloaderAtomicSwapTests`, and the two are not interchangeable.
        let absent = directory.appendingPathComponent("never-arrived.bin")

        #expect(throws: (any Error).self) {
            try FileDownloader.verifyAndMove(absent, to: destination, sha256: nil,
                                             url: "https://example.invalid/x")
        }
        #expect(try Data(contentsOf: destination) == sentinel)
        // And no staging sibling was left in the destination directory.
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path)
                == ["installed.bin"])
    }

    @Test("a successful replacement swaps the bytes and leaves no staging file behind")
    func successfulReplacementLeavesOnlyTheDestination() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = try write(Data("the old install".utf8), named: "installed.bin",
                                    in: directory)
        let payload = Data("the new install".utf8)
        let incoming = try write(payload, named: "incoming.bin", in: directory)

        try FileDownloader.verifyAndMove(incoming, to: destination,
                                         sha256: try FileDownloader.fileDigest(incoming),
                                         url: "https://example.invalid/x")

        #expect(try Data(contentsOf: destination) == payload)
        // The staging file lives in the DESTINATION directory (same volume, so the swap
        // is a rename), which is precisely why it must not survive the swap.
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path)
                == ["installed.bin"])
    }

    @Test("a first install creates the destination directory")
    func firstInstallCreatesTheDirectory() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload = Data("a fresh install".utf8)
        let source = try write(payload, named: "incoming.bin", in: directory)
        let destination = directory
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("installed.bin")

        try FileDownloader.verifyAndMove(source, to: destination, sha256: nil,
                                         url: "https://example.invalid/x")
        #expect(try Data(contentsOf: destination) == payload)
    }

    @Test("a bad url throws before anything else happens", arguments: [
        "not a url",       // parses as a RELATIVE url in modern Foundation
        "http://[bad",     // unparseable authority
        "/just/a/path",    // no scheme at all
        "https:///nohost"  // a network scheme with no host
    ])
    func badURL(candidate: String) async {
        await #expect(throws: FileDownloader.DownloadError.badURL(candidate)) {
            try await FileDownloader.download(candidate,
                                              to: URL.temporaryDirectory.appendingPathComponent("x"),
                                              sha256: nil)
        }
    }

    @Test("progress is reported as bytes arrive, throttled, and always at the end")
    func progressReachesTheCallback() {
        // The production delegate's own throttling logic, driven directly: it
        // reports about every megabyte and ALWAYS on the final byte, so a UI
        // never sits at 99%.
        final class Sink: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var reports: [DownloadProgress] = []
            func record(_ progress: DownloadProgress) { lock.withLock { reports.append(progress) } }
        }
        let sink = Sink()
        let delegate = ProgressDelegate { sink.record($0) }
        let total: Int64 = 3_000_000
        let session = URLSession.shared
        let task = session.downloadTask(with: URL(string: "https://example.invalid/x")!)
        for written in stride(from: Int64(250_000), through: total, by: 250_000) {
            delegate.urlSession(session, downloadTask: task, didWriteData: 250_000,
                                totalBytesWritten: written, totalBytesExpectedToWrite: total)
        }
        task.cancel()

        let reports = sink.reports
        #expect(!reports.isEmpty)
        // Throttled: far fewer than the twelve writes.
        #expect(reports.count < 12)
        let last = reports.last
        #expect(last?.received == total)
        #expect(last?.expected == total)
        #expect(last?.fraction == 1.0)
    }

    @Test("a non-200 response throws before any digest work or destination change")
    func httpErrorPrecedesTheDigest() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sentinel = Data("the previous good install".utf8)
        let destination = directory.appendingPathComponent("kept.bin")
        try sentinel.write(to: destination)

        let server = try CannedServer(status: "404 Not Found", body: Data())
        defer { server.close() }

        await #expect(throws: FileDownloader.DownloadError.self) {
            // A pin is supplied deliberately: if the status check did NOT come
            // first, the failure would be a digest mismatch instead.
            try await FileDownloader.download("http://127.0.0.1:\(server.port)/missing",
                                              to: destination,
                                              sha256: String(repeating: "d", count: 64))
        }
        do {
            try await FileDownloader.download("http://127.0.0.1:\(server.port)/missing",
                                              to: destination, sha256: nil)
            Issue.record("expected the 404 to raise")
        } catch let error as FileDownloader.DownloadError {
            #expect(error == .http(404, "http://127.0.0.1:\(server.port)/missing"))
        }
        #expect(try Data(contentsOf: destination) == sentinel)
    }

    @Test("a file url still downloads - it has no host, and needs none")
    func fileURLsStillWork() async throws {
        // The Aozora import fetches a local zip through this same path, so the
        // scheme/host guard must not treat file: as malformed.
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload = Data("a local archive".utf8)
        let source = try write(payload, named: "local.zip", in: directory)
        let destination = directory.appendingPathComponent("imported.zip")
        let digest = try FileDownloader.fileDigest(source)

        try await FileDownloader.download(source.absoluteString, to: destination, sha256: digest)
        #expect(try Data(contentsOf: destination) == payload)
    }

    @Test("a served body is verified against its pin end to end")
    func servedBodyIsVerified() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload = Data((0 ..< 200_000).map { UInt8($0 % 251) })
        let digest = try FileDownloader.fileDigest(
            try write(payload, named: "reference.bin", in: directory))
        let destination = directory.appendingPathComponent("served.bin")

        let good = try CannedServer(status: "200 OK", body: payload)
        try await FileDownloader.download("http://127.0.0.1:\(good.port)/a.bin",
                                          to: destination, sha256: digest)
        good.close()
        #expect(try Data(contentsOf: destination) == payload)

        // The same bytes with one flipped: the pin must reject them and leave
        // the good install in place.
        var tampered = payload
        tampered[1234] = tampered[1234] &+ 1
        let bad = try CannedServer(status: "200 OK", body: tampered)
        defer { bad.close() }
        await #expect(throws: FileDownloader.DownloadError.self) {
            try await FileDownloader.download("http://127.0.0.1:\(bad.port)/a.bin",
                                              to: destination, sha256: digest)
        }
        #expect(try Data(contentsOf: destination) == payload)
    }

    @Test("the digest is the file's own streamed sha256")
    func digestMatchesKnownVector() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // sha256("abc"), the canonical vector - so a broken hasher cannot agree
        // with itself and pass every other test in this suite.
        let file = try write(Data("abc".utf8), named: "abc.txt", in: directory)
        #expect(try FileDownloader.fileDigest(file)
                    == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
