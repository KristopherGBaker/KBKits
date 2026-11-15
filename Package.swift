// swift-tools-version: 6.2
import CompilerPluginSupport
import Foundation
import PackageDescription

// Public, app-neutral Swift packages. Each product remains independently linkable while
// one repository gives consumers a single stable dependency URL.
let package = Package(
    name: "KBKits",
    // KBMarkdownUI's String Catalog needs a default localization. The other targets' resources are copied, not localized.
    defaultLocalization: "en",
    platforms: [
        .iOS(.v26),
        .macOS(.v26)
    ],
    products: [
        .library(name: "KBAnkiKit", targets: ["KBAnkiKit"]),
        .library(name: "KBCore", targets: ["KBCore"]),
        .library(name: "KBDictionaryKit", targets: ["KBDictionaryKit"]),
        .library(name: "KBJapaneseKit", targets: ["KBJapaneseKit"]),
        .library(name: "KBKanaKit", targets: ["KBKanaKit"]),
        .library(name: "KBLLM", targets: ["KBLLM"]),
        .library(name: "KBLLMRuntime", targets: ["KBLLMRuntime"]),
        .library(name: "KBLLMTesting", targets: ["KBLLMTesting"]),
        .library(name: "KBLLMAnthropic", targets: ["KBLLMAnthropic"]),
        .library(name: "KBLLMOpenAI", targets: ["KBLLMOpenAI"]),
        .library(name: "KBLLMURLSession", targets: ["KBLLMURLSession"]),
        .library(name: "KBLLMApple", targets: ["KBLLMApple"]),
        .library(name: "KBMarkdown", targets: ["KBMarkdown"]),
        .library(name: "KBMarkdownUI", targets: ["KBMarkdownUI"]),
        .library(name: "KBMCPServer", targets: ["KBMCPServer"]),
        .library(name: "KBNotificationKit", targets: ["KBNotificationKit"]),
        .library(name: "KBReadingKit", targets: ["KBReadingKit"])
    ],
    dependencies: [
        // KBCore's only dependency, and only off Apple platforms: CryptoKit does not exist
        // there and `TextHashing`'s SHA-256 is load-bearing (it is what validates a persisted
        // reading position against a live document). The range deliberately spans 3 and 4:
        // only SHA-256 is used and it is identical across both majors, so a consumer already
        // pinned to either one resolves rather than hitting a hard conflict.
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
        // 7.x, not 6.x. GRDB 6's own sources do not compile off Apple platforms; 7.x does,
        // which is what lets a consumer of KBDictionaryKit cross-compile.
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        // Pure-Swift gzip + tar (MIT) so the Open JTalk dictionary unpacks on iOS too, where
        // there is no `Process` and no `tar`.
        .package(url: "https://github.com/tsolomko/SWCompression", from: "4.9.0"),
        // The fork carries the Japanese G2P, Open JTalk and furigana work upstream does not. Its
        // versions are `<next upstream version>-kits.N` pre-releases, so they never collide with an
        // upstream release, and each is required exactly: a range could also take an upstream
        // release tag a fork carries, which is upstream's code. See README.md, "Dependencies on
        // forks".
        // We take the `MisakiJapanese` product, NOT `MisakiSwift`: the former is the Open
        // JTalk reading path alone, with no mlx-swift and no CoreFoundation, which is what
        // keeps KBJapaneseKit in the `swift test` loop and able to cross-compile.
        .package(url: "https://github.com/KristopherGBaker/MisakiSwift", exact: "1.1.0-kits.1"),
        // The fork is upstream's unreleased `development` plus one commit, in-memory archives on
        // Android, which no upstream release has yet; versioned like the MisakiSwift fork. If
        // upstream releases 0.9.21 with Android support, this can return to upstream.
        // KBAnkiKit reads and writes zips with it (an `.apkg` is a zip). MisakiSwift pins the
        // same fork, and SwiftPM keys package identity on the URL's last path component, so
        // upstream `weichsel/ZIPFoundation` and this fork are ONE identity to it: the URL and
        // requirement here must stay compatible with MisakiSwift's, or the two locations
        // resolve to a pin that cannot be checked out. If one moves, this moves with it.
        .package(url: "https://github.com/KristopherGBaker/ZIPFoundation", exact: "0.9.21-kits.1"),
        // Anki's current export compresses the collection with zstd, which nothing else here
        // can read: SWCompression ships Deflate/BZip2/LZMA/XZ/LZ4 and Apple's Compression
        // framework has LZFSE/LZ4/LZMA/zlib. This is upstream zstd's own SwiftPM manifest, so it
        // is the reference implementation rather than a wrapper. zstd is dual-licensed; KBKits
        // takes it under BSD-3-Clause. See NOTICE.
        .package(url: "https://github.com/facebook/zstd", from: "1.5.0"),
        // SQLite off Apple platforms, for KBAnkiKit. An `.apkg` IS a SQLite database, so unlike
        // KBDictionaryKit there is no seam to hide behind: the dependency is the format. Apple
        // ships SQLite in the SDK; the Android NDK does not expose it, so this vendors the
        // amalgamation. It is the Swift project's own package for this problem, so CVE and
        // version bumps are not ours to chase.
        .package(url: "https://github.com/swiftlang/swift-toolchain-sqlite", from: "1.0.12"),
        // KBLLM's macros. The range is the one KBLLM declared as its own package: every swift-syntax
        // release its macro plugin builds against.
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "601.0.0"..<"604.0.0"),
        // KBMarkdown parses with Apple's swift-markdown.
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.6.0")
    ],
    targets: [
        // Reading and writing Anki `.apkg` decks: the archive layout, the collection database
        // inside it, and the note/note-type shapes an import or export needs. It knows Anki and
        // nothing else: no card model, no scheduler, no mapping to any app's study types.
        .target(
            name: "KBAnkiKit",
            dependencies: [
                // SHA-1 for Anki's note checksum/guid. CryptoKit covers Apple; the condition
                // matches KBCore's, from the same shared swift-crypto range.
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.android])),
                .product(name: "SwiftToolchainCSQLite", package: "swift-toolchain-sqlite",
                         condition: .when(platforms: [.android, .linux])),
                // Declared DIRECTLY, never leaned on transitively, and that is REQUIRED. Importing
                // ZIPFoundation through another product compiles, because the module is
                // visible, and `swift test` even links, because a test executable pulls in
                // every transitive product. A consuming app's test bundle then fails with
                // undefined ZIPFoundation symbols, because THIS target's own object files
                // reference them and nothing linked the library for it. An import grep does
                // not prove a dependency is unused; the check is removing it and LINKING.
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                .product(name: "libzstd", package: "zstd")
            ],
            path: "Packages/KBAnkiKit/Sources/KBAnkiKit",
            swiftSettings: .house
        ),
        .testTarget(
            name: "KBAnkiKitTests",
            dependencies: [
                "KBAnkiKit",
                // Tests COMPRESS their own fixtures, so a zstd collection is exercised end to
                // end rather than through a checked-in blob nobody can regenerate.
                .product(name: "libzstd", package: "zstd"),
                // Declared directly, one per module the tests import themselves: they zip
                // their own `.apkg` fixtures, and the collation tests open a bare SQLite
                // connection to show what a reader without `unicase` sees.
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                .product(name: "SwiftToolchainCSQLite", package: "swift-toolchain-sqlite",
                         condition: .when(platforms: [.android, .linux]))
            ],
            path: "Packages/KBAnkiKit/Tests/KBAnkiKitTests",
            resources: [
                // Rust unicase 2.6.0's fold for every scalar it changes, dumped from the crate
                // by Tools/generate-unicase-fold.sh: the oracle the collation is walked against.
                .copy("Resources/unicase-2.6.0-folds.tsv")
            ],
            swiftSettings: .house
        ),
        // App-neutral reading/document value types plus the portable text machinery
        // (tokenizing, segmenting, spoken-text normalization, hashing, downloads).
        .target(
            name: "KBCore",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.android]))
            ],
            path: "Packages/KBCore/Sources/KBCore",
            swiftSettings: .house
        ),
        .testTarget(
            name: "KBCoreTests",
            dependencies: ["KBCore"],
            path: "Packages/KBCore/Tests/KBCoreTests",
            swiftSettings: .house
        ),
        // SwiftUI-free: the reading pipeline (tokenize, compound join, reading tiers, ruby
        // segments, provenance) and its value model. A UI package draws these; nothing here
        // draws anything, which is what lets a non-Apple host use the same pipeline.
        .target(
            name: "KBReadingKit",
            dependencies: ["KBCore"],
            path: "Packages/KBReadingKit/Sources/KBReadingKit",
            swiftSettings: .house
        ),
        .testTarget(
            name: "KBReadingKitTests",
            // KBCore is declared directly, not leaned on through KBReadingKit:
            // `MemberImportVisibility` only sees members of modules a target imports
            // itself, and these tests build `Document`/`TextSegment` values of their own.
            dependencies: ["KBReadingKit", "KBCore"],
            path: "Packages/KBReadingKit/Tests/KBReadingKitTests",
            swiftSettings: .house
        ),
        // JMdict-backed Japanese word lookup and KANJIDIC2 per-character lookup: read-only
        // stores plus the value types behind a meaning popover and kanji cards.
        .target(
            name: "KBDictionaryKit",
            dependencies: [
                "KBCore",
                // GRDB is Apple-only HERE by necessity, not preference: its CSQLite is a
                // `.systemLibrary` linking sqlite3, the Android NDK ships no SQLite headers
                // or linkable library, and Android's on-device libsqlite.so has been outside
                // the app linker namespace since API 24. `SQLiteJMDictStorage` compiles out
                // with it and `JMDictStore` falls back to `EmptyJMDictStorage`, so the rest
                // of the target stays portable behind the `JMDictStorage` seam.
                .product(
                    name: "GRDB",
                    package: "GRDB.swift",
                    condition: .when(platforms: [.macOS, .iOS, .tvOS, .watchOS, .visionOS])
                )
            ],
            path: "Packages/KBDictionaryKit/Sources/KBDictionaryKit",
            resources: [
                // The curated JMdict seed only (28 KB): a deterministic fixture and a
                // last-resort fallback. A full JMdict is ~66 MB, which no repository should
                // carry for every consumer; apps supply one through `JMDictStore(databaseURL:)`.
                // Licensed CC BY-SA 4.0, not Apache-2.0. See NOTICE.
                .copy("Resources/jmdict-seed.sqlite"),
                // KANJIDIC2, by contrast, DOES ship whole: trimmed to the characters a reader
                // meets it is 332 KB, so kanji lookup works on a fresh clone and on a device
                // rather than silently doing nothing. Licensed CC BY-SA 4.0. See NOTICE.
                .copy("Resources/kanjidic.sqlite")
            ],
            swiftSettings: .house
        ),
        .testTarget(
            name: "KBDictionaryKitTests",
            dependencies: ["KBDictionaryKit"],
            path: "Packages/KBDictionaryKit/Tests/KBDictionaryKitTests",
            swiftSettings: .house
        ),
        // The Japanese reading pipeline: Open JTalk morphology (readings, base forms), the
        // JMdict furigana tier that validates and repairs those readings for DISPLAY, pitch
        // accent, and the on-first-use Open JTalk dictionary download. Display and study
        // only: no speech synthesis lives here.
        .target(
            name: "KBJapaneseKit",
            dependencies: [
                "KBCore",
                "KBDictionaryKit",
                .product(name: "MisakiJapanese", package: "MisakiSwift"),
                // Apple-only for the same reason GRDB is: off Apple there is no download path
                // to unpack.
                .product(name: "SWCompression", package: "SWCompression",
                         condition: .when(platforms: [.macOS, .iOS, .tvOS, .watchOS, .visionOS]))
            ],
            path: "Packages/KBJapaneseKit/Sources/KBJapaneseKit",
            swiftSettings: .house
        ),
        .testTarget(
            name: "KBJapaneseKitTests",
            dependencies: [
                "KBJapaneseKit",
                // Declared directly, one per module the tests import themselves: KBCore for
                // the document and pitch value types, KBDictionaryKit for the real stores,
                // MisakiJapanese for the analyser configuration the live suites touch.
                "KBCore",
                "KBDictionaryKit",
                .product(name: "MisakiJapanese", package: "MisakiSwift"),
                // The cross-seam tests build a real `ReaderContent` to prove the furigana tier
                // survives the renderer's tokenizer, which neither target can assert alone.
                "KBReadingKit",
                // The dictionary tests BUILD a small tar.gz so the real
                // download-stage-extract-install path runs offline, rather than asserting
                // against a lookalike.
                .product(name: "SWCompression", package: "SWCompression",
                         condition: .when(platforms: [.macOS, .iOS, .tvOS, .watchOS, .visionOS]))
            ],
            path: "Packages/KBJapaneseKit/Tests/KBJapaneseKitTests",
            swiftSettings: .house
        ),
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
        ),

        // KBLLM, KBMCPServer and KBMarkdownKit were packages of their own until 1.1.0. Their targets keep the settings they
        // had there (Swift 6 mode, no `.house` upcoming features), so moving them here changes no behaviour.
        .target(name: "KBLLM", dependencies: ["KBLLMMacros"], path: "Packages/KBLLM/Sources/KBLLM"),
        .target(name: "KBLLMMacros", dependencies: ["KBLLMMacrosPlugin"], path: "Packages/KBLLM/Sources/KBLLMMacros"),
        .macro(
            name: "KBLLMMacrosPlugin",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax")
            ],
            path: "Packages/KBLLM/Sources/KBLLMMacrosPlugin"
        ),
        .target(name: "KBLLMTesting", dependencies: ["KBLLM"], path: "Packages/KBLLM/Sources/KBLLMTesting"),
        .target(name: "KBLLMRuntime", dependencies: ["KBLLM"], path: "Packages/KBLLM/Sources/KBLLMRuntime"),
        .target(name: "KBLLMAnthropic", dependencies: ["KBLLM"], path: "Packages/KBLLM/Sources/KBLLMAnthropic"),
        .target(name: "KBLLMOpenAI", dependencies: ["KBLLM"], path: "Packages/KBLLM/Sources/KBLLMOpenAI"),
        .target(name: "KBLLMURLSession", dependencies: ["KBLLM"], path: "Packages/KBLLM/Sources/KBLLMURLSession"),
        .target(name: "KBLLMApple", dependencies: ["KBLLM"], path: "Packages/KBLLM/Sources/KBLLMApple"),
        .testTarget(name: "KBLLMTests", dependencies: ["KBLLM", "KBLLMTesting"], path: "Packages/KBLLM/Tests/KBLLMTests"),
        .testTarget(
            name: "KBLLMRuntimeTests",
            dependencies: ["KBLLM", "KBLLMRuntime", "KBLLMTesting"],
            path: "Packages/KBLLM/Tests/KBLLMRuntimeTests"
        ),
        .testTarget(
            name: "KBLLMProvidersTests",
            dependencies: ["KBLLMAnthropic", "KBLLMOpenAI", "KBLLM", "KBLLMTesting", "KBLLMRuntime"],
            path: "Packages/KBLLM/Tests/KBLLMProvidersTests"
        ),
        .testTarget(
            name: "KBLLMURLSessionTests",
            dependencies: ["KBLLMURLSession", "KBLLM", "KBLLMTesting", "KBLLMAnthropic"],
            path: "Packages/KBLLM/Tests/KBLLMURLSessionTests"
        ),
        .testTarget(
            name: "KBLLMAppleTests",
            dependencies: ["KBLLMApple", "KBLLM", "KBLLMTesting"],
            path: "Packages/KBLLM/Tests/KBLLMAppleTests"
        ),
        .target(name: "KBMCPServer", path: "Packages/KBMCPServer/Sources/KBMCPServer"),
        .testTarget(name: "KBMCPServerTests", dependencies: ["KBMCPServer"], path: "Packages/KBMCPServer/Tests/KBMCPServerTests"),
        .target(
            name: "KBMarkdown",
            dependencies: [.product(name: "Markdown", package: "swift-markdown")],
            path: "Packages/KBMarkdownKit/Sources/KBMarkdown",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "KBMarkdownUI",
            dependencies: ["KBMarkdown"],
            path: "Packages/KBMarkdownKit/Sources/KBMarkdownUI",
            resources: [.process("Localizable.xcstrings")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "KBMarkdownTests",
            dependencies: ["KBMarkdown"],
            path: "Packages/KBMarkdownKit/Tests/KBMarkdownTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "KBMarkdownUITests",
            dependencies: ["KBMarkdown", "KBMarkdownUI"],
            path: "Packages/KBMarkdownKit/Tests/KBMarkdownUITests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)

// The DocC plugin only when building documentation (`KBLLM_BUILD_DOCS=1`), as KBLLM had it, so no consumer resolves it.
if ProcessInfo.processInfo.environment["KBLLM_BUILD_DOCS"] != nil {
    package.dependencies.append(.package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.0.0"))
}

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
