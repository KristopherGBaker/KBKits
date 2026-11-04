import Foundation
import KBLLM

// Request building: a pure translation from a neutral request (plus, on a `pause_turn`
// continuation, the paused assistant turn to echo) to one HTTP spec, shaped for the model it is
// addressed to (see `AnthropicModelProfile`). In an extension of its own so the adapter's main
// file stays within the house length limits; it touches neither the transport nor the
// credential store. Schema translation lives in `AnthropicModel+Schema.swift`.

/// What a `pause_turn` continuation sends back: the paused assistant turn's content blocks,
/// exactly as received, and the code execution container the turn ran in, if it named one.
/// Holds `Any` from `JSONSerialization`, so it is not `Sendable`; it lives inside one adapter task.
struct PausedTurn {
    var content: [[String: Any]] = []
    var containerID: String?

    /// Fold in one paused call: its blocks after the earlier calls' blocks, and the container it
    /// named, else the one an earlier call named.
    mutating func append(_ parser: AnthropicResponseParser) {
        content += parser.turn.content
        containerID = parser.containerID ?? containerID
    }
}

/// The adapter's `thinking` and `effort`, carried together into the request builder.
struct AnthropicReasoningSettings: Sendable {
    var thinking: AnthropicThinking?
    var effort: AnthropicEffort?

    /// `thinking` as its own field, and `effort` inside `output_config` beside a structured request's `format`.
    func add(to body: inout [String: Any]) {
        if let thinking { body["thinking"] = thinking.json }
        if let effort {
            var config = body["output_config"] as? [String: Any] ?? [:]
            config["effort"] = effort.rawValue
            body["output_config"] = config
        }
    }
}

extension AnthropicModel {
    /// The basic search tool: direct searches, no code execution. Sent to every model the
    /// dynamic version is not documented for, and to any id this adapter cannot place.
    static let basicWebSearchToolType = "web_search_20250305"

    /// The dynamic-filtering search tool, which lets the model filter results with code before
    /// they reach its context. Sent to Sonnet and Opus 4.6 and later. The code execution it uses
    /// is the server's own, so no `code_execution` tool is declared beside it.
    static let dynamicWebSearchToolType = "web_search_20260209"

    /// The search tool version the profiled model takes.
    static func webSearchToolType(for profile: AnthropicModelProfile) -> String {
        profile.supportsDynamicWebSearch ? dynamicWebSearchToolType : basicWebSearchToolType
    }

    // Seven parameters on an internal builder with one call site, each a distinct value captured
    // out of the struct before the escaping closure. Bundling two of them into a type that
    // exists only to satisfy a count would add indirection and explain nothing.
    // swiftlint:disable:next function_parameter_count
    static func buildRequest(
        _ request: ModelRequest,
        model: String,
        secret: String,
        endpoint: String,
        promptCaching: AnthropicPromptCaching,
        reasoning: AnthropicReasoningSettings = AnthropicReasoningSettings(),
        pausedTurn: PausedTurn
    ) throws -> HTTPRequestSpec {
        let profile = AnthropicModelProfile(model)
        try validate(request, model: model, profile: profile)
        // Anthropic REQUIRES max_tokens on the wire, so it is ALWAYS emitted: the caller's
        // value when set, else `maxOutputTokensFallback`. It is not a model choice or a cap;
        // a caller asking for a long answer gets exactly what it asked for.
        var body: [String: Any] = [
            "model": model,
            "stream": true,
            "max_tokens": request.options.maxOutputTokens ?? maxOutputTokensFallback
        ]
        addSampling(request.options, to: &body, profile: profile)
        let systemText = request.messages
            .filter { $0.role == .system }
            .flatMap { $0.content }
            .compactMap { part -> String? in
                if case .text(let text) = part { return text }
                return nil
            }
            .joined(separator: "\n")
        if !systemText.isEmpty {
            // Plain string unless caching is asked for: the block form exists only to carry
            // `cache_control`, and sending it unconditionally would change the request shape
            // for every caller to no purpose.
            body["system"] = promptCaching.cachesSystemPrompt
                ? [["type": "text", "text": systemText, "cache_control": promptCaching.control]]
                : systemText
        }
        // Client tools first, then the server search tool, so a request without search sends
        // exactly the tools it always did.
        var tools = request.tools.map(toolJSON)
        if let webSearch = request.webSearch {
            tools.append(webSearchToolJSON(webSearch, profile: profile))
        }
        if !tools.isEmpty {
            body["tools"] = tools
        }
        if let schema = request.responseSchema {
            addStructuredOutput(schema, to: &body, profile: profile)
        }
        reasoning.add(to: &body)
        // Tools render before the system prompt, so with no system prompt the last tool carries
        // the breakpoint that would have covered both.
        if promptCaching.cachesSystemPrompt, systemText.isEmpty,
           var cachedTools = body["tools"] as? [[String: Any]], !cachedTools.isEmpty {
            cachedTools[cachedTools.count - 1]["cache_control"] = promptCaching.control
            body["tools"] = cachedTools
        }
        var messages = try request.messages
            .filter { $0.role != .system }
            .map(messageJSON)
        // The conversation's breakpoint moves to the newest message on every request; the
        // previous request's entry is found by looking back from it, so the history is read
        // rather than reprocessed. Placed before a paused turn is echoed: that turn is the
        // server's own content, resent unchanged.
        if promptCaching.cachesConversation {
            markLastCacheableBlock(in: &messages, control: promptCaching.control)
        }
        // A `pause_turn` continuation sends the paused assistant turn back UNCHANGED, every block
        // as received, so the API resumes the turn rather than starting a new one. This trailing
        // assistant turn is the documented continuation, not a prefill, on every model.
        if !pausedTurn.content.isEmpty {
            messages.append(["role": "assistant", "content": pausedTurn.content])
        }
        // A turn that ran server-side code (dynamic search filtering does) ran it in a
        // container, and its continuation must name the same one.
        if let containerID = pausedTurn.containerID {
            body["container"] = containerID
        }
        body["messages"] = messages
        // A search request echoes provider-encrypted fields (`encrypted_content`,
        // `encrypted_index`) that are base64 and full of `/`. Default serialization escapes
        // those as `\/`, which is the same JSON string but not the same bytes, so a search
        // request writes them verbatim. Every other request keeps the bytes it always had.
        // Signed thinking blocks are sent back as received too.
        let verbatim = request.webSearch != nil || !pausedTurn.content.isEmpty
            || request.messages.contains(where: carriesAnthropicReasoning)
        // Keys are sorted because a Swift dictionary's order follows a hash seed that changes
        // with every process: unsorted, the same request would have different bytes after a
        // relaunch, and a prompt-cache entry (a byte-prefix match) would never be read across
        // launches or between separate runs sharing one prompt.
        let data = try serialize(body, options: verbatim ? [.sortedKeys, .withoutEscapingSlashes] : [.sortedKeys])
        return HTTPRequestSpec(
            method: .post,
            url: endpoint,
            headers: [
                "x-api-key": secret,
                "anthropic-version": "2023-06-01",
                "content-type": "application/json"
            ],
            body: data
        )
    }

    /// Every refusal that must happen before a request leaves, in one place.
    private static func validate(_ request: ModelRequest, model: String, profile: AnthropicModelProfile) throws {
        // RULING 19: a request cannot ask for BOTH structured output and caller tools. On the
        // legacy route the synthetic structured tool would sit among the caller's tools, so
        // honouring one silently would drop the other; reject it before dispatch instead,
        // naming both fields. Kept on the structured-outputs route too, so one request means
        // the same thing on every model.
        if request.responseSchema != nil, !request.tools.isEmpty {
            throw KBLLMError.invalidRequest(
                field: "responseSchema+tools",
                reason: "responseSchema and tools cannot be combined in one request"
            )
        }
        // Search results come back cited, and the API rejects citations alongside a structured
        // output format, so the two cannot share a request. Refused rather than quietly
        // unsearched: the caller would get an answer it believes was researched.
        if request.responseSchema != nil, request.webSearch != nil {
            throw KBLLMError.invalidRequest(
                field: "responseSchema+webSearch",
                reason: "responseSchema and webSearch cannot be combined: search results carry citations, "
                    + "which structured output rejects. Search in one request, then ask for the "
                    + "structured answer in a second one that includes the findings"
            )
        }
        // A request ending on the assistant's turn asks the model to continue it (prefill),
        // which current models answer with a 400. Refused here, naming the model, so the caller
        // sees why instead of an opaque status.
        if profile.rejectsPrefill, request.messages.last(where: { $0.role != .system })?.role == .assistant {
            throw KBLLMError.invalidRequest(
                field: "messages",
                reason: "the last message is the assistant's (a prefill), which \(model) does not accept; "
                    + "end the conversation on a user turn"
            )
        }
        try request.webSearch?.validate()
        // A schema no provider could honour (a negative `minItems`) is refused here, before
        // the transport is opened, by the one core check every adapter shares.
        try request.responseSchema?.validate()
        for tool in request.tools { try tool.parameters.validate() }
    }

    /// Temperature and top-p are OMITTED when unset so Anthropic's own defaults hold; only
    /// `max_tokens` gets a KBLLM-supplied fallback. When set they are HINTS, sent only as far as
    /// the model takes them rather than refused: a model that removed sampling gets neither, and
    /// one that takes only one per request gets the temperature when both were given. Dropping
    /// a hint changes how the answer is sampled, never whether the request succeeds.
    ///
    /// Greedy sampling is the same kind of hint: `temperature: 0` alone on a model that takes
    /// sampling parameters (it wins over a temperature or top-p also set, so no `top_p` is sent
    /// beside it), and nothing at all on one that removed them.
    private static func addSampling(
        _ options: GenerationOptions,
        to body: inout [String: Any],
        profile: AnthropicModelProfile
    ) {
        if options.sampling == .greedy {
            if profile.sampling != .none { body["temperature"] = 0.0 }
            return
        }
        switch profile.sampling {
        case .none:
            return
        case .oneOf:
            if let temperature = options.temperature {
                body["temperature"] = temperature
            } else if let topP = options.topP {
                body["top_p"] = topP
            }
        case .any:
            if let temperature = options.temperature { body["temperature"] = temperature }
            if let topP = options.topP { body["top_p"] = topP }
        }
    }

    /// Whether a structured request to this model rides the legacy synthetic tool rather than
    /// `output_config.format`. The adapter asks this too, to tell the parser what to unwrap.
    static func usesStructuredTool(_ request: ModelRequest, profile: AnthropicModelProfile) -> Bool {
        request.responseSchema != nil && !profile.supportsStructuredOutputs
    }

    /// Ask for structured output the way this model accepts it.
    ///
    /// Structured outputs (`output_config.format`, 4.5 and later): the API constrains decoding to
    /// the schema and the answer arrives as JSON text in ordinary text blocks. Forced
    /// `tool_choice` is NOT used: the 5.x models reject it with a 400, and an unconstrained tool
    /// input was free to come back off-schema.
    ///
    /// The legacy route, for a model older than structured outputs or an id this adapter cannot
    /// place (a local server speaking the Messages format): one synthetic tool, `strict`, offered
    /// with `tool_choice: auto` and never forced. The parser unwraps its input into content and
    /// holds any text back until it knows whether the tool was called.
    private static func addStructuredOutput(
        _ schema: JSONSchema,
        to body: inout [String: Any],
        profile: AnthropicModelProfile
    ) {
        if profile.supportsStructuredOutputs {
            body["output_config"] = [
                "format": ["type": "json_schema", "schema": schemaJSON(schema, dialect: .structuredOutput)]
            ]
            return
        }
        body["tools"] = [[
            "name": structuredToolName,
            "description": "Return the final answer by calling this tool once with the complete "
                + "structured JSON. Do not answer in text.",
            "input_schema": schemaJSON(schema, dialect: .strictTool),
            "strict": true
        ]]
        body["tool_choice"] = ["type": "auto"]
    }

    /// The documented `web_search` server tool entry, in the version `profile`'s model takes:
    /// `max_uses` only when the caller set one, and the one domain list the caller filled
    /// (validation has already refused both).
    static func webSearchToolJSON(_ options: WebSearchOptions, profile: AnthropicModelProfile) -> [String: Any] {
        var entry: [String: Any] = ["type": webSearchToolType(for: profile), "name": "web_search"]
        if let maxUses = options.maxUses { entry["max_uses"] = maxUses }
        if !options.allowedDomains.isEmpty { entry["allowed_domains"] = options.allowedDomains }
        if !options.blockedDomains.isEmpty { entry["blocked_domains"] = options.blockedDomains }
        return entry
    }

    private static func toolJSON(_ tool: ToolDefinition) -> [String: Any] {
        [
            "name": tool.name,
            "description": tool.description,
            "input_schema": schemaJSON(tool.parameters)
        ]
    }

    private static func messageJSON(_ message: Message) throws -> [String: Any] {
        // A tool turn becomes a user turn carrying tool_result blocks, which is how the
        // Messages API models a tool's output.
        let role = message.role == .tool ? "user" : message.role.rawValue
        var blocks = try message.content.map(contentBlock)
        // An assistant turn's thinking goes back unchanged, ahead of what it led to, as the model returned it.
        if message.role == .assistant, let reasoning = message.reasoningBlocks {
            blocks = reasoning.compactMap(reasoningBlock) + blocks
        }
        return ["role": role, "content": blocks]
    }

    /// Another provider's block (an OpenAI Responses reasoning item) is nil: Anthropic could not read it and would
    /// refuse the unknown block type, so a turn first made elsewhere goes back without it.
    private static func reasoningBlock(_ block: ReasoningBlock) -> [String: Any]? {
        switch block {
        case let .thinking(text, signature): ["type": "thinking", "thinking": text, "signature": signature]
        case let .redacted(data): ["type": "redacted_thinking", "data": data]
        case .openAIReasoning: nil
        }
    }

    /// Whether a message carries a block this adapter sends back.
    static func carriesAnthropicReasoning(_ message: Message) -> Bool {
        (message.reasoningBlocks ?? []).contains { reasoningBlock($0) != nil }
    }

    private static func contentBlock(_ part: MessageContent) throws -> [String: Any] {
        switch part {
        case .text(let text):
            return ["type": "text", "text": text]
        case .toolCall(let record):
            let input = try jsonObject(from: record.arguments, toolID: record.id)
            return ["type": "tool_use", "id": record.id, "name": record.name, "input": input]
        case .toolResult(let callID, let result):
            return ["type": "tool_result", "tool_use_id": callID, "content": result.text ?? ""]
        case .image(let data, let mimeType):
            // Anthropic carries an image as its own block with a base64 `source`, keeping the
            // MIME type in a SEPARATE `media_type` field (unlike OpenAI's inline `data:` URI).
            // `.map` over `content` preserves the neutral order, so a text-plus-image turn
            // renders the blocks in the order the caller listed them.
            return [
                "type": "image",
                "source": ["type": "base64", "media_type": mimeType, "data": data.base64EncodedString()]
            ]
        }
    }

    /// Put `control` on the last block of the last message that can carry it. An empty text block
    /// cannot (the API rejects `cache_control` there), so the walk goes back past one; a message
    /// with nothing eligible leaves the request unmarked rather than marking an older turn.
    private static func markLastCacheableBlock(in messages: inout [[String: Any]], control: [String: Any]) {
        guard let last = messages.indices.last,
              var blocks = messages[last]["content"] as? [[String: Any]] else { return }
        let eligible = blocks.lastIndex { block in
            block["type"] as? String != "text" || !((block["text"] as? String) ?? "").isEmpty
        }
        guard let index = eligible else { return }
        blocks[index]["cache_control"] = control
        messages[last]["content"] = blocks
    }

    /// Parse tool-call arguments into JSON for the request body. Invalid JSON is caught
    /// HERE, before dispatch, as `.invalidRequest` naming the offending tool call, rather
    /// than being sent as bytes the provider would reject.
    private static func jsonObject(from data: Data, toolID: String) throws -> Any {
        do {
            return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw KBLLMError.invalidRequest(
                field: "toolCall(\(toolID)).arguments",
                reason: "tool call arguments must be valid JSON before dispatch"
            )
        }
    }

    private static func serialize(
        _ object: [String: Any],
        options: JSONSerialization.WritingOptions
    ) throws -> Data {
        do {
            return try JSONSerialization.data(withJSONObject: object, options: options)
        } catch {
            throw KBLLMError.invalidRequest(field: "body", reason: "request body could not be serialized")
        }
    }
}
