#if canImport(FoundationModels)
import Foundation
import FoundationModels
import KBLLM

// The on-device FoundationModels-backed `FoundationModelBackend`, plus the run path it shares
// with the Private Cloud Compute backend. It and its sibling live files are compiled in only
// where `canImport(FoundationModels)` holds; the adapter and the seam protocol are declared
// OUTSIDE this guard, so the module still vends `AppleModel` and `FoundationModelBackend`
// where the framework is absent and only these leaf implementations are compiled out. The
// real session op is exercised by the hand-run `Tools/KBLLMSmoke` harness, never by the
// suite, because real inference is non-deterministic and machine dependent.

/// Wraps the real `SystemLanguageModel`: maps availability, runs a request against a FRESH
/// `LanguageModelSession` (never cached across calls, since a session carries conversation
/// state the caller already owns), streams its cumulative snapshots, and captures a model
/// tool call by giving the session tools whose bodies record their arguments and throw a
/// sentinel that ends the turn.
public struct LiveFoundationModelBackend: FoundationModelBackend {
    private let model: SystemLanguageModel
    private let responder: any FoundationModelResponder
    private let metadata: LiveModelMetadata?

    /// Defaults to `SystemLanguageModel.default`, the general-purpose on-device model, so a
    /// caller need not pick one; a specialized model is a single argument. The response
    /// operation is the real session op by default.
    public init(model: SystemLanguageModel = .default) {
        self.model = model
        self.responder = SessionResponder { tools, instructions in
            LanguageModelSession(model: model, tools: tools, instructions: instructions)
        }
        self.metadata = nil
    }

    /// Inject a fake response operation so a test can observe the `GenerationSchema` actually
    /// supplied to it without running on-device inference, and optionally scripted metadata so
    /// the backend can be driven through `AppleModel` whatever this machine's model reports.
    /// Internal, so the public surface is unchanged and only a `@testable` test reaches it.
    init(
        model: SystemLanguageModel = .default,
        responder: any FoundationModelResponder,
        metadata: LiveModelMetadata? = nil
    ) {
        self.model = model
        self.responder = responder
        self.metadata = metadata
    }

    /// The on-device model's capabilities: mapped from the framework's own report on macOS 27,
    /// and on macOS 26 what that model has always had (guided generation and tool calling; the
    /// 26 framework takes no image input at all).
    public var capabilities: Set<FoundationModelCapability> {
        if let metadata { return metadata.capabilities() }
        if #available(macOS 27, iOS 27, *) {
            return FoundationModelCapability.set(from: model.capabilities)
        }
        return [.guidedGeneration, .toolCalling]
    }

    /// Not reported (`nil`) unless scripted, so `AppleModel` dispatches on-device requests
    /// unchecked, exactly as before this seam existed, and the framework's own limit (mapped
    /// from `contextSizeExceeded`) is the backstop. Forwarding the 27 model's size would let
    /// the character-count estimate refuse a request the on-device model would have accepted.
    public func contextSize() async throws -> Int? {
        try await metadata?.contextSize()
    }

    /// The on-device model is unmetered.
    public var quotaUsage: FoundationModelQuotaUsage? {
        metadata?.quotaUsage()
    }

    public var availability: FoundationModelAvailability {
        if let metadata { return metadata.availability() }
        switch model.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            return .unavailable(reason: Self.describe(reason))
        @unknown default:
            return .unavailable(reason: "unavailable")
        }
    }

    /// Map the framework's reason onto a stable string so a caller can distinguish a
    /// machine-cannot outcome from a request-wrong one, and so the reason survives into the
    /// typed `KBLLMError.unavailable`.
    private static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible: return "deviceNotEligible"
        case .appleIntelligenceNotEnabled: return "appleIntelligenceNotEnabled"
        case .modelNotReady: return "modelNotReady"
        @unknown default: return "unavailable"
        }
    }

    public func run(_ request: ModelRequest) -> AsyncThrowingStream<FoundationModelChunk, any Error> {
        LiveRun.run(request, responder: responder)
    }
}

/// The one run path BOTH live backends share (on-device and Private Cloud Compute), so tool
/// capture, schema compilation, image decoding and error mapping are written once. It decodes
/// every `.image` part before the responder is called, so an undecodable image is refused
/// without any session, and it maps the framework's errors onto `KBLLMError` before they
/// reach `AppleModel`.
enum LiveRun {
    /// The schema root name used when a request carries a `responseSchema`. The framework wants
    /// a named root; the value is not otherwise significant.
    private static let structuredRootName = "structured_response"

    /// Map a request's neutral sampling controls onto FoundationModels `GenerationOptions` at
    /// the ONE construction site, so both the plain and the schema-constrained response ops
    /// carry the same values. The FoundationModels type is qualified because KBLLM vends its
    /// own neutral `GenerationOptions`; the request is taken whole rather than naming the
    /// neutral type, since the module and its `KBLLM` namespace enum share a name. An unset
    /// knob stays nil so the framework's own default holds, and `topP` becomes nucleus sampling
    /// (`SamplingMode.random(probabilityThreshold:)`, which the SDK confirms IS top-p), while a
    /// nil `topP` fabricates no sampling mode.
    ///
    /// Greedy sampling becomes `SamplingMode.greedy` and WINS over a `topP` or `temperature`
    /// also set: neither is passed beside it, since both only shape a random draw greedy
    /// decoding never makes.
    private static func makeGenerationOptions(
        for request: ModelRequest
    ) -> FoundationModels.GenerationOptions {
        let options = request.options
        if options.sampling == .greedy {
            return FoundationModels.GenerationOptions(
                samplingMode: .greedy,
                temperature: nil,
                maximumResponseTokens: options.maxOutputTokens
            )
        }
        return FoundationModels.GenerationOptions(
            samplingMode: options.topP.map {
                FoundationModels.GenerationOptions.SamplingMode.random(probabilityThreshold: $0)
            },
            temperature: options.temperature,
            maximumResponseTokens: options.maxOutputTokens
        )
    }

    static func run(
        _ request: ModelRequest,
        responder: any FoundationModelResponder
    ) -> AsyncThrowingStream<FoundationModelChunk, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // Every image, in message order, decoded up front: a picture the backend
                    // cannot read is refused here rather than silently dropped.
                    let images = try LiveImageDecoding.decodeImages(in: request)
                    let capture = ToolCapture()
                    // `Tool` is qualified: KBLLM also vends a `Tool` value type, so the
                    // FoundationModels protocol must be named explicitly to disambiguate.
                    let tools: [any FoundationModels.Tool] = try request.tools.map {
                        try CapturingTool(definition: $0, capture: capture)
                    }
                    // A structured request compiles its neutral schema into a runtime
                    // `GenerationSchema` (the same recursive renderer the tools use) and hands it
                    // to the response op, so the on-device model constrains its answer to it.
                    let schema = try request.responseSchema.map {
                        try GenerationSchema(
                            root: renderDynamicSchema(named: Self.structuredRootName, from: $0),
                            dependencies: []
                        )
                    }
                    do {
                        for try await snapshot in responder.streamResponse(
                            to: ResponderPrompt(text: PromptRendering.prompt(from: request), images: images),
                            instructions: PromptRendering.instructions(from: request),
                            tools: tools,
                            schema: schema,
                            options: Self.makeGenerationOptions(for: request)
                        ) {
                            // Each yielded value is the cumulative answer-so-far; the adapter
                            // diffs consecutive snapshots into deltas.
                            continuation.yield(.snapshot(snapshot))
                        }
                        continuation.finish()
                    } catch {
                        // A captured tool call ENDS the turn: the response op surfaces the
                        // sentinel throw here. Translate it into a neutral toolCall chunk so the
                        // adapter can emit a `toolCalls` finish and `AgentSession` dispatches the
                        // real tool; any other error is a genuine failure, mapped and passed on.
                        if let captured = capture.value {
                            continuation.yield(.toolCall(
                                name: captured.name,
                                id: captured.id,
                                argumentsJSON: captured.json
                            ))
                            continuation.finish()
                        } else {
                            continuation.finish(throwing: LiveErrorMapping.map(error))
                        }
                    }
                } catch {
                    continuation.finish(throwing: LiveErrorMapping.map(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// The response operation, behind a seam so a scripted fake can observe what the live backend
/// actually supplies (the `GenerationSchema`, the options, the decoded images) without running
/// inference. The default is the real session op; a test substitutes a recorder. It yields
/// cumulative content-snapshot strings (a structured answer's snapshots are its `jsonString`),
/// which the adapter diffs into deltas. The prompt carries the rendered text and every
/// `.image` part of the request, decoded, in message order.
protocol FoundationModelResponder: Sendable {
    func streamResponse(
        to prompt: ResponderPrompt,
        instructions: String?,
        tools: [any FoundationModels.Tool],
        schema: GenerationSchema?,
        options: FoundationModels.GenerationOptions
    ) -> AsyncThrowingStream<String, any Error>
}

/// The real response operation: builds a FRESH `LanguageModelSession` per call (never cached,
/// since a session carries conversation state the caller already owns) through `makeSession`,
/// which names the model (on-device or Private Cloud Compute), and streams its cumulative
/// snapshots, choosing the schema-constrained op when a schema is supplied. Each decoded image
/// joins the prompt as an `Attachment` on macOS 27. Not exercised by the suite (real inference
/// is nondeterministic and machine dependent); the seam lets a fake stand in for it.
struct SessionResponder: FoundationModelResponder {
    let makeSession: @Sendable ([any FoundationModels.Tool], Instructions?) -> LanguageModelSession

    func streamResponse(
        to prompt: ResponderPrompt,
        instructions: String?,
        tools: [any FoundationModels.Tool],
        schema: GenerationSchema?,
        options: FoundationModels.GenerationOptions
    ) -> AsyncThrowingStream<String, any Error> {
        let makeSession = self.makeSession
        return AsyncThrowingStream { continuation in
            let task = Task {
                let session = makeSession(tools, instructions.map { Instructions($0) })
                do {
                    let fullPrompt = try Self.prompt(prompt.text, images: prompt.images)
                    if let schema {
                        for try await snapshot in session.streamResponse(
                            to: fullPrompt,
                            schema: schema,
                            options: options
                        ) {
                            continuation.yield(snapshot.content.jsonString)
                        }
                    } else {
                        for try await snapshot in session.streamResponse(to: fullPrompt, options: options) {
                            continuation.yield(snapshot.content)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The prompt text, with each decoded image attached after it on macOS 27. The macOS 26
    /// framework has no attachment type, so an image there is refused rather than dropped;
    /// `AppleModel` never sends one, because no 26 model reports `.vision`.
    private static func prompt(_ text: String, images: [DecodedImage]) throws -> Prompt {
        guard !images.isEmpty else { return Prompt(text) }
        guard #available(macOS 27, iOS 27, *) else {
            throw KBLLMError.invalidRequest(
                field: "content.image",
                reason: "image input needs the vision capability, which needs macOS 27 or later"
            )
        }
        return Prompt {
            text
            for image in images {
                Attachment(image.cgImage)
            }
        }
    }
}

/// The sentinel a capturing tool throws to END the turn once it has recorded its arguments.
/// A `ToolDefinition` has no executable body, so the adapter cannot run a tool; it captures
/// the call and hands it to the caller's `AgentSession` instead.
private struct ToolCaptureSentinel: Error {}

/// A captured model tool call: its name, a deterministic id, and its argument JSON.
private struct CapturedCall: Sendable {
    let name: String
    let id: String
    let json: String
}

/// Holds the arguments of the first captured tool call. Reference-typed and lock-guarded so
/// the tool body (run by FM) and the drain loop share one record safely.
private final class ToolCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var capturedName: String?
    private var capturedJSON: String = ""
    private var counter = 0

    func record(name: String, json: String) {
        lock.lock()
        defer { lock.unlock() }
        // Only the first capture matters: the sentinel ends the turn on the first call.
        guard capturedName == nil else { return }
        counter += 1
        capturedName = name
        capturedJSON = json
    }

    /// The captured call plus a deterministic id (a counter, never a random/clock value, so
    /// the unit stays free of RNG and wall-clock spellings).
    var value: CapturedCall? {
        lock.lock()
        defer { lock.unlock() }
        guard let capturedName else { return nil }
        return CapturedCall(name: capturedName, id: "call_\(counter)", json: capturedJSON)
    }
}

/// An FM `Tool` whose `Arguments` is `GeneratedContent` and whose `parameters` is built from
/// a `DynamicGenerationSchema`, so a runtime `JSONSchema` (no compile-time `@Generable` type)
/// is expressible. Its body records the arguments and throws the sentinel: it never executes,
/// because the caller owns the tool loop.
private final class CapturingTool: FoundationModels.Tool, @unchecked Sendable {
    typealias Arguments = GeneratedContent
    typealias Output = GeneratedContent

    let name: String
    let description: String
    let parameters: GenerationSchema
    private let capture: ToolCapture

    init(definition: ToolDefinition, capture: ToolCapture) throws {
        self.name = definition.name
        self.description = definition.description
        self.parameters = try GenerationSchema(
            root: renderDynamicSchema(named: definition.name, from: definition.parameters),
            dependencies: []
        )
        self.capture = capture
    }

    func call(arguments: GeneratedContent) async throws -> GeneratedContent {
        capture.record(name: name, json: arguments.jsonString)
        throw ToolCaptureSentinel()
    }
}

/// Render a neutral `JSONSchema` as a `DynamicGenerationSchema` FM can consume. Shared by the
/// tool `parameters` and the structured `responseSchema` paths so nested objects, arrays, every
/// `required` list, and every node description are translated once and identically.
private func renderDynamicSchema(named name: String, from schema: JSONSchema) -> DynamicGenerationSchema {
    switch schema {
    case .object(let properties, let required, let description):
        let props = properties.map { key, value in
            DynamicGenerationSchema.Property(
                name: key,
                description: value.schemaDescription,
                schema: renderDynamicSchema(named: key, from: value),
                isOptional: !required.contains(key)
            )
        }
        return DynamicGenerationSchema(name: name, description: description, properties: props)
    case .array(let items, _, let minItems):
        // The array's `minItems` becomes the framework's own minimum element count, so the
        // on-device model is constrained to it while generating; `nil` passes no minimum. The
        // post-decode conformance check in `AppleModel` still enforces it either way.
        return DynamicGenerationSchema(
            arrayOf: renderDynamicSchema(named: name, from: items),
            minimumElements: minItems
        )
    case .string(let description, let choices):
        // A string's `choices` become the framework's own string choice, so the model can only
        // generate one of them. The post-decode conformance check still enforces them.
        guard let choices else { return DynamicGenerationSchema(type: String.self) }
        return DynamicGenerationSchema(name: name, description: description, anyOf: choices)
    case .integer:
        return DynamicGenerationSchema(type: Int.self)
    case .number:
        return DynamicGenerationSchema(type: Double.self)
    case .boolean:
        return DynamicGenerationSchema(type: Bool.self)
    }
}
#endif
