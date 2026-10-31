import Foundation

/// Reads the package's own source off disk so the content-invariant tests (no banned
/// imports, no em dashes, single-source descriptions, one adapter-surface file) run as
/// ordinary tests under `swift test` rather than as an external script.
enum SourceReader {
    /// The `Packages/KBLLM` root, derived from this file's location so it works from
    /// any build directory.
    static var packageRoot: URL {
        // This file lives at Packages/KBLLM/Tests/KBLLMTests/SourceReader.swift, so the
        // package root is three directories up.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Whether the package's own sources are reachable on disk.
    ///
    /// `#filePath` is baked in at COMPILE time, so on a device the test binary was pushed
    /// to it names a path on the build machine that does not exist. The content-invariant
    /// tests assert things about the repository, not about runtime behavior, so they are
    /// host-only by nature: gating on this reports them as skipped there instead of as
    /// dozens of failures that say nothing about the platform. See `docs/ANDROID.md`.
    static var sourcesAvailable: Bool {
        FileManager.default.fileExists(atPath: packageRoot.appendingPathComponent("Sources").path)
    }

    static var sourcesRoot: URL { packageRoot.appendingPathComponent("Sources") }
    static var testsRoot: URL { packageRoot.appendingPathComponent("Tests") }

    static func moduleSourceDirectory(_ module: String) -> URL {
        sourcesRoot.appendingPathComponent(module)
    }

    /// Every `.swift` file under a directory, skipping build artifacts and documentation.
    ///
    /// A `.docc` catalog holds tutorial CODE SNIPPETS as `.swift` files. SwiftPM does not
    /// compile them and they are deliberately incomplete (they reference a `model` the reader
    /// supplies), so scanning them as module sources makes every architecture assertion here
    /// answer a question about documentation instead of about the module.
    static func swiftFiles(under directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        var files: [URL] = []
        for case let url as URL in enumerator {
            let path = url.path
            if path.contains("/.build/") || path.contains("/.swiftpm/") { continue }
            if path.contains(".docc/") { continue }
            if url.pathExtension == "swift" {
                files.append(url)
            }
        }
        return files
    }

    static func contents(of url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// Combined contents of every `.swift` file under a directory.
    static func combinedContents(under directory: URL) -> String {
        swiftFiles(under: directory).map(contents(of:)).joined(separator: "\n")
    }

    /// The count of occurrences of a substring across every `.swift` file under a set
    /// of directories.
    static func occurrences(of needle: String, under directories: [URL]) -> Int {
        var total = 0
        for directory in directories {
            for file in swiftFiles(under: directory) {
                total += contents(of: file).components(separatedBy: needle).count - 1
            }
        }
        return total
    }

    /// Extract every `- Parameter name: text` description from a file's doc comments.
    static func parameterDescriptions(in url: URL) -> [String] {
        var descriptions: [String] = []
        for rawLine in contents(of: url).split(separator: "\n", omittingEmptySubsequences: false) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("///") else { continue }
            line.removeFirst(3)
            line = line.trimmingCharacters(in: .whitespaces)
            let marker = "- Parameter "
            guard line.hasPrefix(marker), let colon = line.firstIndex(of: ":") else { continue }
            let text = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !text.isEmpty {
                descriptions.append(text)
            }
        }
        return descriptions
    }

    /// Every top-level module name imported by a file, normalizing `@_exported`, the
    /// submodule kinds (`import class Foundation.NSObject`), and aliased forms down to the
    /// first path component, so the import-allowlist test cannot be slipped past by a
    /// novel spelling.
    static func importedModules(in file: URL) -> [String] {
        var modules: [String] = []
        for rawLine in contents(of: file).split(separator: "\n", omittingEmptySubsequences: false) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            // Strip leading attributes such as @_exported or @testable.
            while line.hasPrefix("@"), let space = line.firstIndex(of: " ") {
                line = String(line[line.index(after: space)...]).trimmingCharacters(in: .whitespaces)
            }
            guard line.hasPrefix("import ") else { continue }
            var rest = String(line.dropFirst("import ".count)).trimmingCharacters(in: .whitespaces)
            // A submodule import names a declaration kind before the module path.
            for kind in ["typealias ", "struct ", "class ", "enum ", "protocol ", "let ", "var ", "func "]
            where rest.hasPrefix(kind) {
                rest = String(rest.dropFirst(kind.count)).trimmingCharacters(in: .whitespaces)
            }
            let module = String(rest.split(separator: ".").first ?? Substring(rest))
                .trimmingCharacters(in: .whitespaces)
            if !module.isEmpty { modules.append(module) }
        }
        return modules
    }

    /// The contiguous `///` doc-comment lines IMMEDIATELY preceding the first line
    /// containing `declaration`, joined into one string, or nil if none directly precede
    /// it. Used to prove a load-bearing design choice carries a rationale.
    static func docComment(precedingLineContaining declaration: String, in file: URL) -> String? {
        let lines = contents(of: file)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard let target = lines.firstIndex(where: { $0.contains(declaration) }) else { return nil }
        var collected: [String] = []
        var index = target - 1
        while index >= 0 {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("///") else { break }
            collected.append(String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces))
            index -= 1
        }
        return collected.isEmpty ? nil : collected.reversed().joined(separator: " ")
    }

    /// The text of a specific `- Parameter name: text` doc line in a file.
    static func parameterDescription(named name: String, in url: URL) -> String? {
        for rawLine in contents(of: url).split(separator: "\n", omittingEmptySubsequences: false) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("///") else { continue }
            line.removeFirst(3)
            line = line.trimmingCharacters(in: .whitespaces)
            let marker = "- Parameter \(name):"
            guard line.hasPrefix(marker) else { continue }
            return line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}
