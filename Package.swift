// swift-tools-version: 6.2
import PackageDescription

// Public, app-neutral Swift packages. Each product remains independently linkable while
// one repository gives consumers a single stable dependency URL.
let package = Package(
    name: "KBKits",
    platforms: [
        .iOS(.v26),
        .macOS(.v26)
    ],
    products: [
        .library(name: "KBKanaKit", targets: ["KBKanaKit"]),
        .library(name: "KBNotificationKit", targets: ["KBNotificationKit"])
    ],
    targets: [
        .target(
            name: "KBKanaKit",
            path: "Packages/KBKanaKit/Sources/KBKanaKit",
            swiftSettings: .house
        ),
        .testTarget(
            name: "KBKanaKitTests",
            dependencies: ["KBKanaKit"],
            path: "Packages/KBKanaKit/Tests/KBKanaKitTests",
            swiftSettings: .house
        ),
        .target(
            name: "KBNotificationKit",
            path: "Packages/KBNotificationKit/Sources/KBNotificationKit",
            swiftSettings: .house
        ),
        .testTarget(
            name: "KBNotificationKitTests",
            dependencies: ["KBNotificationKit"],
            path: "Packages/KBNotificationKit/Tests/KBNotificationKitTests",
            swiftSettings: .house
        )
    ]
)

extension Array where Element == SwiftSetting {
    static var house: [SwiftSetting] {
        [
            .swiftLanguageMode(.v6),
            .enableUpcomingFeature("ExistentialAny"),
            .enableUpcomingFeature("MemberImportVisibility"),
            .enableUpcomingFeature("InternalImportsByDefault"),
            .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            .enableUpcomingFeature("InferIsolatedConformances")
        ]
    }
}
