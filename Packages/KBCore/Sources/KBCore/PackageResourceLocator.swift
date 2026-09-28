public import Foundation

/// Finds a SwiftPM resource-bundle file WITHOUT touching `Bundle.module`.
///
/// This exists because `Bundle.module` is not safe to call. SwiftPM generates its accessor
/// as a `fatalError` when the bundle cannot be found, so a caller that carefully writes
/// `guard let url = Bundle.module.url(...) else { return fallback }` never reaches its own
/// guard: the trap fires while evaluating `Bundle.module`. Inside an Android APK there is no
/// resource bundle at all, so that is a process abort on first use, and the crash even
/// reports the build machine's path. A sibling package had exactly that shape, with a comment
/// promising it "never crashes".
///
/// The search mirrors SwiftPM's own layout: a directory named `<Package>_<Target>` beside the
/// executable or the main bundle, with the `.bundle` extension on Apple platforms and
/// `.resources` elsewhere. Both are tried everywhere, because which one exists is a property
/// of how the code was built rather than of where it is running.
///
/// `roots` is a parameter rather than an `#if` so the whole thing is exercised on macOS,
/// where it is not the default path. A lookup that only ran off-Apple would first execute on
/// a phone, in production, which is the mistake this package has made before.
public enum PackageResourceLocator {
    /// Directories that may contain a resource bundle, most specific first.
    public static var defaultRoots: [URL] {
        var roots: [URL] = []
        if let resources = Bundle.main.resourceURL { roots.append(resources) }
        roots.append(Bundle.main.bundleURL)
        if let executable = Bundle.main.executableURL?.deletingLastPathComponent() {
            roots.append(executable)
        }
        return roots
    }

    /// The URL of `resource.ext` inside `<bundleName>.bundle` or `<bundleName>.resources`
    /// under any of `roots`, or `nil` when it is not there. Never traps, never throws.
    ///
    /// `bundleName` is SwiftPM's `<Package>_<Target>` form, e.g. `KBKits_KBDictionaryKit`.
    public static func url(
        bundleName: String,
        resource: String,
        extension ext: String,
        roots: [URL] = defaultRoots
    ) -> URL? {
        let fileManager = FileManager.default
        for root in roots {
            for suffix in ["bundle", "resources"] {
                let candidate = root
                    .appendingPathComponent("\(bundleName).\(suffix)")
                    .appendingPathComponent("\(resource).\(ext)")
                if fileManager.fileExists(atPath: candidate.path) { return candidate }
            }
        }
        return nil
    }

    /// The URL of `resource.ext` in the resource bundle belonging to the TARGET named
    /// `target`, whatever package happens to enclose it, or `nil` when it is not there.
    ///
    /// Prefer this to ``url(bundleName:resource:extension:roots:)``. Spelling the bundle
    /// name out in full hard-codes the enclosing PACKAGE, so a target that is copied into a
    /// differently named package stops finding its own resources, with no compile error and
    /// no crash to say so: the lookup simply returns nil and the feature quietly does
    /// nothing. Matching the `_<Target>` suffix keys the search to the module name, which
    /// travels with the code.
    public static func url(
        targetName target: String,
        resource: String,
        extension ext: String,
        roots: [URL] = defaultRoots
    ) -> URL? {
        let fileManager = FileManager.default
        for root in roots {
            guard let entries = try? fileManager.contentsOfDirectory(atPath: root.path) else {
                continue
            }
            // Sorted so a root holding more than one matching bundle resolves the same way
            // on every run, rather than in whatever order the filesystem enumerated.
            for entry in entries.sorted() {
                let bundle = root.appendingPathComponent(entry)
                let name = bundle.deletingPathExtension().lastPathComponent
                guard ["bundle", "resources"].contains(bundle.pathExtension),
                      name == target || name.hasSuffix("_\(target)") else { continue }
                let candidate = bundle.appendingPathComponent("\(resource).\(ext)")
                if fileManager.fileExists(atPath: candidate.path) { return candidate }
            }
        }
        return nil
    }
}
