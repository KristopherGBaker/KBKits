#if canImport(FoundationModels)
import Foundation
import FoundationModels
import KBLLM
import Testing
@testable import KBLLMApple

// The opt-in live smoke: with `KBLLM_LIVE_APPLE=1` it constructs the real on-device backend
// and the public Private Cloud Compute factory's answer (live only when this process holds the
// entitlement, otherwise a stand-in) and reads their METADATA only (availability, capabilities,
// quota, context size). It runs no inference. Whatever the machine reports passes, as long as
// it is well-formed and the neutral capabilities match the live model's own report; a quota or
// context-size read that throws, is nil or times out is logged, never a failure. Without the
// variable the suite is disabled, so the default run touches nothing live here.

private let liveAppleEnabled = ProcessInfo.processInfo.environment["KBLLM_LIVE_APPLE"] == "1"

@Suite(.enabled(if: liveAppleEnabled))
struct LiveAppleSmokeTests {
    @Test func liveMetadataReadsWithoutInference() async {
        let onDevice = LiveFoundationModelBackend()
        expectWellFormed(onDevice.availability, "onDevice")
        if #available(macOS 27, iOS 27, *) {
            let expected = FoundationModelCapability.set(from: SystemLanguageModel.default.capabilities)
            #expect(onDevice.capabilities == expected)
        } else {
            #expect(onDevice.capabilities == [.guidedGeneration, .toolCalling])
        }
        emit("APPLE-LIVE onDevice availability=\(describe(onDevice.availability)) "
            + "capabilities=\(describe(onDevice.capabilities))")

        // Through the public factory, so an unentitled process gets the entitlement stand-in
        // (and macOS 26 the pre-27 one) instead of a live model that would trap.
        let pcc = AppleModelBackends.privateCloudCompute()
        expectWellFormed(pcc.availability, "pcc")
        if #available(macOS 27, iOS 27, *), pcc is LivePrivateCloudComputeBackend {
            let expected = FoundationModelCapability.set(from: PrivateCloudComputeLanguageModel().capabilities)
            #expect(pcc.capabilities == expected)
        } else {
            #expect(pcc is UnavailableFoundationModelBackend)
            #expect(pcc.capabilities.isEmpty)
        }
        let quota = await bounded { pcc.quotaUsage }
        let contextSize = await bounded { try await pcc.contextSize() }
        emit("APPLE-LIVE pcc availability=\(describe(pcc.availability)) "
            + "capabilities=\(describe(pcc.capabilities)) "
            + "quota=\(describeQuota(quota)) contextSize=\(describeContextSize(contextSize))")
    }

    private func expectWellFormed(_ availability: FoundationModelAvailability, _ label: String) {
        if case .unavailable(let reason) = availability {
            #expect(!reason.isEmpty, "\(label): an unavailable model must say why")
        }
    }

    private func emit(_ line: String) {
        // One whole line, written at once, so it never interleaves with the runner's output.
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    private func describe(_ availability: FoundationModelAvailability) -> String {
        switch availability {
        case .available: "available"
        case .unavailable(let reason): "unavailable:" + oneToken(reason)
        }
    }

    private func describe(_ capabilities: Set<FoundationModelCapability>) -> String {
        let ordered: [(FoundationModelCapability, String)] = [
            (.vision, "vision"), (.guidedGeneration, "guidedGeneration"),
            (.reasoning, "reasoning"), (.toolCalling, "toolCalling")
        ]
        let names = ordered.filter { capabilities.contains($0.0) }.map(\.1)
        return names.isEmpty ? "none" : names.joined(separator: ",")
    }

    private func describeQuota(_ outcome: BoundedRead<FoundationModelQuotaUsage?>) -> String {
        guard case .value(let usage) = outcome, let usage else { return "nil" }
        if usage.isLimitReached { return "reached" }
        return usage.isApproachingLimit ? "approaching" : "below"
    }

    private func describeContextSize(_ outcome: BoundedRead<Int?>) -> String {
        switch outcome {
        case .value(let size): size.map(String.init) ?? "nil"
        case .failed(let detail): "error:" + oneToken(detail)
        case .timedOut: "timeout"
        }
    }

    /// Whitespace becomes `_`, so a reason is one token and the line stays one line.
    private func oneToken(_ text: String) -> String {
        let token = String(text.map { $0.isWhitespace ? "_" : $0 })
        return token.isEmpty ? "_" : token
    }
}

/// The outcome of one metadata read bounded by a timeout.
private enum BoundedRead<Value: Sendable>: Sendable {
    case value(Value)
    case failed(String)
    case timedOut
}

/// Run one metadata read in its own task and wait on the real clock with a bound, so a read
/// that hangs (a network-backed context size, say) is reported as a timeout rather than
/// wedging the suite. The task is cancelled, not awaited, when the bound elapses.
private func bounded<Value: Sendable>(
    timeout: Duration = .seconds(20),
    _ read: @escaping @Sendable () async throws -> Value
) async -> BoundedRead<Value> {
    let box = Box<BoundedRead<Value>?>(nil)
    let task = Task {
        do {
            let value = try await read()
            box.mutate { $0 = .value(value) }
        } catch {
            box.mutate { $0 = .failed(String(describing: error)) }
        }
    }
    let finished = await waitUntil(timeout: timeout) { box.get() != nil }
    if !finished { task.cancel() }
    return box.get() ?? .timedOut
}
#endif
