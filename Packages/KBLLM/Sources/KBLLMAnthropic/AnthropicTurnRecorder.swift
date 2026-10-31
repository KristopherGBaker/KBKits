import Foundation

/// Reassembles the assistant turn's content blocks, as raw JSON, from the streaming frames, so a
/// `pause_turn` continuation can send the paused turn back EXACTLY as the API produced it.
///
/// Raw JSON rather than decoded fields is the point: the search blocks carry provider-encrypted
/// fields (`encrypted_content` on each result, `encrypted_index` on each citation) that the API
/// checks when the turn comes back, plus whatever fields a later API version adds. A typed
/// model would drop anything it did not name; this keeps every key the start frame carried and
/// applies each delta onto it, the way the non-streaming response would have delivered the
/// block whole.
///
/// It holds `Any` values from `JSONSerialization`, so it is not `Sendable`; it lives and dies
/// inside one adapter task and never crosses an isolation boundary.
struct AnthropicTurnRecorder {
    private var blocks: [Int: [String: Any]] = [:]
    /// Tool input arrives as `input_json_delta` fragments that are only valid JSON once joined.
    private var partialInputs: [Int: String] = [:]

    /// The recorded blocks in content order, ready to be the `content` of an assistant message.
    var content: [[String: Any]] {
        blocks.keys.sorted().compactMap { blocks[$0] }
    }

    /// Fold one frame in. Only the three content-block frame types touch the turn; anything
    /// else (message start and delta, pings) is about the call, not its content.
    mutating func record(type: String, index: Int?, payload: String) {
        guard let index else { return }
        switch type {
        case "content_block_start":
            guard let block = Self.object(payload)?["content_block"] as? [String: Any] else { return }
            blocks[index] = block
        case "content_block_delta":
            guard let delta = Self.object(payload)?["delta"] as? [String: Any] else { return }
            apply(delta, to: index)
        case "content_block_stop":
            // The joined fragments replace the start frame's placeholder (`{}`) input. An empty
            // join means the block carried its input whole, so the placeholder is the input.
            guard let joined = partialInputs.removeValue(forKey: index),
                  !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let input = try? JSONSerialization.jsonObject(with: Data(joined.utf8))
            else { return }
            blocks[index]?["input"] = input
        default:
            return
        }
    }

    private mutating func apply(_ delta: [String: Any], to index: Int) {
        switch delta["type"] as? String {
        case "text_delta":
            append(delta["text"], to: "text", at: index)
        case "thinking_delta":
            append(delta["thinking"], to: "thinking", at: index)
        case "signature_delta":
            if let signature = delta["signature"] { blocks[index]?["signature"] = signature }
        case "input_json_delta":
            partialInputs[index, default: ""] += delta["partial_json"] as? String ?? ""
        case "citations_delta":
            guard let citation = delta["citation"] else { return }
            var citations = blocks[index]?["citations"] as? [Any] ?? []
            citations.append(citation)
            blocks[index]?["citations"] = citations
        default:
            return
        }
    }

    private mutating func append(_ fragment: Any?, to key: String, at index: Int) {
        guard let fragment = fragment as? String else { return }
        let existing = blocks[index]?[key] as? String ?? ""
        blocks[index]?[key] = existing + fragment
    }

    private static func object(_ payload: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any]
    }
}
