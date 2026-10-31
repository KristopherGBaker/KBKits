import Foundation
import KBLLM
import Testing
@testable import KBLLMApple

// Reads the Apple leaf's own source off disk so the closed-surface invariant is enforced by
// the suite, not by review: the adapter exposes only its struct, one init, and stream, and no
// public symbol in the target names a model lifecycle, download, or training verb. Modeled on
// the provider suite's `NeutralSurfaceTests.adaptersExposeOnlyTheStructInitAndStream`.
/// Whether the package's own sources are reachable. `#filePath` is baked in at compile
/// time, so on a device this names a build-machine path that does not exist; these assert
/// repository structure rather than runtime behavior. See `docs/ANDROID.md`.
private let appleSourcesAvailable: Bool = {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return FileManager.default.fileExists(atPath: root.appendingPathComponent("Sources").path)
}()

@Suite(.enabled(if: appleSourcesAvailable))
struct AppleSurfaceTests {
    /// The `Packages/KBLLM` root, derived from this file's location so it works from any build
    /// directory. This file lives at Tests/KBLLMAppleTests, so the root is three up.
    private var appleSources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
            .appendingPathComponent("KBLLMApple")
    }

    private func contents(of file: String) -> String {
        (try? String(contentsOf: appleSources.appendingPathComponent(file), encoding: .utf8)) ?? ""
    }

    private func swiftFiles() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: appleSources, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "swift" } ?? []
    }

    // MARK: Assertion 12 - the adapter's public surface is exactly struct + init + stream, plus
    // the four read-only forwarders of the backend's metadata (availability, capabilities,
    // quota, context size) a caller needs to act before sending.

    @Test func appleAdapterPublicSurfaceIsClosed() {
        let source = contents(of: "AppleModel.swift")
        #expect(!source.isEmpty, "expected AppleModel.swift to exist")
        let publicLines = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("public ") }
        #expect(
            publicLines.count == 7,
            "AppleModel.swift must have exactly seven public declarations, found \(publicLines)"
        )
        // Exact set equality on the declared names: a renamed, added or dropped symbol fails.
        let expectedNames: Set<String> = [
            "AppleModel", "init", "stream", "availability", "capabilities", "quotaUsage", "contextSize"
        ]
        #expect(Set(publicLines.map(symbolName(in:))) == expectedNames)
        #expect(publicLines.contains { $0.hasPrefix("public struct AppleModel") })
        #expect(publicLines.contains { $0.hasPrefix("public init(") })
        #expect(publicLines.contains { $0.hasPrefix("public func stream(") })
        // The single initializer takes exactly the injected backend seam.
        #expect(source.contains("backend: any FoundationModelBackend"))

        // No public symbol anywhere in KBLLMApple names a lifecycle/download/training verb, so
        // the adapter cannot grow a `prewarm()`, `downloadModel()`, or `finetune()` surface.
        let bannedVerbs = [
            "download", "prefetch", "warmup", "prewarm", "unload",
            "deletemodel", "train", "finetune", "adapter"
        ]
        for file in swiftFiles() {
            let publicDecls = ((try? String(contentsOf: file, encoding: .utf8)) ?? "")
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("public ") }
            for decl in publicDecls {
                let symbol = symbolName(in: decl).lowercased()
                for verb in bannedVerbs {
                    #expect(!symbol.contains(verb), "public symbol \"\(symbol)\" names banned verb \(verb)")
                }
            }
        }
    }

    /// The declared symbol name from a `public` declaration line: the token after the
    /// declaration keyword (`struct`/`func`/`var`/`enum`/`protocol`/`init`/`let`/`typealias`),
    /// stripped of any signature. `init` has no following name and returns "init".
    private func symbolName(in line: String) -> String {
        var tokens = line.split(separator: " ").map(String.init)
        // Drop leading modifiers until a declaration keyword is found.
        let keywords: Set<String> = ["struct", "func", "var", "let", "enum", "protocol", "class", "typealias"]
        while let first = tokens.first, !keywords.contains(first), !first.hasPrefix("init") {
            tokens.removeFirst()
            if tokens.isEmpty { return line }
        }
        guard let keyword = tokens.first else { return line }
        if keyword.hasPrefix("init") { return "init" }
        guard tokens.count > 1 else { return keyword }
        // The name is the next token, up to a delimiter that starts a signature.
        let raw = tokens[1]
        let name = raw.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        return String(name)
    }
}

@Suite struct PromptRenderingTests {
    /// Foundation Models has no structured channel for tool history, so it must survive into
    /// the prompt text. Dropping it makes turn two byte-identical to turn one, and the model
    /// re-requests the same tool until the round-trip bound ends the run with no answer.
    /// This was observed live on device.
    @Test func toolCallAndResultSurviveIntoThePrompt() {
        let call = ToolCallRecord(id: "c1", name: "convert", arguments: Data(#"{"celsius":100}"#.utf8))
        let request = ModelRequest(messages: [
            Message(role: .system, text: "be terse"),
            Message(role: .user, text: "convert 100c"),
            Message(role: .assistant, content: [.toolCall(call)]),
            Message(role: .tool, content: [
                .toolResult(callID: "c1", ToolResult.success(toolName: "convert", content: Data("212".utf8)))
            ])
        ])

        let prompt = PromptRendering.prompt(from: request)
        #expect(prompt.contains("convert 100c"))
        // The call, WITH its arguments, so a repeat is distinguishable from the original.
        #expect(prompt.contains("convert"))
        #expect(prompt.contains(#"{"celsius":100}"#))
        // The result the model needs in order to stop asking.
        #expect(prompt.contains("212"))
        // System turns are instructions, never part of the prompt body.
        #expect(!prompt.contains("be terse"))
        #expect(PromptRendering.instructions(from: request) == "be terse")
    }

    /// A failing tool must read as a failure, not as a successful value the model trusts.
    @Test func failingToolResultIsRenderedAsAFailure() {
        let request = ModelRequest(messages: [
            Message(role: .tool, content: [
                .toolResult(callID: "c1", ToolResult.failure(toolName: "convert", message: "bad input"))
            ])
        ])
        let prompt = PromptRendering.prompt(from: request)
        #expect(prompt.contains("failed"))
        #expect(prompt.contains("bad input"))
    }
}
