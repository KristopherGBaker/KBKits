import Foundation
import KBLLM

// Request building, in an extension rather than the struct body: it is a self-contained
// pure translation from a neutral request to one HTTP spec, and keeping it here would put
// the type past the house type-body limit.
extension OpenAIModel {

    // Nine parameters on a builder with one call site, each a distinct value captured
    // out of the struct before the escaping closure. Bundling two of them into a type that
    // exists only to satisfy a count would add indirection and explain nothing.
    // swiftlint:disable:next function_parameter_count
    static func buildRequest(
        _ request: ModelRequest,
        model: String,
        secret: String,
        endpoint: String,
        extraHeaders: [String: String],
        reasoningEffort: ReasoningEffort?,
        outputTokenField: OutputTokenField,
        promptCacheKey: String? = nil,
        replaysReasoning: Bool = false,
        thinking: ThinkingSwitch? = nil
    ) throws -> HTTPRequestSpec {
        var body: [String: Any] = [
            "model": model,
            "stream": true,
            // A streaming Chat Completions call reports NOTHING about what it consumed unless
            // asked: usage arrives in a final, choice-less frame only when this is set. It is
            // sent unconditionally because a caller cannot opt into billing information it was
            // never offered, and a server that does not implement it ignores the key.
            "stream_options": ["include_usage": true]
        ]
        // Server-side web search is not something Chat Completions offers, so a request that
        // asks for it is refused rather than answered without searching, which would hand the
        // caller stale knowledge dressed as a researched answer.
        if request.webSearch != nil {
            throw KBLLMError.invalidRequest(
                field: "webSearch",
                reason: "this model does not support server-side web search (supportsWebSearch is false)"
            )
        }
        // RULING 19: a request cannot ask for BOTH structured output and caller tools. OpenAI
        // could only satisfy one, so honouring the other silently would drop what the caller
        // asked for; reject it before dispatch instead, naming both fields.
        if request.responseSchema != nil, !request.tools.isEmpty {
            throw KBLLMError.invalidRequest(
                field: "responseSchema+tools",
                reason: "responseSchema and tools cannot be combined in one request"
            )
        }
        // A schema no provider could honour (a negative `minItems`) is refused here, before
        // the transport is opened, by the one core check every adapter shares.
        try request.responseSchema?.validate()
        for tool in request.tools { try tool.validate() }
        if !request.tools.isEmpty {
            body["tools"] = request.tools.map(toolJSON)
        }
        // A structured request carries the schema on the wire as `response_format.json_schema`
        // (verified against LM Studio): the answer then arrives as ordinary content, so nothing
        // else in the response path changes.
        if let schema = request.responseSchema {
            body["response_format"] = [
                "type": "json_schema",
                "json_schema": [
                    "name": structuredSchemaName,
                    "strict": true,
                    "schema": strictSchemaJSON(schema)
                ]
            ]
        }
        // Sampling controls ride the body only when the caller set them: an unset knob emits
        // NO key, so OpenAI's own default holds rather than a value KBLLM invented. OpenAI has
        // no required output-token field, so `max_tokens` is likewise omitted unless asked for.
        //
        // Greedy is `temperature: 0`, sent the way a caller's temperature always is (this
        // adapter forwards it to every model), and it wins over a temperature or top-p also
        // set: a nucleus cut around an argmax pick changes nothing, so no `top_p` goes with it.
        let options = request.options
        let isGreedy = options.sampling == .greedy
        if isGreedy {
            body["temperature"] = 0.0
        } else if let temperature = options.temperature {
            body["temperature"] = temperature
        }
        if let maxOutputTokens = options.maxOutputTokens {
            body[outputTokenField.rawValue] = maxOutputTokens
        }
        if !isGreedy, let topP = options.topP { body["top_p"] = topP }
        if let reasoningEffort { body["reasoning_effort"] = reasoningEffort.rawValue }
        if let thinking { body["thinking"] = ["type": thinking.rawValue] }
        // Only when the caller asked: an absent key is the body this adapter always sent.
        if let promptCacheKey { body["prompt_cache_key"] = promptCacheKey }
        body["messages"] = try request.messages.flatMap { try messageJSON($0, replaysReasoning: replaysReasoning) }
        // Sorted keys, so the same request is the same bytes in every process (a Swift dictionary's order is
        // per-process): a provider caching prompt prefixes (OpenAI, DeepSeek) and a test comparing two requests see
        // one stable body.
        let data = try AdapterPlumbing.serialize(body, options: [.sortedKeys])
        let headers = requestHeaders(secret: secret, extraHeaders: extraHeaders)
        return HTTPRequestSpec(method: .post, url: endpoint, headers: headers, body: data)
    }

    /// The request's headers: the caller's, then the adapter's own, which win on a collision in
    /// any letter case (HTTP header names are case-insensitive, so `authorization` would otherwise
    /// ride beside `Authorization` and the transport would pick one): a caller cannot replace the
    /// Authorization header built from the credential it just resolved, nor the content type. An
    /// EMPTY secret sends no Authorization header at all, rather than a bare `Bearer `: that is how
    /// a keyless server is reached, or one that takes its key in a header of its own (then the
    /// caller's `Authorization`, if it passes one, is the only one sent).
    static func requestHeaders(secret: String, extraHeaders: [String: String]) -> [String: String] {
        var own = ["content-type": "application/json"]
        if !secret.isEmpty { own["Authorization"] = "Bearer \(secret)" }
        let ownNames = Set(own.keys.map { $0.lowercased() })
        var headers = extraHeaders.filter { !ownNames.contains($0.key.lowercased()) }
        headers.merge(own) { _, adapter in adapter }
        return headers
    }

    static func toolJSON(_ tool: ToolDefinition) -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": tool.name,
                "description": tool.description,
                "parameters": tool.rawParametersJSON ?? schemaJSON(tool.parameters)
            ]
        ]
    }

    /// The schema as `strict: true` requires it: every property listed in `required`, with the
    /// ones the caller left optional made NULLABLE instead.
    ///
    /// Strict mode has no way to say "this property may be absent", so a schema with an
    /// optional property cannot be sent as written. It can be said exactly, though: the
    /// property is always present and may be null, which is the same statement about the world
    /// and is what OpenAI's own guidance prescribes. Callers were already relying on this
    /// shape without being able to express it, prompting the model for "a reading, or null if
    /// not applicable" and decoding into an optional.
    ///
    /// Promoting them to plain required WITHOUT the null would be the silent version of this:
    /// it would force the model to invent a value for a field the caller said might not exist.
    static func strictSchemaJSON(_ schema: JSONSchema) -> [String: Any] {
        switch schema {
        case .object(let properties, let required, _):
            var node = schemaJSON(schema)
            let requiredNames = Set(required)
            node["properties"] = properties.reduce(into: [String: Any]()) { result, entry in
                var child = strictSchemaJSON(entry.value)
                if !requiredNames.contains(entry.key) {
                    // `["string", "null"]` rather than `"string"`: the union IS the optionality.
                    child["type"] = [entry.value.jsonType, "null"]
                    // An `enum` is checked on its own, so the null the union admits must be
                    // listed too, or strict mode could never send the property's absence.
                    if let choices = entry.value.choices {
                        child["enum"] = choices.map { $0 as Any } + [NSNull()]
                    }
                }
                result[entry.key] = child
            }
            // Every property, because strict mode's `required` is the property list or nothing.
            // The caller's own order is kept and the promoted ones appended, so a schema that
            // was already fully required serializes exactly as it did before this translation
            // existed.
            node["required"] = required + properties.keys.filter { !requiredNames.contains($0) }.sorted()
            return node
        case .array(let items, _, _):
            // `schemaJSON` already carries the array's own `minItems`; only the items need
            // the strict translation, and an optional array keeps its minimum when the
            // enclosing object turns its `type` into the nullable union.
            var node = schemaJSON(schema)
            node["items"] = strictSchemaJSON(items)
            return node
        default:
            return schemaJSON(schema)
        }
    }

    static func schemaJSON(_ schema: JSONSchema) -> [String: Any] {
        var node: [String: Any] = ["type": schema.jsonType]
        if let description = schema.schemaDescription {
            node["description"] = description
        }
        switch schema {
        case .object(let properties, let required, _):
            node["properties"] = properties.mapValues(schemaJSON)
            node["required"] = required
            // Required by `strict: true` on EVERY object, not just the root, and a 400 from
            // OpenAI when absent. It was missing because the structured path was verified
            // against LM Studio, which does not enforce it, so the gap was invisible locally
            // and total against the real API.
            //
            // Emitted for tool parameters too, where strict mode is not requested. It is
            // merely stricter there: the model is told not to invent arguments the tool never
            // declared, which is what the caller meant by listing them.
            node["additionalProperties"] = false
        case .array(let items, _, let minItems):
            node["items"] = schemaJSON(items)
            // Sent whenever the caller set one, 0 included; absent otherwise, so a schema
            // with no minimum serializes exactly as it did before the keyword existed.
            if let minItems { node["minItems"] = minItems }
        case .string(_, let choices):
            // Absent when unset, so a schema without choices serializes exactly as before.
            if let choices { node["enum"] = choices }
        default:
            break
        }
        return node
    }

    /// Translate one neutral message into the Chat Completions message array. A single
    /// neutral turn can expand to several wire messages (an assistant `tool_calls` message
    /// plus its text), which is why this returns an array the caller flat-maps.
    ///
    /// `replaysReasoning` (`OpenAIModel(replaysReasoning:)`) adds an assistant message's reasoning as
    /// `reasoning_content`; no other role ever carries it.
    static func messageJSON(_ message: Message, replaysReasoning: Bool = false) throws -> [[String: Any]] {
        switch message.role {
        case .tool:
            return try message.content.compactMap(toolResultMessage)
        case .assistant:
            let reasoning = replaysReasoning ? message.reasoning : nil
            let extras = toolCallExtras(message.reasoningBlocks)
            return try [assistantMessage(message.content, reasoning: reasoning, extras: extras)]
        default:
            // A turn carrying an image cannot flatten to a plain string: Chat Completions
            // takes multimodal content as an ORDERED ARRAY of parts, so the text and the
            // image ride as sibling parts in the neutral order the caller listed them, which
            // is part of what the model sees. A text-only turn stays the plain-string form so
            // nothing about the existing wire changes when no image is present.
            if message.content.contains(where: isImage) {
                let parts = message.content.compactMap(userContentPart)
                return [["role": message.role.rawValue, "content": parts]]
            }
            let text = joinedText(message.content)
            return [["role": message.role.rawValue, "content": text]]
        }
    }

    /// Whether a part is an image, used to decide between the plain-string and the ordered
    /// multimodal-array shape for a user or system turn.
    static func isImage(_ part: MessageContent) -> Bool {
        if case .image = part { return true }
        return false
    }

    /// Render one neutral part as a Chat Completions content part, PRESERVING order. Text
    /// becomes a `text` part; an image becomes an `image_url` part whose URL is a `data:` URI
    /// with the MIME type inline and the bytes base64-encoded, exactly the shape verified
    /// against a vision model. Tool calls and tool results never appear in a user or system
    /// turn, so they map to nil and are dropped by the caller's `compactMap`.
    static func userContentPart(_ part: MessageContent) -> [String: Any]? {
        switch part {
        case .text(let text):
            return ["type": "text", "text": text]
        case .image(let data, let mimeType):
            return [
                "type": "image_url",
                "image_url": ["url": "data:\(mimeType);base64,\(data.base64EncodedString())"]
            ]
        case .toolCall, .toolResult:
            return nil
        }
    }

    /// `reasoning`, when not empty, rides as `reasoning_content`, exactly the text the model streamed, so a provider
    /// that checks or caches it gets back the bytes it sent.
    /// Each tool call's `extra_content` as it came back (`ReasoningBlock.toolCallExtra`), by call id.
    static func toolCallExtras(_ blocks: [ReasoningBlock]?) -> [String: Any] {
        var extras: [String: Any] = [:]
        for case let .toolCallExtra(callID, json) in blocks ?? [] {
            if let object = try? JSONSerialization.jsonObject(with: Data(json.utf8), options: .fragmentsAllowed) {
                extras[callID] = object
            }
        }
        return extras
    }

    /// A tool call's `extras` entry (Gemini's thought signature) goes back on it as `extra_content`, unchanged.
    static func assistantMessage(
        _ content: [MessageContent], reasoning: String? = nil, extras: [String: Any] = [:]
    ) throws -> [String: Any] {
        var toolCalls: [[String: Any]] = []
        for part in content {
            if case .toolCall(let record) = part {
                // Validate arguments are JSON here (see `jsonString`), then carry them as
                // the wire's argument STRING.
                let arguments = try jsonString(from: record.arguments, toolID: record.id)
                var call: [String: Any] = [
                    "id": record.id,
                    "type": "function",
                    "function": ["name": record.name, "arguments": arguments]
                ]
                if let extra = extras[record.id] { call["extra_content"] = extra }
                toolCalls.append(call)
            }
        }
        var message: [String: Any] = ["role": "assistant", "content": joinedText(content)]
        if !toolCalls.isEmpty {
            message["tool_calls"] = toolCalls
        }
        if let reasoning, !reasoning.isEmpty {
            message["reasoning_content"] = reasoning
        }
        return message
    }

    static func toolResultMessage(_ part: MessageContent) throws -> [String: Any]? {
        guard case .toolResult(let callID, let result) = part else { return nil }
        return ["role": "tool", "tool_call_id": callID, "content": result.text ?? ""]
    }

    static func joinedText(_ content: [MessageContent]) -> String {
        content
            .compactMap { part -> String? in
                if case .text(let text) = part { return text }
                return nil
            }
            .joined(separator: "\n")
    }

    /// Validate tool-call arguments as JSON and return them as the wire STRING OpenAI
    /// expects. Invalid JSON is caught HERE, before dispatch, as `.invalidRequest` naming
    /// the offending tool call, rather than being sent as bytes the provider would reject.
    static func jsonString(from data: Data, toolID: String) throws -> String {
        do {
            _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw KBLLMError.invalidRequest(
                field: "toolCall(\(toolID)).arguments",
                reason: "tool call arguments must be valid JSON before dispatch"
            )
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
