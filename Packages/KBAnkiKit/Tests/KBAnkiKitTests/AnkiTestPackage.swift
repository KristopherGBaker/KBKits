import Foundation
import ZIPFoundation
import libzstd

/// Builds the `.apkg`-shaped archives the media tests read back.
///
/// Shared so the streaming suite and the manifest suite exercise the same writer: a
/// fixture builder that drifted between them would let one suite pass against bytes
/// the other could not produce.
enum AnkiTestPackage {
    static func make(_ entries: [String: Data]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).apkg")
        let archive = try Archive(url: url, accessMode: .create)
        for (name, data) in entries.sorted(by: { $0.key < $1.key }) {
            try archive.addEntry(
                with: name, type: .file, uncompressedSize: Int64(data.count),
                provider: { position, size in data.subdata(in: Int(position)..<Int(position) + size) })
        }
        return url
    }

    /// zstd-compress `data` with the real codec, so a compressed body is exercised end
    /// to end rather than through a checked-in blob.
    static func zstdCompress(_ data: Data) -> Data {
        let bound = ZSTD_compressBound(data.count)
        var output = Data(count: bound)
        let written: Int = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                ZSTD_compress(destination.baseAddress, bound, source.baseAddress, data.count, 3)
            }
        }
        return output.prefix(written)
    }
}
