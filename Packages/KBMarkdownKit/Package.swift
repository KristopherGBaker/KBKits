// swift-tools-version: 6.2
import PackageDescription

// KBMarkdownKit is the shared Markdown foundation: a Sendable block model with source ranges
// (KBMarkdown) and the SwiftUI renderer and source editor on top of it (KBMarkdownUI).
//
// The logic target imports Foundation and swift-markdown only, so it can be held to the
// Android bar; the SwiftUI lives in the UI target (a logic/UI split).
//
// swift-markdown is an upstream package, not a fork, declared at `from: "0.6.0"` so a graph that
// already holds it resolves the two declarations to one copy.
let package = Package(
    name: "KBMarkdownKit",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v26),
        .iOS(.v26)
    ],
    products: [
        .library(name: "KBMarkdown", targets: ["KBMarkdown"]),
        .library(name: "KBMarkdownUI", targets: ["KBMarkdownUI"])
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.6.0")
    ],
    targets: [
        .target(
            name: "KBMarkdown",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown")
            ]
        ),
        .target(
            name: "KBMarkdownUI",
            dependencies: ["KBMarkdown"],
            resources: [.process("Localizable.xcstrings")]
        ),
        .testTarget(
            name: "KBMarkdownTests",
            dependencies: ["KBMarkdown"]
        ),
        .testTarget(
            name: "KBMarkdownUITests",
            dependencies: ["KBMarkdown", "KBMarkdownUI"]
        )
    ],
    swiftLanguageModes: [.v6]
)
