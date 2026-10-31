import CoreGraphics
import Foundation
import ImageIO
import KBMarkdown
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import KBMarkdownUI

/// Renders the real `MarkdownView` through `ImageRenderer` and reads the pixels.
///
/// Every snapshot is written as a PNG to a fresh temporary directory; set
/// `KBMARKDOWN_SNAPSHOT_DIR` to also keep them in a directory of your choosing.
@MainActor
@Suite("Renderer snapshots")
struct RendererSnapshotTests {
    static let fixture = """
    # Report title

    A paragraph with *emphasis*, **strong**, `code`, a [link](https://example.com) and a citation [A1].

    > A quoted line.

    1. First
       - nested
         - deeper
    2. [x] Done task

    | Name | Score |
    |:-----|------:|
    | *Ann* | 9 |

    ```swift
    let answer = 42
    ```

    ```mermaid
    graph TD; A-->B
    ```

    ---
    """

    private static let magenta = Color(red: 1, green: 0, blue: 1)
    private static let green = Color(red: 0, green: 0.8, blue: 0)

    private func render(_ view: some View, name: String) throws -> Bitmap {
        let content = view
            .frame(width: 480, alignment: .leading)
            .padding(16)
            .background(Color.white)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        let image = try #require(renderer.cgImage, "ImageRenderer produced no bitmap")
        try Snapshots.write(image, name: name)
        return try #require(Bitmap(image))
    }

    @Test("the fixture document renders every block to a sizeable bitmap")
    func fixtureRenders() throws {
        let parser = MarkdownParser(recognizers: [try citationRecognizer()])
        let bitmap = try render(MarkdownView(source: Self.fixture, parser: parser), name: "fixture")
        #expect(bitmap.width == 512)
        #expect(bitmap.height > 350, "every block stacked: \(bitmap.height) px")
        #expect(bitmap.count { $0.isDark } > 1_000, "text was drawn")
    }

    @Test("a code block and a table that fit draw their text (no scroll view in the way)")
    func codeAndTableDrawText() throws {
        let code = try render(MarkdownView(source: "```swift\nlet answer = 42\n```"), name: "code")
        #expect(code.count { $0.isDark } > 100)
        let table = try render(MarkdownView(source: "| Name | Score |\n|:--|--:|\n| Ann | 9 |"), name: "table")
        #expect(table.count { $0.isDark } > 100)
    }

    @Test("a fenced-block override replaces exactly the language it accepts")
    func codeBlockOverride() throws {
        var seen: [String?] = []
        let overridden = MarkdownView(source: Self.fixture) { language, _ in
            seen.append(language)
            guard language == "mermaid" else { return nil }
            return AnyView(Self.magenta.frame(width: 120, height: 60))
        }
        let withOverride = try render(overridden, name: "override")
        #expect(seen.contains("mermaid") && seen.contains("swift"))
        #expect(withOverride.count { $0.isMagenta } > 5_000)
        let without = try render(MarkdownView(source: Self.fixture), name: "no-override")
        #expect(without.count { $0.isMagenta } == 0)
    }

    @Test("tokens draw the default tinted capsule; without a recognizer nothing is tinted")
    func tokenCapsules() throws {
        let style = MarkdownStyle(tokenTint: Self.green)
        let source = "Claims [A1] and [B2] are cited."
        let tokens = try render(
            MarkdownView(source: source, parser: MarkdownParser(recognizers: [try citationRecognizer()]), style: style),
            name: "tokens")
        #expect(tokens.count { $0.isGreenish } > 40)
        let plain = try render(MarkdownView(source: source, style: style), name: "no-tokens")
        #expect(plain.count { $0.isGreenish } == 0)
    }

    @Test("a heading renders taller than the same words as a paragraph")
    func headingScale() throws {
        let heading = try render(MarkdownView(source: "# Quarterly"), name: "heading")
        let paragraph = try render(MarkdownView(source: "Quarterly"), name: "paragraph")
        #expect(heading.inkHeight > paragraph.inkHeight)
    }

    @Test("a nested list indents each level further")
    func nestedListIndents() throws {
        let flat = try render(MarkdownView(source: "- three"), name: "list-flat")
        let nested = try render(MarkdownView(source: "- one\n  - two\n    - three"), name: "list-nested")
        #expect(nested.lastLineMinX > flat.lastLineMinX + 20)
    }
}

// MARK: - Pixels

/// An RGBA8 copy of an image.
struct Bitmap {
    struct Pixel {
        let red: UInt8, green: UInt8, blue: UInt8

        var isDark: Bool { Int(red) + Int(green) + Int(blue) < 200 }
        var isMagenta: Bool { red > 230 && green < 30 && blue > 230 }
        var isGreenish: Bool { Int(green) > Int(red) + 25 && Int(green) > Int(blue) + 25 }
        var isInk: Bool { Int(red) + Int(green) + Int(blue) < 600 }
    }

    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init?(_ image: CGImage) {
        let width = image.width
        let height = image.height
        self.width = width
        self.height = height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = buffer.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        bytes = buffer
    }

    func pixel(x: Int, y: Int) -> Pixel {
        let index = (y * width + x) * 4
        return Pixel(red: bytes[index], green: bytes[index + 1], blue: bytes[index + 2])
    }

    func count(where predicate: (Pixel) -> Bool) -> Int {
        var total = 0
        for y in 0..<height {
            for x in 0..<width where predicate(pixel(x: x, y: y)) { total += 1 }
        }
        return total
    }

    /// The rows from the first to the last holding any ink.
    var inkHeight: Int {
        let rows = (0..<height).filter { y in (0..<width).contains { pixel(x: $0, y: y).isInk } }
        guard let first = rows.first, let last = rows.last else { return 0 }
        return last - first + 1
    }

    /// The leftmost ink in the last line of ink (the band of inked rows nearest the bottom).
    var lastLineMinX: Int {
        let inked = { (y: Int) in (0..<width).contains { pixel(x: $0, y: y).isInk } }
        guard var top = (0..<height).last(where: inked) else { return width }
        while top > 0, inked(top - 1) { top -= 1 }
        let band = top...((0..<height).last(where: inked) ?? top)
        return (0..<width).first { x in band.contains { pixel(x: x, y: $0).isInk } } ?? width
    }
}

enum Snapshots {
    /// A fresh directory per test process, so runs never read each other's files.
    static let directory: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("KBMarkdownKitSnapshots-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func write(_ image: CGImage, name: String) throws {
        var targets = [directory]
        if let kept = ProcessInfo.processInfo.environment["KBMARKDOWN_SNAPSHOT_DIR"], !kept.isEmpty {
            let url = URL(fileURLWithPath: kept, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            targets.append(url)
        }
        for target in targets {
            let file = target.appendingPathComponent("\(name).png")
            let destination = try #require(
                CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            #expect(CGImageDestinationFinalize(destination), "wrote \(file.path)")
        }
    }
}
