// swift-tools-version: 6.2
import PackageDescription

// Dev-only LIVE smoke harness for KBLLM (NOT part of any app build, any test suite, or lint).
// It points the real `KBLLMURLSession` transport and the OpenAI-wire adapter at a live server
// (the public endpoint, or an OpenAI-compatible local server such as LM Studio, Ollama, or
// vLLM), runs one streaming completion and one tool round trip, prints what it observed, and
// exits non-zero on failure. It is run by hand, exactly like `build-jmdict.swift` and
// `FuriganaQA`; it is deliberately its OWN package under Tools/ so it is never a target of the
// KBLLM manifest and never pulled into its `swift test`.
let package = Package(
    name: "KBLLMSmoke",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(name: "KBLLM", path: "../../Packages/KBLLM")
    ],
    targets: [
        .executableTarget(
            name: "KBLLMSmoke",
            dependencies: [
                .product(name: "KBLLM", package: "KBLLM"),
                .product(name: "KBLLMAnthropic", package: "KBLLM"),
                .product(name: "KBLLMOpenAI", package: "KBLLM"),
                .product(name: "KBLLMURLSession", package: "KBLLM")
            ]
        )
    ]
)
