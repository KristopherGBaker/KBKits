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
        .library(name: "KBAnkiKit", targets: ["KBAnkiKit"]),
        .library(name: "KBCore", targets: ["KBCore"]),
        .library(name: "KBDictionaryKit", targets: ["KBDictionaryKit"]),
        .library(name: "KBJapaneseKit", targets: ["KBJapaneseKit"]),
        .library(name: "KBKanaKit", targets: ["KBKanaKit"]),
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
        // ==========================================================================
        // BRANCH PIN, NOT A RELEASE. This fork has no tag yet. It MUST become a tagged
        // version before KBKits itself is released: a branch pin makes every consumer's
        // resolution float, and SwiftPM will not accept it from a versioned dependency at
        // all. Tracked in README.md ("Before a release").
        // ==========================================================================
        // We take the `MisakiJapanese` product, NOT `MisakiSwift`: the former is the Open
        // JTalk reading path alone, with no mlx-swift and no CoreFoundation, which is what
        // keeps KBJapaneseKit in the `swift test` loop and able to cross-compile.
        .package(url: "https://github.com/KristopherGBaker/MisakiSwift", branch: "feat/japanese-g2p"),
        // ==========================================================================
        // BRANCH PIN, NOT A RELEASE. This fork has no tag yet either, and it MUST become a
        // tagged version before KBKits itself is released, for the same reasons as the pin
        // above. Tracked in README.md ("Before a release").
        // ==========================================================================
        // KBAnkiKit reads and writes zips with it (an `.apkg` is a zip). MisakiSwift pins the
        // same fork, and SwiftPM keys package identity on the URL's last path component, so
        // upstream `weichsel/ZIPFoundation` and this fork are ONE identity to it: the URL and
        // branch here must stay character-identical to MisakiSwift's, or the two locations
        // resolve to a pin that cannot be checked out. If one moves, this moves with it.
        .package(url: "https://github.com/KristopherGBaker/ZIPFoundation", branch: "kits-android"),
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
        .package(url: "https://github.com/swiftlang/swift-toolchain-sqlite", from: "1.0.12")
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
