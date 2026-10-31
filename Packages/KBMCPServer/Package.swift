// swift-tools-version: 6.2
import PackageDescription

// KBMCPServer: host a tool-only MCP (Model Context Protocol) server from an app. A JSON-RPC 2.0
// core, closure-based tools, a loopback Streamable-HTTP transport on NWListener, a stdio transport, and a
// persistence-agnostic lifecycle controller. No dependencies.
let package = Package(
    name: "KBMCPServer",
    platforms: [
        .macOS(.v26),
        .iOS(.v26)
    ],
    products: [
        .library(name: "KBMCPServer", targets: ["KBMCPServer"])
    ],
    targets: [
        .target(
            name: "KBMCPServer"
        ),
        .testTarget(
            name: "KBMCPServerTests",
            dependencies: ["KBMCPServer"]
        )
    ]
)
