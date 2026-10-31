// swift-tools-version: 6.2
import CompilerPluginSupport
import Foundation
import PackageDescription

// KBLLM: a provider-neutral LLM client for Swift, built to survive being ported
// off Apple platforms (Swift for Android) and to be written largely by coding
// agents under human review.
//
// The module split is the load-bearing decision:
//   KBLLM         value types + protocols. NO URLSession, Keychain, Combine, or
//                 OSLog; every platform-specific capability is a seam. This is
//                 the target that has to cross to Android intact.
//   KBLLMMacros   @Tool / @Schema. swift-syntax is quarantined here so the core
//                 stays cheap to build and easy to port.
//   KBLLMTesting  fakes and transcript replay, so agent-written tests are
//                 deterministic and offline.
//   KBLLMRuntime  the agentic session loop, tool dispatch, and the LanguageModel
//                 middleware chain. Depends on the core, never the reverse.
//
// The provider adapters land next; they depend on this core, never the reverse.
let package = Package(
    name: "KBLLM",
    platforms: [
        .macOS(.v26),
        .iOS(.v26)
    ],
    products: [
        .library(name: "KBLLM", targets: ["KBLLM"]),
        .library(name: "KBLLMRuntime", targets: ["KBLLMRuntime"]),
        .library(name: "KBLLMTesting", targets: ["KBLLMTesting"]),
        .library(name: "KBLLMAnthropic", targets: ["KBLLMAnthropic"]),
        .library(name: "KBLLMOpenAI", targets: ["KBLLMOpenAI"]),
        .library(name: "KBLLMURLSession", targets: ["KBLLMURLSession"]),
        .library(name: "KBLLMApple", targets: ["KBLLMApple"])
    ],
    dependencies: [
        // Widened past 601 rather than pinned to it: a consumer that also depends on
        // mlx-swift-lm cannot resolve otherwise (it requires 602+), and this package's macros
        // use only long-stable swift-syntax API. The upper bound stops at the first major
        // beyond what this toolchain (Swift 6.3) ships.
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "601.0.0"..<"604.0.0")
    ],
    targets: [
        .target(name: "KBLLM", dependencies: ["KBLLMMacros"]),
        .target(name: "KBLLMMacros", dependencies: ["KBLLMMacrosPlugin"]),
        .macro(
            name: "KBLLMMacrosPlugin",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax")
            ]
        ),
        .target(name: "KBLLMTesting", dependencies: ["KBLLM"]),
        .target(name: "KBLLMRuntime", dependencies: ["KBLLM"]),
        .target(name: "KBLLMAnthropic", dependencies: ["KBLLM"]),
        .target(name: "KBLLMOpenAI", dependencies: ["KBLLM"]),
        // The ONLY target permitted to import a networking framework. Everything else
        // talks to the `HTTPTransport`/`CredentialStore` seams, so a port to a platform
        // without URLSession reimplements exactly this leaf and nothing else.
        .target(name: "KBLLMURLSession", dependencies: ["KBLLM"]),
        // The ONLY target permitted to import Apple's `FoundationModels`. Everything else
        // talks to the in-package `FoundationModelBackend` seam, so a port to a platform
        // without on-device inference reimplements exactly this leaf and nothing else. The
        // FM-backed backend is compiled in only where `canImport(FoundationModels)` holds.
        .target(name: "KBLLMApple", dependencies: ["KBLLM"]),
        .testTarget(name: "KBLLMTests", dependencies: ["KBLLM", "KBLLMTesting"]),
        .testTarget(
            name: "KBLLMRuntimeTests",
            dependencies: ["KBLLM", "KBLLMRuntime", "KBLLMTesting"]
        ),
        .testTarget(
            name: "KBLLMProvidersTests",
            // KBLLMRuntime is here because one test wraps an adapter in the runtime's logging
            // middleware to prove a full exchange never logs the secret.
            dependencies: ["KBLLMAnthropic", "KBLLMOpenAI", "KBLLM", "KBLLMTesting", "KBLLMRuntime"]
        ),
        .testTarget(
            name: "KBLLMURLSessionTests",
            // KBLLMAnthropic is here only for the opt-in live web search check, which needs a
            // real adapter over the real transport and so can live in no other test target.
            dependencies: ["KBLLMURLSession", "KBLLM", "KBLLMTesting", "KBLLMAnthropic"]
        ),
        .testTarget(
            name: "KBLLMAppleTests",
            dependencies: ["KBLLMApple", "KBLLM", "KBLLMTesting"]
        )
    ]
)

// The Swift-DocC plugin is needed only when building documentation (`KBLLM_BUILD_DOCS=1 swift
// package preview-documentation`), so it is added behind an environment gate rather than imposed
// on every app that depends on KBLLM. A build-tool plugin still has to RESOLVE for consumers,
// which is a cost they should not pay for documentation they are not reading.
if ProcessInfo.processInfo.environment["KBLLM_BUILD_DOCS"] != nil {
    package.dependencies.append(
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.0.0")
    )
}
