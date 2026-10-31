import Foundation
import KBLLM
import Testing

@Suite struct SSETests {
    @Test func twoFramesYieldTwoEventsInOrder() async throws {
        let bytes = Array("data: hello\n\ndata: world\n\n".utf8)
        let events = try await collect(SSE.events(from: byteStream([bytes])))
        #expect(events.count == 2)
        #expect(events.first?.data == "hello")
        #expect(events.last?.data == "world")
    }

    @Test func frameSplitAcrossChunkBoundaryReassembles() async throws {
        // The single message's bytes arrive in two separate chunks.
        let chunkOne = Array("data: hello ".utf8)
        let chunkTwo = Array("world\n\n".utf8)
        let events = try await collect(SSE.events(from: byteStream([chunkOne, chunkTwo])))
        #expect(events.count == 1)
        #expect(events.first?.data == "hello world")
    }

    @Test func unterminatedTrailingFrameIsDiscarded() async throws {
        // "first" is terminated by a blank line; the trailing frame has no blank line.
        let bytes = Array("data: first\n\ndata: incomplete\n".utf8)
        let events = try await collect(SSE.events(from: byteStream([bytes])))
        #expect(events.count == 1)
        #expect(events.first?.data == "first")
    }

    @Test func eventAndIdFieldsAreParsed() async throws {
        let bytes = Array("event: update\nid: 42\ndata: payload\n\n".utf8)
        let events = try await collect(SSE.events(from: byteStream([bytes])))
        #expect(events.count == 1)
        #expect(events.first?.event == "update")
        #expect(events.first?.id == "42")
        #expect(events.first?.data == "payload")
    }
}

/// A Sendable byte `AsyncSequence` built from chunks, so a message can be delivered
/// across chunk boundaries.
private func byteStream(_ chunks: [[UInt8]]) -> AsyncStream<UInt8> {
    AsyncStream { continuation in
        for chunk in chunks {
            for byte in chunk {
                continuation.yield(byte)
            }
        }
        continuation.finish()
    }
}

private func collect<S: AsyncSequence>(_ sequence: S) async throws -> [SSEEvent]
where S.Element == SSEEvent {
    var events: [SSEEvent] = []
    for try await event in sequence {
        events.append(event)
    }
    return events
}
