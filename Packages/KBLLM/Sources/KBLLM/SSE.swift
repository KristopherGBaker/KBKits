import Foundation

/// One parsed Server-Sent Events frame. `data` is the joined payload of the frame's
/// `data:` lines; `event` and `id` carry the optional fields when present.
public struct SSEEvent: Sendable, Equatable {
    public var event: String?
    public var data: String
    public var id: String?

    public init(event: String? = nil, data: String, id: String? = nil) {
        self.event = event
        self.data = data
        self.id = id
    }
}

/// A pure-Swift Server-Sent Events parser. It lives in the core, over a byte
/// `AsyncSequence`, so it does not depend on any particular HTTP client's event
/// handling: an adapter feeds it raw response bytes from whatever transport the host
/// provides. Parsing is byte-at-a-time, so a frame split across chunk boundaries is
/// reassembled correctly, and an unterminated trailing frame is discarded rather than
/// guessed at.
public enum SSE {
    /// Parse a byte stream into SSE frames. A frame is emitted only when a blank line
    /// terminates it; bytes left over at end-of-stream (a frame with no closing blank
    /// line) are discarded.
    public static func events<Bytes: AsyncSequence & Sendable>(
        from bytes: Bytes
    ) -> AsyncThrowingStream<SSEEvent, any Error> where Bytes.Element == UInt8 {
        AsyncThrowingStream { continuation in
            let task = Task {
                var accumulator = FrameAccumulator()
                var line: [UInt8] = []
                do {
                    for try await byte in bytes {
                        if byte == 0x0A { // newline terminates a line
                            if line.last == 0x0D { // strip a trailing carriage return
                                line.removeLast()
                            }
                            if let event = accumulator.consume(line: line) {
                                continuation.yield(event)
                            }
                            line.removeAll(keepingCapacity: true)
                        } else {
                            line.append(byte)
                        }
                    }
                    // End of stream: any bytes not terminated by a blank line are an
                    // incomplete frame and are dropped, never fabricated into an event.
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Accumulates SSE lines into frames. Extracted so the field-parsing rules live in one
/// place and the streaming loop stays about I/O.
private struct FrameAccumulator {
    private var dataLines: [String] = []
    private var eventType: String?
    private var lastID: String?
    private var hasField = false

    /// Feed one already-newline-stripped line. Returns a frame when the line is blank
    /// and a frame is pending, otherwise nil.
    mutating func consume(line: [UInt8]) -> SSEEvent? {
        if line.isEmpty {
            return flush()
        }
        // A leading colon marks a comment line, which is ignored.
        if line.first == 0x3A {
            return nil
        }
        let (field, value) = Self.split(line: line)
        switch field {
        case "data":
            dataLines.append(value)
            hasField = true
        case "event":
            eventType = value
            hasField = true
        case "id":
            lastID = value
            hasField = true
        default:
            break // unknown fields are ignored, per the SSE spec
        }
        return nil
    }

    private mutating func flush() -> SSEEvent? {
        guard hasField else {
            return nil // a blank line with nothing pending dispatches nothing
        }
        let event = SSEEvent(event: eventType, data: dataLines.joined(separator: "\n"), id: lastID)
        dataLines.removeAll(keepingCapacity: true)
        eventType = nil
        hasField = false
        return event
    }

    /// Split a line into field name and value at the first colon, dropping a single
    /// optional space after the colon, as the SSE grammar prescribes.
    private static func split(line: [UInt8]) -> (field: String, value: String) {
        guard let colon = line.firstIndex(of: 0x3A) else {
            return (utf8String(line[...]), "")
        }
        let field = utf8String(line[..<colon])
        var valueStart = line.index(after: colon)
        if valueStart < line.endIndex, line[valueStart] == 0x20 {
            valueStart = line.index(after: valueStart)
        }
        let value = utf8String(line[valueStart...])
        return (field, value)
    }

    /// Decode UTF-8 bytes to text. Invalid bytes yield an empty string rather than
    /// aborting the whole stream, since a malformed field should not be fatal.
    private static func utf8String(_ bytes: ArraySlice<UInt8>) -> String {
        String(bytes: bytes, encoding: .utf8) ?? ""
    }
}
