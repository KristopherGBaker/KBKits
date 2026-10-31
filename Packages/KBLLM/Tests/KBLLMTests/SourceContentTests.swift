import Foundation
import Testing

// These tests read the package's own source from disk so structural invariants the
// brief cares about are enforced by the suite, not by review: no banned imports in the
// core, no wall clock in the testing support, one adapter-surface file, single-source
// descriptions, Swift Testing only, no em dashes, and a locked target set.
@Suite(.enabled(if: SourceReader.sourcesAvailable))
struct SourceContentTests {
    private var coreDirectory: URL { SourceReader.moduleSourceDirectory("KBLLM") }

    // MARK: Assertion 3(a) - one adapter-surface file, nothing scattered.

    @Test func adapterSurfaceTypesLiveInExactlyOneCoreFile() {
        let expectedFile = "LanguageModel.swift"
        let declarations = [
            "protocol LanguageModel",
            "struct ModelRequest",
            "enum ModelEvent",
            "struct ModelResponse"
        ]
        let coreFiles = SourceReader.swiftFiles(under: coreDirectory)
        for declaration in declarations {
            let declaringFiles = coreFiles.filter {
                SourceReader.contents(of: $0).contains(declaration)
            }
            #expect(
                declaringFiles.count == 1,
                "\(declaration) should be declared in exactly one core file, found \(declaringFiles.count)"
            )
            #expect(
                declaringFiles.first?.lastPathComponent == expectedFile,
                "\(declaration) should be declared in \(expectedFile)"
            )
        }
    }

    // MARK: Assertion 3(b) - host seams are Sendable protocols.

    @Test func hostSeamsAreDeclaredAsSendableProtocols() {
        let seams = SourceReader.contents(of: coreDirectory.appendingPathComponent("Seams.swift"))
        #expect(seams.contains("protocol HTTPTransport: Sendable"))
        #expect(seams.contains("protocol CredentialStore: Sendable"))
        #expect(seams.contains("protocol LogSink: Sendable"))
        #expect(seams.contains("protocol ClockSource: Sendable"))
        // RandomSource refines the standard generator and Sendable.
        #expect(seams.contains("protocol RandomSource: RandomNumberGenerator, Sendable"))
    }

    // MARK: Assertion 6 - each parameter description is written exactly once.

    @Test func parameterDescriptionsHaveASingleSourceInSource() {
        let fixtures = SourceReader.testsRoot
            .appendingPathComponent("KBLLMTests")
            .appendingPathComponent("Fixtures.swift")
        let descriptions = SourceReader.parameterDescriptions(in: fixtures)
        #expect(descriptions.count >= 2)
        let searchRoots = [SourceReader.sourcesRoot, SourceReader.testsRoot]
        for description in descriptions {
            let count = SourceReader.occurrences(of: description, under: searchRoots)
            #expect(count == 1, "description \"\(description)\" should appear once, found \(count)")
        }
    }

    // MARK: Assertion 11 - core imports no platform or network/keychain APIs.

    @Test func coreImportsNoPlatformOrNetworkAPIs() {
        let banned = [
            "import FoundationNetworking",
            "import Security",
            "import Combine",
            "import OSLog",
            "import SwiftUI",
            "import AppKit",
            "import UIKit",
            "URLSession",
            "Keychain"
        ]
        let core = SourceReader.combinedContents(under: coreDirectory)
        for token in banned {
            #expect(!core.contains(token), "core must not contain \(token)")
        }
    }

    // MARK: Assertion 12 - testing support never touches the wall clock or system RNG.

    @Test func testingSupportHasNoWallClockOrSystemRandom() {
        let testing = SourceReader.combinedContents(under: SourceReader.moduleSourceDirectory("KBLLMTesting"))
        #expect(!testing.contains("Date()"))
        #expect(!testing.contains("Date.now"))
        #expect(!testing.contains("SystemRandomNumberGenerator"))
    }

    // MARK: Assertion 13 - Swift Testing only, and no em dashes in sources.

    @Test func noXCTestAnywhereInThePackage() {
        let everything = SourceReader.combinedContents(under: SourceReader.sourcesRoot)
            + SourceReader.combinedContents(under: SourceReader.testsRoot)
        // Built by concatenation so this assertion's own needle is not a false positive.
        let needle = "import " + "XCTest"
        #expect(!everything.contains(needle))
    }

    @Test func noEmDashInSources() {
        let emDash = "\u{2014}"
        let sources = SourceReader.combinedContents(under: SourceReader.sourcesRoot)
        #expect(!sources.contains(emDash))
    }

    // MARK: Runtime assertion 11 / transport assertion 3 - closed import allowlist, and
    // networking permitted ONLY in KBLLMURLSession.

    @Test func modulesImportOnlyAllowlistedModules() {
        // KBLLM re-exports its macros via `@_exported import KBLLMMacros`, so that internal
        // module is on its allowlist alongside Foundation; the runtime adds only KBLLM.
        let allowlist: [String: Set<String>] = [
            "KBLLM": ["Foundation", "KBLLMMacros"],
            "KBLLMRuntime": ["Foundation", "KBLLM"],
            // The provider adapters talk only to the core's seams: Foundation for JSON and
            // KBLLM for the neutral types. No networking module is on their allowlist.
            "KBLLMAnthropic": ["Foundation", "KBLLM"],
            "KBLLMOpenAI": ["Foundation", "KBLLM"],
            // The networking leaf is the ONE target allowed a networking framework:
            // Foundation, FoundationNetworking (the non-Apple URLSession home), and KBLLM.
            // Security joins them because this is also where the HOST-side credential stores
            // live, and the Keychain-backed one needs it. It is guarded by canImport, so the
            // target still builds for Android; the networking-spelling scan below already
            // treats Keychain and SecItem as this target's alone.
            "KBLLMURLSession": ["Foundation", "FoundationNetworking", "KBLLM", "Security"],
            // The Apple leaf is the ONE target allowed `FoundationModels`: Foundation for
            // JSON, FoundationModels for the on-device and Private Cloud Compute models, and
            // KBLLM for the neutral types. CoreGraphics and ImageIO join them (U10k) so the
            // live layer can decode an `.image` part into the `CGImage` a macOS 27
            // `Attachment` takes; both are imported under an in-file `canImport` guard, so the
            // target still builds for Android. No networking module is on its allowlist.
            "KBLLMApple": ["Foundation", "FoundationModels", "KBLLM", "CoreGraphics", "ImageIO"]
        ]
        for (module, allowed) in allowlist {
            for file in SourceReader.swiftFiles(under: SourceReader.moduleSourceDirectory(module)) {
                for imported in SourceReader.importedModules(in: file) {
                    #expect(
                        allowed.contains(imported),
                        "\(module)/\(file.lastPathComponent) imports \(imported), not on the allowlist"
                    )
                }
            }
        }
        // The networking-spelling scan covers EVERY source target except the one leaf that is
        // permitted networking, so a URLSession/Keychain reference that leaks into any other
        // target (core, runtime, testing, either adapter) fails here.
        let nonNetworkingTargets =
            ["KBLLM", "KBLLMRuntime", "KBLLMTesting", "KBLLMAnthropic", "KBLLMOpenAI", "KBLLMApple"]
        let combined = nonNetworkingTargets
            .map { SourceReader.combinedContents(under: SourceReader.moduleSourceDirectory($0)) }
            .joined(separator: "\n")
        let networkingSpellings = [
            "URLSession", "URLRequest", "URLSessionConfiguration", "FoundationNetworking", "Keychain", "SecItem"
        ]
        for spelling in networkingSpellings {
            #expect(!combined.contains(spelling), "\(spelling) may appear only in KBLLMURLSession")
        }
    }

    // MARK: Providers assertion 3 - no networking anywhere in the adapters or their tests.

    @Test func adaptersAndProvidersTestsContainNoNetworkingSpellings() {
        let adapterAndTestSources =
            SourceReader.combinedContents(under: SourceReader.moduleSourceDirectory("KBLLMAnthropic"))
            + SourceReader.combinedContents(under: SourceReader.moduleSourceDirectory("KBLLMOpenAI"))
            + SourceReader.combinedContents(
                under: SourceReader.testsRoot.appendingPathComponent("KBLLMProvidersTests")
            )
        let banned = [
            "URLSession", "URLRequest", "URLSessionConfiguration",
            "FoundationNetworking", "Network", "CFSocket", "socket("
        ]
        for spelling in banned {
            #expect(
                !adapterAndTestSources.contains(spelling),
                "networking spelling \(spelling) must not appear in the adapters or their tests"
            )
        }
    }

    // MARK: Runtime assertion 12(b) - defense-in-depth scan for wall-clock/RNG spellings.

    @Test func unitAvoidsKnownWallClockAndRandomSpellings() {
        let banned = [
            "Date()", "Date.now", "ContinuousClock", "SuspendingClock", "DispatchTime",
            "DispatchWallTime", "clock_gettime", "mach_absolute_time", "gettimeofday",
            "CACurrentMediaTime", "ProcessInfo", ".systemUptime", "Task.sleep", "Thread.sleep",
            "usleep(", "nanosleep(", "DispatchQueue", "SystemRandomNumberGenerator"
        ]
        let combined = SourceReader.combinedContents(under: SourceReader.moduleSourceDirectory("KBLLM"))
            + SourceReader.combinedContents(under: SourceReader.moduleSourceDirectory("KBLLMRuntime"))
            + SourceReader.combinedContents(under: SourceReader.moduleSourceDirectory("KBLLMAnthropic"))
            + SourceReader.combinedContents(under: SourceReader.moduleSourceDirectory("KBLLMOpenAI"))
            + SourceReader.combinedContents(under: SourceReader.moduleSourceDirectory("KBLLMApple"))
        for spelling in banned {
            #expect(!combined.contains(spelling), "banned time/RNG spelling \(spelling) must not appear in the unit")
        }
    }

    // MARK: Runtime assertion 14(d) - load-bearing design choices document their rationale.

    @Test func loadBearingDesignChoicesDocumentRationale() {
        let runtime = SourceReader.moduleSourceDirectory("KBLLMRuntime")
        let session = runtime.appendingPathComponent("AgentSession.swift")
        let middleware = runtime.appendingPathComponent("Middleware.swift")
        // Each choice's doc must name the FAILURE it avoids, not merely restate the signature.
        let boundTokens: Set<String> = [
            "forever", "infinite", "never terminate", "never stop", "runaway", "unbounded"
        ]
        let checks: [DocRationaleCheck] = [
            DocRationaleCheck(session, "public func run(", ["disagree", "drift", "diverge", "out of sync"]),
            DocRationaleCheck(session, "public let maxToolRoundTrips", boundTokens),
            DocRationaleCheck(session, "func dispatchInCallOrder(", ["nondeterministic", "unpredictable", "arbitrary"]),
            DocRationaleCheck(middleware, "public func wrap(", ["unpredictable", "arbitrary", "reorder", "ambiguous"])
        ]
        for check in checks {
            let doc = SourceReader.docComment(precedingLineContaining: check.declaration, in: check.file)?.lowercased()
            #expect(doc != nil, "\(check.declaration) must carry a doc comment")
            let hasToken = check.tokens.contains { doc?.contains($0) ?? false }
            #expect(hasToken, "doc for \(check.declaration) must name a failure from \(check.tokens)")
        }
    }

    // MARK: Assertion 14 - the target set is locked, no out-of-scope surface.

    @Test func packageTargetSetIsExactlyTheFourteenExpected() throws {
        let expected: Set<String> = [
            "KBLLM",
            "KBLLMMacros",
            "KBLLMMacrosPlugin",
            "KBLLMTesting",
            "KBLLMRuntime",
            "KBLLMAnthropic",
            "KBLLMOpenAI",
            "KBLLMURLSession",
            "KBLLMApple",
            "KBLLMTests",
            "KBLLMRuntimeTests",
            "KBLLMProvidersTests",
            "KBLLMURLSessionTests",
            "KBLLMAppleTests"
        ]
        // Read the AUTHORITATIVE resolved target set from `swift package dump-package`,
        // whose JSON has every manifest expression evaluated. Parsing Package.swift as
        // text is defeatable by binding a target name to a constant; the resolved dump
        // is not. Compare the COMPLETE set for exact equality.
        let declared = try resolvedTargetNames()
        let unexpected = declared.subtracting(expected).sorted()
        let missing = expected.subtracting(declared).sorted()
        #expect(unexpected.isEmpty, "manifest declares unexpected target(s): \(unexpected)")
        #expect(missing.isEmpty, "manifest is missing expected target(s): \(missing)")
        #expect(declared == expected, "declared target set \(declared.sorted()) must equal \(expected.sorted())")
    }

    /// The exact set of declared target names, from the evaluated manifest.
    private func resolvedTargetNames() throws -> Set<String> {
        Set(try resolvedManifest().targets.map(\.name))
    }

    /// Invoke `swift package dump-package` and return its evaluated manifest, so a target
    /// added by any means (a literal name or a name bound to a constant) is reflected here.
    ///
    /// The dump runs against an isolated temporary copy of `Package.swift`, not the live
    /// package: a `dump-package` pointed at the live package path blocks indefinitely on
    /// the SwiftPM workspace lock held by the concurrently running `swift test`. A fresh
    /// throwaway workspace evaluates the identical manifest with no lock contention, and
    /// `--manifest-cache none` keeps it off the shared manifest-cache lock too. A
    /// watchdog terminates the child if it ever stalls, so this can never hang the suite.
    private func resolvedManifest() throws -> DumpedManifest {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("kbllm-dump-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        try FileManager.default.copyItem(
            at: SourceReader.packageRoot.appendingPathComponent("Package.swift"),
            to: workspace.appendingPathComponent("Package.swift")
        )

        let process = Process()
        // `/usr/bin/env` resolves `swift` from PATH, avoiding a hardcoded toolchain path.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "swift", "package",
            "--package-path", workspace.path,
            "--manifest-cache", "none",
            "dump-package"
        ]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()

        // Insurance: if the child ever stalls, kill it so the test fails fast instead of
        // hanging. dump-package on an isolated workspace is fast, so 120s is generous.
        let watchdog = Thread {
            Thread.sleep(forTimeInterval: 120)
            if process.isRunning { process.terminate() }
        }
        watchdog.start()

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw DumpFailure.nonZeroExit(Int(process.terminationStatus))
        }
        return try JSONDecoder().decode(DumpedManifest.self, from: data)
    }

    // MARK: Transport assertion 14 - the Tools smoke harness stays out of lint and the suite.

    @Test func toolsSmokeHarnessIsOutsideLintAndTheSuite() throws {
        // (a) No target in the resolved KBLLM manifest draws its sources from `Tools/`.
        for target in try resolvedManifest().targets {
            if let path = target.path {
                #expect(!path.contains("Tools"), "no package target may source from Tools/, found \(path)")
            }
        }

        // (b) No file under `Tests/` references the harness. The needle is built by
        // concatenation so this guard file is not itself a false positive.
        let harnessModule = "KBLLM" + "Smoke"
        let tests = SourceReader.combinedContents(under: SourceReader.testsRoot)
        #expect(!tests.contains(harnessModule), "no test may reference the Tools smoke harness")
    }

}

// A separate suite for the Apple leaf's FoundationModels invariants, so these scans do not
// push `SourceContentTests` past its type-body-length budget. Same disk-reading approach.
@Suite(.enabled(if: SourceReader.sourcesAvailable))
struct FoundationModelsSourceTests {
    // MARK: Apple assertion 14 - FoundationModels is exclusive to KBLLMApple.

    @Test func foundationModelsAppearsOnlyInKBLLMApple() {
        // Every source target EXCEPT the Apple leaf must be free of any FoundationModels
        // reference, so the on-device framework cannot leak into the portable core or any
        // other adapter. `SystemLanguageModel` is scanned alongside the module name so an
        // import-free use is caught too.
        let otherTargets = [
            "KBLLM", "KBLLMMacros", "KBLLMMacrosPlugin", "KBLLMTesting",
            "KBLLMRuntime", "KBLLMAnthropic", "KBLLMOpenAI", "KBLLMURLSession"
        ]
        let spellings = ["FoundationModels", "SystemLanguageModel"]
        for target in otherTargets {
            let combined = SourceReader.combinedContents(under: SourceReader.moduleSourceDirectory(target))
            for spelling in spellings {
                #expect(!combined.contains(spelling), "\(spelling) may appear only in KBLLMApple, found in \(target)")
            }
        }
        // And it MUST appear in the Apple leaf, or the exclusivity claim is vacuous.
        let apple = SourceReader.combinedContents(under: SourceReader.moduleSourceDirectory("KBLLMApple"))
        #expect(apple.contains("FoundationModels"), "KBLLMApple must import FoundationModels")
        #expect(apple.contains("SystemLanguageModel"), "KBLLMApple must reference SystemLanguageModel")
    }

    // MARK: Apple assertion 15 - the FoundationModels import is platform-gated, surface survives.

    @Test func foundationModelsImportIsPlatformGated() {
        let guardToken = "#if canImport(FoundationModels)"
        let importToken = "import FoundationModels"
        // Every file that imports FoundationModels must place the import AFTER a
        // `#if canImport(FoundationModels)` line, so the framework-absent build excludes it.
        for file in SourceReader.swiftFiles(under: SourceReader.moduleSourceDirectory("KBLLMApple")) {
            let lines = SourceReader.contents(of: file)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
            guard let importLine = lines.firstIndex(where: { $0.contains(importToken) }) else { continue }
            let guardLine = lines.firstIndex(where: { $0.contains(guardToken) })
            #expect(guardLine != nil, "\(file.lastPathComponent) imports FoundationModels without a canImport guard")
            if let guardLine {
                #expect(guardLine < importLine, "\(file.lastPathComponent) must gate the import behind canImport")
            }
        }
        // The adapter struct and the seam protocol are declared OUTSIDE any canImport guard,
        // so the module vends its surface where the framework is absent. Their files carry no
        // such guard at all, which makes the declarations unambiguously unguarded.
        let adapter = SourceReader.contents(
            of: SourceReader.moduleSourceDirectory("KBLLMApple").appendingPathComponent("AppleModel.swift")
        )
        #expect(adapter.contains("public struct AppleModel"), "AppleModel must be declared")
        #expect(!adapter.contains(guardToken), "AppleModel must not sit inside a canImport(FoundationModels) guard")
        let seam = SourceReader.contents(
            of: SourceReader.moduleSourceDirectory("KBLLMApple")
                .appendingPathComponent("FoundationModelBackend.swift")
        )
        #expect(seam.contains("protocol FoundationModelBackend"), "the backend seam must be declared")
        #expect(!seam.contains(guardToken), "the backend seam must not sit inside a canImport(FoundationModels) guard")
    }
}

// A separate suite for the stale-documentation sweep, kept out of `SourceContentTests` so
// these scans do not push that suite past its type-body-length budget. Same disk-reading
// approach: the source is the authority, not review.
@Suite(.enabled(if: SourceReader.sourcesAvailable))
struct StaleDocSweepTests {
    // MARK: Assertion 14 - no lingering "1024 cap" claim in sources or package docs.

    @Test func noStale1024CapClaimInPackageDocs() {
        // The old defect froze Anthropic output at this token; after the behaviour widened to
        // caller-controlled-with-fallback, no doc comment or package prose may still claim a
        // fixed/capped-at-1024 output. Test sources are OUT of scope (assertion 4's test name
        // and the sweep's own needle mention it deliberately), so only `Sources` comment lines
        // and package markdown are scanned.
        let needle = "1024"
        for file in SourceReader.swiftFiles(under: SourceReader.sourcesRoot) {
            for rawLine in SourceReader.contents(of: file).split(separator: "\n", omittingEmptySubsequences: false) {
                let line = String(rawLine)
                guard let comment = commentText(in: line) else { continue }
                #expect(
                    !comment.contains(needle),
                    "\(file.lastPathComponent) comment still claims a \(needle) cap: \(line)"
                )
            }
        }
        for markdown in packageMarkdownFiles() {
            #expect(
                !SourceReader.contents(of: markdown).contains(needle),
                "\(markdown.lastPathComponent) package doc still mentions \(needle)"
            )
        }
    }
}

/// The comment portion of a source line, or nil when the line carries no comment. A
/// whole-line comment returns its text; a trailing comment returns the text from the first
/// `//`, unless that `//` is part of a `://` URL scheme, so a doc URL is not mistaken for a
/// comment start. File scope so the sweep suite stays small.
private func commentText(in line: String) -> String? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix("//") { return trimmed }
    guard let range = line.range(of: "//") else { return nil }
    if line[..<range.lowerBound].hasSuffix(":") { return nil }
    return String(line[range.lowerBound...])
}

/// Every `.md` file under the package root, skipping build artifacts, so the sweep covers any
/// package README/markdown prose as well as the source doc comments.
private func packageMarkdownFiles() -> [URL] {
    guard let enumerator = FileManager.default.enumerator(
        at: SourceReader.packageRoot,
        includingPropertiesForKeys: nil
    ) else {
        return []
    }
    var files: [URL] = []
    for case let url as URL in enumerator {
        let path = url.path
        if path.contains("/.build/") || path.contains("/.swiftpm/") { continue }
        if url.pathExtension == "md" { files.append(url) }
    }
    return files
}

/// The list items under a `.swiftlint.yml` `included:` key, quotes stripped. A tiny hand
/// parser rather than a YAML dependency, since the shape checked is a flat list. File scope so
/// it does not count against the guard suite's type-body-length budget.
private func includedRoots(inSwiftLintYAML yaml: String) -> [String] {
    var roots: [String] = []
    var inIncluded = false
    for rawLine in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(rawLine)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#") { continue }
        if trimmed == "included:" { inIncluded = true; continue }
        guard inIncluded else { continue }
        // A new unindented key ends the `included:` block.
        if !line.hasPrefix(" "), !line.hasPrefix("\t"), trimmed.hasSuffix(":") { break }
        if trimmed.hasPrefix("-") {
            let item = trimmed.dropFirst()
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !item.isEmpty { roots.append(item) }
        }
    }
    return roots
}

/// One load-bearing design choice to check: the file and declaration to locate, and the
/// failure-token set its rationale doc must contain. A named type rather than a tuple so
/// the three members read clearly at each call site.
private struct DocRationaleCheck {
    let file: URL
    let declaration: String
    let tokens: Set<String>

    init(_ file: URL, _ declaration: String, _ tokens: Set<String>) {
        self.file = file
        self.declaration = declaration
        self.tokens = tokens
    }
}

/// The minimal shape of `swift package dump-package` output that this test reads.
/// File scope rather than nested, to stay within the house nesting limit.
private struct DumpedManifest: Decodable {
    let targets: [DumpedTarget]
}

private struct DumpedTarget: Decodable {
    let name: String
    /// The target's explicit source path, if the manifest set one. `nil` for a target that
    /// uses SwiftPM's default `Sources/<name>` layout, which is every KBLLM target.
    let path: String?
}

private enum DumpFailure: Error {
    case nonZeroExit(Int)
}
