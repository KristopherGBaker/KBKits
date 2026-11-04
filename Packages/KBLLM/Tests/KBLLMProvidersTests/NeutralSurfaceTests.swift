import Foundation
import KBLLM
import Testing

/// Whether the package's own sources are reachable. `#filePath` is baked in at compile
/// time, so on a device this names a build-machine path that does not exist; these assert
/// repository structure rather than runtime behavior. See `docs/ANDROID.md`.
private let sourcesAvailable: Bool = {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return FileManager.default.fileExists(atPath: root.appendingPathComponent("Sources").path)
}()

@Suite(.enabled(if: sourcesAvailable))
struct NeutralSurfaceTests {
    /// The `Packages/KBLLM` root, derived from this file's location so it works from any
    /// build directory. This file lives at Tests/KBLLMProvidersTests, so the root is three up.
    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativeToSources: String) -> String {
        let url = packageRoot.appendingPathComponent("Sources").appendingPathComponent(relativeToSources)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private func labels(_ value: Any) -> Set<String> {
        Set(Mirror(reflecting: value).children.compactMap(\.label))
    }

    // MARK: Assertion 13(a) - the neutral struct surfaces are exactly pinned.

    @Test func neutralStructSurfacesArePinnedByReflection() {
        // `options` is unit 9's deliberate neutral-surface addition (temperature, max output
        // tokens, top-p), pinned here alongside the original fields so a FURTHER undeclared
        // field still fails this guard.
        // `webSearch` (request) and `webSearches` + `citations` (response) are the web search
        // unit's deliberate additions, pinned the same way. `reasoning` (message and response)
        // is the reasoning replay's (DeepSeek's thinking mode with tools).
        #expect(
            labels(ModelRequest(messages: []))
                == ["messages", "tools", "responseSchema", "options", "webSearch"]
        )
        #expect(labels(Message(role: .user, text: "x")) == ["role", "content", "reasoning", "reasoningBlocks"])
        #expect(
            labels(ModelResponse(content: ""))
                == ["content", "toolCalls", "finishReason", "usage", "webSearches", "citations", "reasoning"]
        )
        #expect(
            labels(ToolDefinition(name: "n", description: "d", parameters: .string(description: nil)))
                == ["name", "description", "parameters"]
        )
        #expect(
            labels(ToolCallRecord(id: "i", name: "n", arguments: Data()))
                == ["id", "name", "arguments"]
        )
    }

    // MARK: Assertion 13(b) - the neutral enum surfaces are frozen by an exhaustive switch.

    @Test func neutralEnumSurfacesAreFrozenByAllowlist() {
        // No `default`: adding or renaming a case fails to compile this target, exactly like
        // the target-set guard is updated deliberately when a target is added.
        let event: ModelEvent = .completed(.stop)
        switch event {
        case .contentDelta: break
        case .reasoningDelta: break
        case .toolCall: break
        // `.usage` is the FIFTH deliberate guarded-enum update (after `reasoningDelta`,
        // `schemaViolation`, `MessageContent.image` and `KBLLMError.cancelled`), enumerated
        // here explicitly so a FURTHER undeclared event still fails to compile this target.
        case .usage: break
        // The three web search events are the SIXTH deliberate guarded-enum update, enumerated
        // explicitly for the same reason.
        case .webSearchCall: break
        case .webSearchResult: break
        case .citation: break
        // `.reasoningBlock` (Anthropic's signed thinking, kept to be sent back) is the SEVENTH deliberate guarded-enum
        // update, enumerated explicitly for the same reason.
        case .reasoningBlock: break
        case .completed: break
        }
        // `.image` is the THIRD deliberate guarded-enum update (after `reasoningDelta` and
        // `schemaViolation`), so it is enumerated here EXPLICITLY, keeping no fallthrough arm so
        // a FURTHER undeclared `MessageContent` case still fails to compile this target.
        let content: MessageContent = .text("x")
        switch content {
        case .text: break
        case .toolCall: break
        case .toolResult: break
        case .image: break
        }
        // Source check: the switches above are exhaustive by ENUMERATION, never a fallthrough
        // arm. A fallthrough would silently absorb a newly added neutral case (like
        // `.reasoningDelta` was in this unit) instead of failing the build, so pin the absence
        // of that arm in this test's own source. The needle is built by concatenation so
        // neither this comment nor the check line is a false positive.
        let ownSource = (try? String(contentsOfFile: #filePath, encoding: .utf8)) ?? ""
        #expect(!ownSource.isEmpty)
        let defaultArm = "default" + ":"
        #expect(!ownSource.contains(defaultArm), "the frozen-enum switches must not use a default arm")
    }

    // MARK: Assertion 13(c1) - no retry: a single transport failure yields one attempt.

    @Test func aTransportFailureIsNotRetried() async {
        let (anth, transport) = makeAnthropic(.foreign(detail: "boom"))
        let result = await collect(anth, weatherRequest)
        #expect(result.error != nil)
        #expect(transport.openCount.get() == 1)
    }

    // MARK: Assertion 13(c2) - no caching: two identical calls open the transport twice.

    @Test func twoIdenticalCallsOpenTheTransportTwice() async {
        let (anth, transport) = makeAnthropic(.replay(Fixtures.anthropicWeather))
        _ = await collect(anth, weatherRequest)
        _ = await collect(anth, weatherRequest)
        #expect(transport.openCount.get() == 2)
    }

    // MARK: Assertion 13(c3) - no public token/cost API; the public surface is closed.

    @Test func adaptersExposeOnlyTheStructInitAndStream() {
        let cases = [
            ("KBLLMAnthropic/AnthropicModel.swift", "AnthropicModel"),
            ("KBLLMOpenAI/OpenAIModel.swift", "OpenAIModel")
        ]
        for (file, adapter) in cases {
            let contents = source(file)
            let publicLines = contents
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("public ") }
            // A public ENUM is allowed and nothing else is. The property being defended is
            // "no token or cost API, and no second way in": an enum that exists only to TYPE a
            // parameter of the one initializer adds no entry point, and the alternative is
            // taking the same value as a bare String, where a typo becomes a provider error at
            // runtime instead of a compile error. Amended when `reasoning_effort` landed, which
            // some models require set before they will use function tools at all.
            //
            // Amended again for `OutputTokenField`. The property this guard defends is that an
            // adapter exposes no API for COUNTING tokens or cost - that belongs to
            // `TokenUsage` in the core - and the substring check is a proxy for it. This enum
            // counts nothing: it selects which wire field carries an existing neutral option,
            // because OpenAI's newer models reject `max_tokens` outright while older ones and
            // LM Studio reject the new name. Named here rather than renamed around the check,
            // since dodging the substring would hide the exception instead of recording it.
            let allowedConfigurationTypes = ["OutputTokenField"]
            let configurationTypes = publicLines
                .filter { $0.hasPrefix("public enum ") }
                .filter { line in !allowedConfigurationTypes.contains { line.contains($0) } }
            // Amended for web search: an adapter may override the core's DEFAULTED capability
            // flag. It is neither a token/cost API nor a second way in (it answers a yes/no
            // the protocol already asks), so it is named here rather than moved to another
            // file where this check would not see it.
            let allowedCapabilityLines = ["public var supportsWebSearch: Bool { true }"]
            let entryPoints = publicLines
                .filter { !$0.hasPrefix("public enum ") }
                .filter { !allowedCapabilityLines.contains($0) }
            #expect(
                entryPoints.count == 3,
                "\(file) must have exactly three public entry points, found \(entryPoints)"
            )
            for line in configurationTypes {
                #expect(
                    !line.lowercased().contains("token") && !line.lowercased().contains("cost")
                        && !line.lowercased().contains("usage"),
                    "\(file) exposes a token or cost type: \(line)"
                )
            }
            #expect(entryPoints.contains { $0.hasPrefix("public struct \(adapter)") })
            #expect(entryPoints.contains { $0.hasPrefix("public init(") })
            #expect(entryPoints.contains { $0.hasPrefix("public func stream(") })
            // The single initializer takes exactly the four seam/config parameters.
            #expect(contents.contains("model: String"))
            #expect(contents.contains("credentialKey: String"))
            #expect(contents.contains("transport: any HTTPTransport"))
            #expect(contents.contains("credentials: any CredentialStore"))
        }
    }

    // MARK: Assertion 14 - the HTTPTransport non-success obligation is documented.

    @Test func httpTransportDocumentsTheNonSuccessObligation() {
        let seams = source("KBLLM/Seams.swift")
        #expect(seams.contains("httpStatus"))
        #expect(seams.lowercased().contains("non-success"))
        #expect(seams.contains("openBytes"))
    }
}
