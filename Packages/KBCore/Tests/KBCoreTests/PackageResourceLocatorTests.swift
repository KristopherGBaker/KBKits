import Foundation
import Testing
@testable import KBCore

/// The locator runs on every platform, so it is tested on macOS against a real directory
/// layout rather than only exercised on a device. `roots` is injectable precisely so this
/// can be done without depending on how the test binary itself was packaged.
@Suite("Package resource locator")
struct PackageResourceLocatorTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("locator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func plant(_ root: URL, bundle: String, file: String) throws {
        let dir = root.appendingPathComponent(bundle, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: dir.appendingPathComponent(file))
    }

    @Test("finds a resource in a .resources directory, the off-Apple layout")
    func findsResourcesLayout() throws {
        let root = try makeRoot()
        try plant(root, bundle: "Pkg_Target.resources", file: "data.json")
        let found = PackageResourceLocator.url(bundleName: "Pkg_Target", resource: "data",
                                               extension: "json", roots: [root])
        #expect(found != nil)
        #expect(FileManager.default.fileExists(atPath: try #require(found).path))
    }

    @Test("finds a resource in a .bundle directory, the Apple layout")
    func findsBundleLayout() throws {
        let root = try makeRoot()
        try plant(root, bundle: "Pkg_Target.bundle", file: "data.json")
        #expect(PackageResourceLocator.url(bundleName: "Pkg_Target", resource: "data",
                                           extension: "json", roots: [root]) != nil)
    }

    /// The whole point: absent resources must return nil, not abort the process the way
    /// `Bundle.module` does. This is the APK case.
    @Test("returns nil when there is no bundle at all, rather than trapping")
    func missingBundleIsNil() throws {
        let root = try makeRoot()
        #expect(PackageResourceLocator.url(bundleName: "Pkg_Target", resource: "data",
                                           extension: "json", roots: [root]) == nil)
    }

    @Test("returns nil when the bundle exists but the file does not")
    func missingFileIsNil() throws {
        let root = try makeRoot()
        try plant(root, bundle: "Pkg_Target.resources", file: "other.json")
        #expect(PackageResourceLocator.url(bundleName: "Pkg_Target", resource: "data",
                                           extension: "json", roots: [root]) == nil)
    }

    @Test("searches roots in order and ignores ones that do not have it")
    func searchesRootsInOrder() throws {
        let empty = try makeRoot()
        let real = try makeRoot()
        try plant(real, bundle: "Pkg_Target.resources", file: "data.json")
        let found = PackageResourceLocator.url(bundleName: "Pkg_Target", resource: "data",
                                               extension: "json", roots: [empty, real])
        #expect(try #require(found).path.hasPrefix(real.path))
    }

    @Test("an empty root list is nil, not a crash")
    func noRootsIsNil() {
        #expect(PackageResourceLocator.url(bundleName: "Pkg_Target", resource: "data",
                                           extension: "json", roots: []) == nil)
    }
}

/// The target-keyed lookup, which is the one every caller should use: a target copied into
/// a differently named package must still find its own resources. These tests name TWO
/// enclosing packages for one target on purpose, because the bug being prevented is a
/// package rename (`KBDictionaryKit` to `KBKits`) that no compiler notices.
@Suite("Package resource locator, keyed by target rather than package")
struct PackageResourceLocatorTargetTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("locator-target-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func plant(_ root: URL, bundle: String, file: String) throws {
        let dir = root.appendingPathComponent(bundle, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: dir.appendingPathComponent(file))
    }

    @Test("the same target is found under either enclosing package name",
          arguments: ["KBDictionaryKit_KBDictionaryKit", "KBKits_KBDictionaryKit"])
    func findsTargetWhateverThePackageIsCalled(bundle: String) throws {
        let root = try makeRoot()
        try plant(root, bundle: "\(bundle).resources", file: "jmdict-seed.sqlite")
        let found = PackageResourceLocator.url(targetName: "KBDictionaryKit",
                                               resource: "jmdict-seed", extension: "sqlite",
                                               roots: [root])
        #expect(try #require(found).path.hasSuffix("\(bundle).resources/jmdict-seed.sqlite"))
    }

    @Test("the Apple .bundle layout resolves by target too")
    func findsBundleLayoutByTarget() throws {
        let root = try makeRoot()
        try plant(root, bundle: "KBKits_KBDictionaryKit.bundle", file: "kanjidic.sqlite")
        #expect(PackageResourceLocator.url(targetName: "KBDictionaryKit", resource: "kanjidic",
                                           extension: "sqlite", roots: [root]) != nil)
    }

    @Test("a bundle with no package prefix at all still resolves")
    func findsUnprefixedBundle() throws {
        let root = try makeRoot()
        try plant(root, bundle: "KBDictionaryKit.resources", file: "kanjidic.sqlite")
        #expect(PackageResourceLocator.url(targetName: "KBDictionaryKit", resource: "kanjidic",
                                           extension: "sqlite", roots: [root]) != nil)
    }

    /// A DIFFERENT target whose name merely ends with the same letters must not match:
    /// `_<Target>` is a suffix on a separator, not a substring.
    @Test("another target is not mistaken for this one")
    func doesNotMatchADifferentTarget() throws {
        let root = try makeRoot()
        try plant(root, bundle: "KBKits_KBDictionaryKitExtras.resources", file: "kanjidic.sqlite")
        try plant(root, bundle: "KBKits_MyKBDictionaryKit.resources", file: "kanjidic.sqlite")
        #expect(PackageResourceLocator.url(targetName: "KBDictionaryKit", resource: "kanjidic",
                                           extension: "sqlite", roots: [root]) == nil)
    }

    @Test("a directory that is not a resource bundle is ignored")
    func ignoresNonBundleDirectories() throws {
        let root = try makeRoot()
        try plant(root, bundle: "KBKits_KBDictionaryKit", file: "kanjidic.sqlite")
        #expect(PackageResourceLocator.url(targetName: "KBDictionaryKit", resource: "kanjidic",
                                           extension: "sqlite", roots: [root]) == nil)
    }

    @Test("a missing root, an empty root and no roots are all nil rather than a trap")
    func absentResourcesAreNil() throws {
        let empty = try makeRoot()
        let absent = empty.appendingPathComponent("not-there", isDirectory: true)
        #expect(PackageResourceLocator.url(targetName: "KBDictionaryKit", resource: "kanjidic",
                                           extension: "sqlite", roots: [absent, empty]) == nil)
        #expect(PackageResourceLocator.url(targetName: "KBDictionaryKit", resource: "kanjidic",
                                           extension: "sqlite", roots: []) == nil)
    }

    @Test("roots are searched in order")
    func searchesRootsInOrder() throws {
        let empty = try makeRoot()
        let real = try makeRoot()
        try plant(real, bundle: "KBKits_KBDictionaryKit.resources", file: "kanjidic.sqlite")
        let found = PackageResourceLocator.url(targetName: "KBDictionaryKit", resource: "kanjidic",
                                               extension: "sqlite", roots: [empty, real])
        #expect(try #require(found).path.hasPrefix(real.path))
    }
}
