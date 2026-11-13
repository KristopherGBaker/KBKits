import Foundation
import KBLLM

// Request building for `OpenAIResponsesModel`: a pure translation from a neutral request to one HTTP spec. The
// schema translation (`schemaJSON`, `strictSchemaJSON`) and the argument validation (`jsonString`) are
// `OpenAIModel`'s, so the two OpenAI wires describe a schema and refuse bad arguments identically.
extension OpenAIResponsesModel {

    // Six parameters on a builder with one call site, each a distinct value captured out of the struct before the
    // escaping closure, as on `OpenAIModel.buildRequest`.
    // swiftlint:disable:next function_parameter_count
    static func buildRequest(
        _ request: ModelRequest,
        model: String,
        secret: String,
        endpoint: String,
        extraHeaders: [String: String],
        options: Options
    ) throws -> HTTPRequestSpec {
        // Every refusal that must happen before a request leaves, the same ones `OpenAIModel` makes. OpenAI's own
        // web search tool is a different tool family this adapter does not speak, so a request asking for search is
        // refused rather than answered unsearched.
        try request.validateNeutralRules(supportsWebSearch: false)
        var body: [String: Any] = [
            "model": model,
            "stream": true,
            // Stateless: nothing is kept on OpenAI's side, the whole conversation travels each time (as on every
            // adapter), and so the reasoning has to travel too. With `store: false` reasoning items carry their
            // `encrypted_content`; the guide says it is returned by default there and that `include` still accepts
            // this legacy value, which is sent so a model or account where the default differs returns it anyway.
            "store": false,
            "include": ["reasoning.encrypted_content"],
            "input": try request.messages.flatMap(inputItems)
        ]
        let instructions = request.messages.filter { $0.role == .system }.map { OpenAIModel.joinedText($0.content) }
        if !instructions.isEmpty { body["instructions"] = instructions.joined(separator: "\n\n") }
        if !request.tools.isEmpty { body["tools"] = request.tools.map(toolJSON) }
        // Structured output is `text.format`, flat here where Chat Completions nests it under `json_schema`, with the
        // strict translation every OpenAI request shares.
        if let schema = request.responseSchema {
            body["text"] = [
                "format": [
                    "type": "json_schema",
                    "name": OpenAIModel.structuredSchemaName,
                    "strict": true,
                    "schema": OpenAIModel.strictSchemaJSON(schema)
                ]
            ]
        }
        addGenerationOptions(request.options, to: &body)
        var reasoning: [String: Any] = [:]
        if let effort = options.reasoningEffort { reasoning["effort"] = effort.rawValue }
        if let summary = options.reasoningSummary { reasoning["summary"] = summary.rawValue }
        if !reasoning.isEmpty { body["reasoning"] = reasoning }
        if let promptCacheKey = options.promptCacheKey { body["prompt_cache_key"] = promptCacheKey }
        // The headers are `OpenAIModel`'s, shared rather than copied, so the two OpenAI wires keep the same rules:
        // the adapter's own headers win over a caller's `extraHeaders` in any letter case, and an empty secret
        // sends no Authorization header at all (a keyless server, or one keyed by a caller header of its own).
        let headers = OpenAIModel.requestHeaders(secret: secret, extraHeaders: extraHeaders)
        // Sorted keys, so the same request is the same bytes in every process and the prompt cache sees one prefix,
        // and unescaped slashes, so an `encrypted_content` (base64, full of `/`) goes back as the bytes that arrived.
        let data = try AdapterPlumbing.serialize(body, options: [.sortedKeys, .withoutEscapingSlashes])
        return HTTPRequestSpec(method: .post, url: endpoint, headers: headers, body: data)
    }

    /// Sampling controls only when set, greedy as `temperature: 0` winning over a temperature or top-p, and the
    /// output limit as `max_output_tokens` (which, per the reference, counts reasoning tokens too).
    private static func addGenerationOptions(_ options: GenerationOptions, to body: inout [String: Any]) {
        let isGreedy = options.sampling == .greedy
        if isGreedy {
            body["temperature"] = 0.0
        } else if let temperature = options.temperature {
            body["temperature"] = temperature
        }
        if !isGreedy, let topP = options.topP { body["top_p"] = topP }
        if let maxOutputTokens = options.maxOutputTokens { body["max_output_tokens"] = maxOutputTokens }
    }

    /// The Responses function tool: flat (`name`, `description`, `parameters` beside `type`), where Chat Completions
    /// nests them under `function`. `strict: false` because the reference lists `strict` on every function tool and
    /// strict mode would make each optional argument a required, nullable one, which is not what the caller declared;
    /// the parameters still carry `additionalProperties: false`, as `OpenAIModel` sends them.
    static func toolJSON(_ tool: ToolDefinition) -> [String: Any] {
        [
            "type": "function",
            "name": tool.name,
            "description": tool.description,
            "parameters": tool.rawParametersJSON ?? OpenAIModel.schemaJSON(tool.parameters),
            "strict": false
        ]
    }

    /// One neutral message as Responses input items. A system message is `instructions`, not an item. An assistant
    /// turn expands to its own reasoning items first, then its text and its `function_call`s in the order the turn
    /// lists them, which is the order the model produced them; a tool turn is one `function_call_output` per result.
    /// Each assistant text carries its `phase`, which newer models ask back on every assistant message: `commentary`
    /// in a turn that calls tools (the model's words before its calls), `final_answer` in a turn that does not.
    static func inputItems(_ message: Message) throws -> [[String: Any]] {
        switch message.role {
        case .system:
            return []
        case .tool:
            return message.content.compactMap { part in
                guard case .toolResult(let callID, let result) = part else { return nil }
                return ["type": "function_call_output", "call_id": callID, "output": result.text ?? ""]
            }
        case .assistant:
            let reasoning = (message.reasoningBlocks ?? []).compactMap(reasoningItem)
            let callsTools = message.content.contains { if case .toolCall = $0 { true } else { false } }
            let phase = callsTools ? "commentary" : "final_answer"
            return try reasoning + message.content.compactMap { try assistantItem($0, phase: phase) }
        case .user:
            return [userItem(message.content)]
        }
    }

    /// A reasoning item as it came back, for an OpenAI block; nil for another provider's (Anthropic's thinking), which
    /// this API could not read.
    static func reasoningItem(_ block: ReasoningBlock) -> [String: Any]? {
        guard case let .openAIReasoning(id, encryptedContent, summary) = block else { return nil }
        return [
            "type": "reasoning",
            "id": id,
            "encrypted_content": encryptedContent,
            "summary": summary.map { ["type": "summary_text", "text": $0] }
        ]
    }

    private static func assistantItem(_ part: MessageContent, phase: String) throws -> [String: Any]? {
        switch part {
        case .text(let text):
            guard !text.isEmpty else { return nil }
            return ["type": "message", "role": "assistant", "content": text, "phase": phase]
        case .toolCall(let record):
            return [
                "type": "function_call",
                "call_id": record.id,
                "name": record.name,
                "arguments": try OpenAIModel.jsonString(from: record.arguments, toolID: record.id)
            ]
        case .toolResult, .image:
            return nil
        }
    }

    /// A text-only turn is the plain-string `content`; one with an image is the ordered list of `input_text` and
    /// `input_image` parts, the image as a base64 `data:` URL, which the reference accepts as `image_url`.
    private static func userItem(_ content: [MessageContent]) -> [String: Any] {
        guard content.contains(where: OpenAIModel.isImage) else {
            return ["type": "message", "role": "user", "content": OpenAIModel.joinedText(content)]
        }
        let parts: [[String: Any]] = content.compactMap { part in
            switch part {
            case .text(let text):
                return ["type": "input_text", "text": text]
            case .image(let data, let mimeType):
                return ["type": "input_image", "image_url": "data:\(mimeType);base64,\(data.base64EncodedString())"]
            case .toolCall, .toolResult:
                return nil
            }
        }
        return ["type": "message", "role": "user", "content": parts]
    }
}
