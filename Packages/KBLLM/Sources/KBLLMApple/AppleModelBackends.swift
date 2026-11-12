import Foundation
import KBLLM

// Backend factories a caller on the macOS 26 runtime floor can call with no `#available`. The
// stand-ins are declared OUTSIDE any framework guard, so the factory exists (and answers
// "unavailable") wherever the module builds; only the branch that names the live macOS 27
// backend is gated. The live Private Cloud Compute backend is also gated on the process's
// entitlement, because an unentitled request does not fail politely: it traps inside
// FoundationModels.

/// Entry points for the Apple backends that need no availability check at the call site.
public enum AppleModelBackends {
    /// Apple's Private Cloud Compute model. It answers one of three ways:
    ///
    /// - Before macOS 27 (or where FoundationModels is absent): a stand-in that reports
    ///   `.unavailable` with "Private Cloud Compute requires macOS 27 or later".
    /// - On macOS 27 when the process is not signed with the
    ///   `com.apple.developer.private-cloud-compute` entitlement: a stand-in that reports
    ///   `.unavailable` with "Private Cloud Compute needs the
    ///   com.apple.developer.private-cloud-compute entitlement".
    /// - On macOS 27 with the entitlement: the live `LivePrivateCloudComputeBackend`.
    ///
    /// Either stand-in reports no capabilities, no quota and no context size, and refuses every
    /// run with its same `.unavailable`. The OS is checked first.
    ///
    /// The entitlement is gated here because an unentitled live request traps inside
    /// FoundationModels rather than throwing. To enable the live backend, request the managed
    /// `com.apple.developer.private-cloud-compute` entitlement from Apple, add it (set to `true`)
    /// to the app's entitlements file, and sign with a provisioning profile that grants it.
    public static func privateCloudCompute() -> any FoundationModelBackend {
        privateCloudCompute(isSupported: true, isEntitled: PrivateCloudComputeEntitlement.isGranted)
    }

    /// `isSupported: false` takes the pre-27 path whatever the OS, so a test on macOS 27 can
    /// still prove the stand-in's behaviour; `isEntitled` replaces the real entitlement read, so
    /// a test can drive both macOS 27 branches from an unentitled runner.
    static func privateCloudCompute(
        isSupported: Bool,
        isEntitled: () -> Bool = PrivateCloudComputeEntitlement.isGranted
    ) -> any FoundationModelBackend {
        #if canImport(FoundationModels)
        if isSupported, #available(macOS 27, iOS 27, *) {
            guard isEntitled() else { return UnavailableFoundationModelBackend(reason: unentitledReason) }
            return LivePrivateCloudComputeBackend()
        }
        #endif
        return UnavailableFoundationModelBackend(reason: unsupportedReason)
    }

    /// Why the pre-macOS 27 stand-in is unavailable.
    static let unsupportedReason = "Private Cloud Compute requires macOS 27 or later"

    /// Why the macOS 27 stand-in for a process without the entitlement is unavailable.
    static let unentitledReason =
        "Private Cloud Compute needs the com.apple.developer.private-cloud-compute entitlement"
}

/// A backend that is not there: unavailable for `reason`, no capabilities, and a run that
/// throws the same `.unavailable` rather than attempting anything. It touches no
/// FoundationModels API (asking the live Private Cloud Compute model anything unentitled
/// traps), so it is declared outside any framework guard and answers wherever the module builds.
struct UnavailableFoundationModelBackend: FoundationModelBackend {
    let reason: String

    var availability: FoundationModelAvailability { .unavailable(reason: reason) }

    var capabilities: Set<FoundationModelCapability> { [] }

    func run(_ request: ModelRequest) -> AsyncThrowingStream<FoundationModelChunk, any Error> {
        let reason = self.reason
        return AsyncThrowingStream { $0.finish(throwing: KBLLMError.unavailable(reason: reason)) }
    }
}

/// Whether this process is signed with the Private Cloud Compute entitlement.
enum PrivateCloudComputeEntitlement {
    static let name = "com.apple.developer.private-cloud-compute"

    /// Reads this process's own signature. Only a CFBoolean `true` grants it.
    static func isGranted() -> Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return isGranted(value: SecTaskCopyValueForEntitlement(task, name as CFString, nil))
        #else
        // iOS has no public API to read a process's own entitlements, so this keeps today's
        // behaviour (macOS 27 means live). A known gap, recorded in the README.
        return true
        #endif
    }

    #if canImport(Darwin)
    /// The decision on a raw entitlement value: true only for a CFBoolean `true`. A string
    /// "true", a number 1, a missing value or a CFBoolean `false` all deny.
    static func isGranted(value: CFTypeRef?) -> Bool {
        guard let value else { return false }
        return CFGetTypeID(value) == CFBooleanGetTypeID() && CFEqual(value, kCFBooleanTrue)
    }
    #endif
}
