import Foundation
import KBLLM
import KBLLMRuntime
import KBLLMTesting
import Testing

// The runtime loop tests. Every fixture that can block waits on a gate the test owns, and
// every run under test executes in an unstructured `Task` observed under a bounded wait, so
// no mutation named in the contract can wedge the suite.

private let toolID = "c1"

/// A session over the given model. The loop reads no clock at all, so nothing here has to
/// inject one to stay deterministic and offline.
private func session(
    _ model: any LanguageModel,
    tools: ToolBox = ToolBox(tools: []),
    maxRoundTrips: Int = 8
) -> AgentSession {
    AgentSession(model: model, tools: tools, maxToolRoundTrips: maxRoundTrips)
}

/// The aggregation of the run-level events, folded the same way from either path so the
/// collected result and the streamed events can be compared directly.
private struct Aggregate: Equatable {
    var content = ""
    var reasoning = ""
    var toolCalls: [ToolCallRecord] = []
    var toolResults: [ToolResult] = []
    var usage: [TokenUsage] = []
    var finish: FinishReason?
}

private func fold(_ events: [RunEvent]) -> Aggregate {
    var aggregate = Aggregate()
    for event in events {
        switch event {
        case .contentDelta(let delta): aggregate.content += delta
        case .reasoningDelta(let delta): aggregate.reasoning += delta
        case .toolInvoked(let call): aggregate.toolCalls.append(call)
        case .toolReturned(let result): aggregate.toolResults.append(result)
        // Collected as a LIST, not a running total: these tests assert the run reports one
        // usage event per model call, which a total would hide.
        case .usage(let reported): aggregate.usage.append(reported)
        case .finished(let reason): aggregate.finish = reason
        }
    }
    return aggregate
}

private func fromResult(_ result: RunResult) -> Aggregate {
    Aggregate(
        content: result.content,
        reasoning: result.reasoning,
        toolCalls: result.toolCalls,
        toolResults: result.toolResults,
        finish: result.finishReason
    )
}

private func collect(_ stream: AsyncThrowingStream<RunEvent, any Error>) async throws -> [RunEvent] {
    var events: [RunEvent] = []
    for try await event in stream { events.append(event) }
    return events
}

/// Collect a stream under a bounded wait, releasing gates through the data path on timeout.
private func collectBounded(
    _ stream: AsyncThrowingStream<RunEvent, any Error>,
    release: @escaping @Sendable () async -> Void
) async -> [RunEvent] {
    let events = Box<[RunEvent]>([])
    let done = Box(false)
    let task = Task {
        do {
            for try await event in stream { events.mutate { $0.append(event) } }
        } catch {}
        done.mutate { $0 = true }
    }
    if await waitUntil({ done.get() }) == false {
        await release()
        _ = await task.value
    }
    return events.get()
}

/// Whether any message in the history carries an error `.toolResult` part.
private func hasErrorToolResult(in messages: [Message]) -> Bool {
    messages.contains { message in
        message.content.contains { part in
            if case .toolResult(_, let result) = part { return result.isError }
            return false
        }
    }
}

private func plainTool(_ name: String, invoke: @escaping @Sendable (Data) async -> ToolResult) -> Tool {
    Tool(
        definition: ToolDefinition(
            name: name,
            description: "",
            parameters: .object(properties: [:], required: [], description: nil)
        ),
        invoke: invoke
    )
}

// MARK: - Assertion 2 fixtures (collected equals streamed).

private func checkPlainText() async throws {
    let turns: [[ModelEvent]] = [[.contentDelta("hi"), .completed(.stop)]]
    let runCalls = Box(0)
    let streamCalls = Box(0)
    let runSession = session(ScriptedModel(turns: turns, calls: runCalls))
    let streamSession = session(ScriptedModel(turns: turns, calls: streamCalls))

    let result = try await runSession.run(ModelRequest(messages: []))
    let events = try await collect(streamSession.stream(ModelRequest(messages: [])))
    #expect(fromResult(result) == fold(events))
    #expect(result.content == "hi")
    #expect(result.finishReason == .stop)
    #expect(runCalls.get() == 1)
    #expect(streamCalls.get() == 1)
}

private func checkToolThenAnswer(toolName: String, tool: Tool, expectError: Bool) async throws {
    let call = ToolCallRecord(id: toolID, name: toolName, arguments: Data("{}".utf8))
    let turns: [[ModelEvent]] = [
        [.toolCall(call), .completed(.toolCalls)],
        [.contentDelta("done"), .completed(.stop)]
    ]
    let runCalls = Box(0)
    let streamCalls = Box(0)
    let tools = ToolBox(tools: [tool])
    let runSession = session(ScriptedModel(turns: turns, calls: runCalls), tools: tools)
    let streamSession = session(ScriptedModel(turns: turns, calls: streamCalls), tools: tools)

    let result = try await runSession.run(ModelRequest(messages: []))
    let events = try await collect(streamSession.stream(ModelRequest(messages: [])))
    #expect(fromResult(result) == fold(events))
    #expect(result.content == "done")
    #expect(result.toolResults.first?.isError == expectError)
    #expect(runCalls.get() == 2)
    #expect(streamCalls.get() == 2)

    // Payloads are read by case pattern-match, not string matching.
    let invoked = events.compactMap { event -> ToolCallRecord? in
        if case .toolInvoked(let record) = event { return record }
        return nil
    }
    #expect(invoked.first?.name == toolName)
}

private func checkRunawayBound() async throws {
    let call = ToolCallRecord(id: toolID, name: "loop", arguments: Data("{}".utf8))
    func make(_ gate: Gate, _ calls: Box<Int>, _ counter: Box<Int>) -> AgentSession {
        session(
            GatedRunawayModel(call: call, budget: 5, gate: gate, calls: calls),
            tools: ToolBox(tools: [countingTool(named: "loop", counter: counter)]),
            maxRoundTrips: 3
        )
    }
    let runGate = Gate()
    let streamGate = Gate()
    let runSession = make(runGate, Box(0), Box(0))
    let streamSession = make(streamGate, Box(0), Box(0))

    let runResult = Box<RunResult?>(nil)
    let runDone = Box(false)
    let runTask = Task {
        let produced = try? await runSession.run(ModelRequest(messages: []))
        runResult.mutate { $0 = produced }
        runDone.mutate { $0 = true }
    }
    if await waitUntil({ runDone.get() }) == false {
        await runGate.open()
        _ = await runTask.value
    }
    let events = await collectBounded(streamSession.stream(ModelRequest(messages: []))) {
        await streamGate.open()
    }

    let result = try #require(runResult.get())
    #expect(fromResult(result) == fold(events))
    #expect(result.toolCalls.count == 3)
    #expect(result.finishReason == .toolCalls)
}

// MARK: - Assertion 7 trial.

private func runOneConcurrencyTrial() async throws {
    let log = OrderLog()
    let zebraStarted = Gate()
    let alphaDone = Gate()
    let zebra = plainTool("zebra") { _ in
        await log.record("zebra-start")
        await zebraStarted.open()
        await alphaDone.wait()
        await log.record("zebra-finish")
        return ToolResult.success(toolName: "zebra", content: Data("z".utf8))
    }
    let alpha = plainTool("alpha") { _ in
        await zebraStarted.wait()
        await log.record("alpha-start")
        await alphaDone.open()
        await log.record("alpha-finish")
        return ToolResult.success(toolName: "alpha", content: Data("a".utf8))
    }
    let turns: [[ModelEvent]] = [
        [
            .toolCall(ToolCallRecord(id: "1", name: "zebra", arguments: Data("{}".utf8))),
            .toolCall(ToolCallRecord(id: "2", name: "alpha", arguments: Data("{}".utf8))),
            .completed(.toolCalls)
        ],
        [.contentDelta("done"), .completed(.stop)]
    ]
    let agent = session(ScriptedModel(turns: turns), tools: ToolBox(tools: [zebra, alpha]))

    let result = Box<RunResult?>(nil)
    let done = Box(false)
    let task = Task {
        let produced = try? await agent.run(ModelRequest(messages: []))
        result.mutate { $0 = produced }
        done.mutate { $0 = true }
    }
    if await waitUntil({ done.get() }) == false {
        await alphaDone.open()
        _ = await task.value
        Issue.record("dispatch serialized: alpha never overlapped zebra")
        return
    }
    let runResult = try #require(result.get())

    let entries = await log.entries
    let zebraStart = try #require(entries.firstIndex(of: "zebra-start"))
    let alphaStart = try #require(entries.firstIndex(of: "alpha-start"))
    let alphaFinish = try #require(entries.firstIndex(of: "alpha-finish"))
    let zebraFinish = try #require(entries.firstIndex(of: "zebra-finish"))
    #expect(zebraStart < alphaStart, "zebra-start must precede alpha-start")
    #expect(alphaFinish < zebraFinish, "alpha must finish before zebra")

    // History tool results are in CALL order [zebra, alpha], not completion order.
    #expect(runResult.toolResults.map(\.toolName) == ["zebra", "alpha"])
}

@Suite struct AgentSessionTests {
    // MARK: Assertion 2 - collected equals streamed across a strong fixture set.

    @Test func collectedEqualsStreamedAcrossCases() async throws {
        try await checkPlainText()
        try await checkToolThenAnswer(
            toolName: "ok",
            tool: countingTool(named: "ok", counter: Box(0)),
            expectError: false
        )
        try await checkToolThenAnswer(toolName: "bad", tool: failingTool(named: "bad"), expectError: true)
        try await checkRunawayBound()
    }

    // MARK: Reasoning reaches the caller and never becomes the answer.

    @Test func reasoningIsForwardedToTheCallerAndKeptOutOfContent() async throws {
        // A scripted model's turn cursor advances as it is consumed, so each path gets its
        // own instance and both therefore start from the same first turn.
        let turns: [[ModelEvent]] = [[
            .reasoningDelta("weighing "),
            .reasoningDelta("options"),
            .contentDelta("the answer"),
            .completed(.stop)
        ]]
        let request = ModelRequest(messages: [Message(role: .user, text: "q")])

        // A caller watching the run must SEE the reasoning: a reasoning model can think for
        // a long time, and a session that emits nothing looks exactly like a hang.
        let streamed = try await collect(session(ScriptedModel(turns: turns)).stream(request))
        #expect(streamed.contains(.reasoningDelta("weighing ")))
        #expect(streamed.contains(.reasoningDelta("options")))

        let result = try await session(ScriptedModel(turns: turns)).run(request)
        #expect(result.reasoning == "weighing options")
        // Reasoning is NOT the answer, so it must never join the content...
        #expect(result.content == "the answer")
        // ...and must never be fed back into history as assistant text.
        let assistantText = result.messages
            .filter { $0.role == .assistant }
            .flatMap(\.content)
            .compactMap { part -> String? in
                if case .text(let text) = part { return text }
                return nil
            }
            .joined()
        #expect(!assistantText.contains("weighing"))
        #expect(assistantText == "the answer")
        // It rides on the assistant message's own `reasoning`, for the adapters that replay it.
        #expect(result.messages.last { $0.role == .assistant }?.reasoning == "weighing options")

        // The collected form stays a total fold of the streamed events.
        #expect(fold(streamed) == fromResult(result))
    }

    @Test func eachToolTurnsReasoningIsInTheNextRequestsHistory() async throws {
        let requests = Box<[ModelRequest]>([])
        let call = ToolCallRecord(id: "c1", name: "echo", arguments: Data("{}".utf8))
        let model = ScriptedModel(turns: [
            [.reasoningDelta("call echo"), .toolCall(call), .completed(.toolCalls)],
            [.contentDelta("done"), .completed(.stop)]
        ], requests: requests)
        let tools = ToolBox(tools: [countingTool(named: "echo", counter: Box(0))])
        let result = try await AgentSession(model: model, tools: tools).run(
            ModelRequest(messages: [Message(role: .user, text: "q")])
        )
        let second = try #require(requests.get().dropFirst().first)
        let assistant = try #require(second.messages.first { $0.role == .assistant })
        #expect(assistant.reasoning == "call echo")
        // A turn that streamed no reasoning carries none, rather than an empty string.
        #expect(result.messages.last?.reasoning == nil)
    }

    // MARK: Assertion 3 - round-trip bound stops a runaway model.

    @Test func boundStopsARunawayModel() async {
        let call = ToolCallRecord(id: toolID, name: "loop", arguments: Data("{}".utf8))
        let gate = Gate()
        let counter = Box(0)
        let agent = session(
            GatedRunawayModel(call: call, budget: 5, gate: gate, calls: Box(0)),
            tools: ToolBox(tools: [countingTool(named: "loop", counter: counter)]),
            maxRoundTrips: 3
        )
        let events = await collectBounded(agent.stream(ModelRequest(messages: []))) {
            await gate.open()
        }
        let invocations = events.filter { if case .toolInvoked = $0 { return true } else { return false } }
        #expect(invocations.count == 3, "tool must be invoked exactly 3 times, saw \(invocations.count)")
        #expect(counter.get() == 3, "counting tool must run exactly 3 times, ran \(counter.get())")
        if case .finished(let reason) = events.last {
            #expect(reason == .toolCalls)
        } else {
            Issue.record("run must emit a terminal .finished event, last was \(String(describing: events.last))")
        }
    }

    // MARK: Assertion 4 - cancellation terminates a suspended run.

    @Test func cancellationTerminatesSuspendedRun() async {
        let probe = ToolCallRecord(id: toolID, name: "probe", arguments: Data("{}".utf8))
        let gate = Gate()
        let probeCount = Box(0)
        let agent = session(
            ScriptedModel(behaviors: [
                .events([.toolCall(probe), .completed(.toolCalls)]),
                // Turn 2 yields a second probe call THEN parks: a loop that honors
                // cancellation throws before dispatching it, so probe count stays 1; a loop
                // that ignores cancellation would dispatch it and push the count past 1.
                .emitThenPark([.toolCall(probe)], gate)
            ]),
            tools: ToolBox(tools: [countingTool(named: "probe", counter: probeCount)])
        )

        let done = Box(false)
        let task = Task {
            _ = try? await agent.run(ModelRequest(messages: []))
            done.mutate { $0 = true }
        }
        // Wait until turn 1 dispatched the probe and the run suspended in turn 2.
        let suspended = await waitUntil({ probeCount.get() == 1 })
        #expect(suspended, "run should reach the parked turn with probe count 1")
        #expect(probeCount.get() == 1)

        task.cancel()
        let completed = await waitUntil({ done.get() })
        if completed == false {
            // Cancellation ignored: release the gate so the suite is not wedged, then join.
            await gate.open()
            _ = await task.value
            Issue.record("cancelled run did not complete; termination required a gate release")
        }
        #expect(completed, "run task must complete promptly after cancellation")
        #expect(probeCount.get() == 1, "no tool may run after cancellation")
    }

    // MARK: Assertion 5 - unknown-tool result equals the projection for many names.

    @Test func unknownToolResultMatchesProjectionForManyNames() async throws {
        let names = ["nope", "zzz", "we\"ird%🙂"]
        var contents: [Data] = []
        for name in names {
            let call = ToolCallRecord(id: toolID, name: name, arguments: Data("{}".utf8))
            let agent = session(ScriptedModel(turns: [
                [.toolCall(call), .completed(.toolCalls)],
                [.contentDelta("ok"), .completed(.stop)]
            ]))
            let result = try await agent.run(ModelRequest(messages: []))
            let toolResult = try #require(result.toolResults.first)
            #expect(toolResult.isError == true)
            #expect(toolResult.content == ToolResult.errorContent(for: .unknownTool(name: name)))
            #expect(hasErrorToolResult(in: result.messages))
            contents.append(toolResult.content)
        }
        #expect(Set(contents).count == names.count)
        let contrast = ToolResult.errorContent(for: .invalidRequest(field: "x", reason: "y"))
        #expect(!contents.contains(contrast))
    }

    // MARK: Assertion 6 - failing tool becomes an error result fed back.

    @Test func failingToolBecomesErrorResultFedBack() async throws {
        let call = ToolCallRecord(id: toolID, name: "bad", arguments: Data("{}".utf8))
        let requests = Box<[ModelRequest]>([])
        let agent = session(
            ScriptedModel(
                turns: [
                    [.toolCall(call), .completed(.toolCalls)],
                    [.contentDelta("done"), .completed(.stop)]
                ],
                requests: requests
            ),
            tools: ToolBox(tools: [failingTool(named: "bad")])
        )
        let result = try await agent.run(ModelRequest(messages: []))
        #expect(result.toolResults.first?.isError == true)
        let secondRequest = try #require(requests.get().dropFirst().first)
        #expect(hasErrorToolResult(in: secondRequest.messages))
    }

    // MARK: Assertion 7 - deterministic order under overlapping, reverse-completing dispatch.

    @Test func toolResultsKeepCallOrderUnderConcurrency() async throws {
        for _ in 0..<5 {
            try await runOneConcurrencyTrial()
        }
    }
}
