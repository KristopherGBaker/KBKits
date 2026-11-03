import KBLLM

/// The collected outcome of a whole run: the aggregated assistant text, every tool call
/// and tool result in the order they happened, why the run stopped, and the final
/// conversation history the loop built. It is a value so a caller can hand it across an
/// async boundary; the streaming form (`AgentSession.stream`) exposes the same
/// information incrementally.
public struct RunResult: Sendable, Equatable {
    public var content: String

    /// The model's reasoning, kept SEPARATE from `content` so it is never mistaken for the
    /// answer. It is collected rather than discarded so the collected form stays a total fold
    /// of the streamed events. In `messages` each turn's reasoning rides on its own assistant
    /// message (`Message.reasoning`), never in its content.
    public var reasoning: String
    public var toolCalls: [ToolCallRecord]
    public var toolResults: [ToolResult]
    public var finishReason: FinishReason?
    public var messages: [Message]

    /// What the WHOLE run consumed: the field-wise sum over every model call it made, or
    /// nil when no call reported anything. The per-call breakdown is on the streamed
    /// `RunEvent.usage`; a collected result has no stream to carry it, so it carries the
    /// total, the same way `content` carries the concatenation rather than the deltas.
    public var usage: TokenUsage?

    public init(
        content: String,
        reasoning: String = "",
        toolCalls: [ToolCallRecord],
        toolResults: [ToolResult],
        finishReason: FinishReason?,
        messages: [Message],
        usage: TokenUsage? = nil
    ) {
        self.content = content
        self.reasoning = reasoning
        self.toolCalls = toolCalls
        self.toolResults = toolResults
        self.finishReason = finishReason
        self.messages = messages
        self.usage = usage
    }
}

/// An agentic session: it drives the model, dispatches the tools the model asks for, and
/// feeds their results back until the model stops or the round-trip bound is hit. It is a
/// value (`Sendable`) so it can be shared and re-run; each `run`/`stream` starts a fresh
/// loop from the request it is handed.
public struct AgentSession: Sendable {
    public let model: any LanguageModel
    public let tools: ToolBox

    /// The hard ceiling on tool-dispatch rounds. It exists because a model can ask for a
    /// tool on every turn FOREVER: without a bound a buggy or adversarial model would
    /// drive a runaway loop that never terminates, so the loop stops itself here.
    public let maxToolRoundTrips: Int

    // The session deliberately holds NO clock. It never sleeps and never reads time, so
    // taking one would be dead surface that every caller has to supply and that would
    // wrongly imply the loop consumes time. `RetryMiddleware` is the only thing here that
    // waits, and it takes its own `ClockSource`.
    public init(
        model: any LanguageModel,
        tools: ToolBox = ToolBox(tools: []),
        maxToolRoundTrips: Int = 8
    ) {
        self.model = model
        self.tools = tools
        self.maxToolRoundTrips = maxToolRoundTrips
    }

    /// The collected form of a run. Folding the SAME event production the streaming form
    /// exposes is what stops the two from drifting apart: there is one loop, so the
    /// collected result can never disagree with the events a caller saw on `stream`.
    public func run(_ request: ModelRequest) async throws -> RunResult {
        var content = ""
        var reasoning = ""
        var toolCalls: [ToolCallRecord] = []
        var toolResults: [ToolResult] = []
        var finishReason: FinishReason?
        var usage: TokenUsage?
        let messages = try await drive(request) { event in
            switch event {
            case .contentDelta(let delta): content += delta
            case .reasoningDelta(let delta): reasoning += delta
            case .toolInvoked(let call): toolCalls.append(call)
            case .toolReturned(let result): toolResults.append(result)
            case .usage(let reported): usage = (usage ?? TokenUsage(inputTokens: 0, outputTokens: 0)) + reported
            case .finished(let reason): finishReason = reason
            }
        }
        return RunResult(
            content: content,
            reasoning: reasoning,
            toolCalls: toolCalls,
            toolResults: toolResults,
            finishReason: finishReason,
            messages: messages,
            usage: usage
        )
    }

    /// The streaming primitive. The collected `run` is derived from this same production,
    /// so the two cannot diverge.
    public func stream(_ request: ModelRequest) -> AsyncThrowingStream<RunEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    _ = try await drive(request) { event in
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The single loop both forms run. It emits every `RunEvent` through `emit` and
    /// returns the final history, so `run` folds and `stream` yields the identical
    /// production.
    private func drive(
        _ request: ModelRequest,
        emit: (RunEvent) async -> Void
    ) async throws -> [Message] {
        var messages = request.messages
        var roundTrips = 0

        while true {
            try Task.checkCancellation()

            let turnRequest = ModelRequest(
                messages: messages,
                tools: tools.definitions,
                responseSchema: request.responseSchema,
                // The caller's sampling controls, `maxOutputTokens` above all: dropped here, a
                // long structured answer was cut off at the adapter's fallback limit and then
                // failed as a schema violation, whatever limit the caller had asked for.
                options: request.options,
                // Carried into every turn so a session run is refused by a model that cannot
                // search, and searches on one that can, exactly as a direct call would.
                webSearch: request.webSearch
            )

            var turnText = ""
            var turnReasoning = ""
            var turnCalls: [ToolCallRecord] = []
            var turnFinish: FinishReason?
            for try await event in model.stream(turnRequest) {
                switch event {
                case .contentDelta(let delta):
                    turnText += delta
                    await emit(.contentDelta(delta))
                case .reasoningDelta(let delta):
                    // Reasoning is forwarded but never joins `turnText`, which becomes the
                    // assistant message's content; it rides on that message's `reasoning`
                    // instead, for the adapters that must send it back (DeepSeek with tools).
                    // Not forwarding it would put a caller back where the adapters started: a
                    // reasoning model can think for a long time before its first answer
                    // token, and a session that emits nothing meanwhile looks like a hang.
                    turnReasoning += delta
                    await emit(.reasoningDelta(delta))
                case .toolCall(let call):
                    turnCalls.append(call)
                case .usage(let reported):
                    // Forwarded per call rather than accumulated: see `RunEvent.usage`.
                    await emit(.usage(reported))
                case .webSearchCall, .webSearchResult, .citation:
                    // Search activity has no `RunEvent` case yet: the search ran inside the
                    // provider call, its answer arrives as `contentDelta` above and its count
                    // in `usage`. A caller that needs the sources or citations streams the
                    // model directly.
                    break
                case .completed(let reason):
                    turnFinish = reason
                }
            }
            // A parked model whose stream is cancelled mid-await unblocks by finishing, so
            // re-check here: a cancelled run must terminate through cancellation rather
            // than fall through and start another turn.
            try Task.checkCancellation()

            var assistantParts: [MessageContent] = []
            if !turnText.isEmpty { assistantParts.append(.text(turnText)) }
            for call in turnCalls { assistantParts.append(.toolCall(call)) }
            messages.append(Message(
                role: .assistant, content: assistantParts, reasoning: turnReasoning.isEmpty ? nil : turnReasoning
            ))

            for call in turnCalls {
                await emit(.toolInvoked(call))
            }

            if turnCalls.isEmpty {
                await emit(.finished(turnFinish ?? .stop))
                return messages
            }

            let dispatched = await dispatchInCallOrder(turnCalls)
            for (call, result) in dispatched {
                messages.append(Message(role: .tool, content: [.toolResult(callID: call.id, result)]))
                await emit(.toolReturned(result))
            }

            roundTrips += 1
            if roundTrips >= maxToolRoundTrips {
                await emit(.finished(turnFinish ?? .toolCalls))
                return messages
            }
        }
    }

    /// Dispatch a turn's tool calls WITHOUT gratuitous serialization (they run
    /// concurrently in a task group) yet return results in the model's CALL order. The
    /// reorder is deliberate: appending in completion order would make the conversation
    /// history nondeterministic across runs, because which tool finishes first is a race,
    /// so the same inputs could yield a different history each time.
    private func dispatchInCallOrder(
        _ calls: [ToolCallRecord]
    ) async -> [(ToolCallRecord, ToolResult)] {
        let box = tools
        let indexed = await withTaskGroup(of: (Int, ToolResult).self) { group in
            for (index, call) in calls.enumerated() {
                group.addTask {
                    (index, await Self.invoke(call, in: box))
                }
            }
            var slots = [ToolResult?](repeating: nil, count: calls.count)
            for await (index, result) in group {
                slots[index] = result
            }
            return slots
        }
        return calls.enumerated().map { offset, call in
            let result = indexed[offset]
                ?? ToolResult(erroring: .unknownTool(name: call.name), toolName: call.name)
            return (call, result)
        }
    }

    /// Run one tool. An unknown tool is a recoverable dispatch outcome, not a transport
    /// failure, so it becomes an error `ToolResult` via the projection seam rather than a
    /// throw; a registered tool that fails already returns its own error result.
    private static func invoke(_ call: ToolCallRecord, in box: ToolBox) async -> ToolResult {
        guard let tool = box.tool(named: call.name) else {
            return ToolResult(erroring: .unknownTool(name: call.name), toolName: call.name)
        }
        return await tool.invoke(call.arguments)
    }
}
