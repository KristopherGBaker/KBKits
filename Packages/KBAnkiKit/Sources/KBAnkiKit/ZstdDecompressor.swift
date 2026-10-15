import Foundation
import libzstd

/// Decompresses a zstd frame, which is how current Anki stores the collection inside
/// an `.apkg` (`collection.anki21b`).
///
/// Streaming rather than one-shot, deliberately. `ZSTD_getFrameContentSize` returns
/// "unknown" for a frame written by a streaming compressor, which is what Anki uses,
/// so sizing a single output buffer from the header fails on exactly the files this
/// exists to read.
enum ZstdDecompressor {
    /// Decompress `data`, or throw when it is not a readable zstd frame.
    static func decompress(_ data: Data) throws(AnkiError) -> Data {
        guard !data.isEmpty else {
            throw AnkiError.unreadableArchive("the compressed collection is empty")
        }
        guard let stream = ZSTD_createDStream() else {
            throw AnkiError.databaseFailure("could not start zstd decompression")
        }
        defer { ZSTD_freeDStream(stream) }
        ZSTD_initDStream(stream)

        let outputCapacity = ZSTD_DStreamOutSize()
        var output = Data()
        var result: Result<Data, AnkiError> = .success(Data())
        // ZSTD_decompressStream returns 0 only once a frame is COMPLETE; any positive
        // value is a hint for how much more input it expects. Without tracking it, a
        // file truncated mid-frame exits the loop below simply because its input ran
        // out, and returns whatever decoded so far as a success.
        var lastCode = 0

        data.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
            guard let base = input.baseAddress else { return }
            var inBuffer = ZSTD_inBuffer(src: base, size: input.count, pos: 0)
            var chunk = [UInt8](repeating: 0, count: outputCapacity)

            while inBuffer.pos < inBuffer.size {
                var finished = false
                chunk.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) in
                    guard let outBase = out.baseAddress else { return }
                    var outBuffer = ZSTD_outBuffer(dst: outBase, size: outputCapacity, pos: 0)
                    let code = ZSTD_decompressStream(stream, &outBuffer, &inBuffer)
                    lastCode = code
                    if ZSTD_isError(code) != 0 {
                        let reason = String(cString: ZSTD_getErrorName(code))
                        result = .failure(.unreadableArchive("zstd: \(reason)"))
                        finished = true
                        return
                    }
                    output.append(contentsOf: UnsafeRawBufferPointer(start: outBase, count: outBuffer.pos))
                }
                if finished { return }
            }
        }

        switch result {
        case .failure(let error): throw error
        case .success: break
        }
        // Input exhausted with the frame still open: the file is cut short. Returning
        // the partial body instead would hand back a truncated SQLite database, which
        // fails much later with a confusing "no such table" rather than saying the
        // deck is incomplete.
        guard lastCode == 0 else {
            throw AnkiError.unreadableArchive("zstd: the compressed collection is truncated")
        }
        return output
    }
}
