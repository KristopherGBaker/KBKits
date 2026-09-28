import Foundation
import KBCore
import KBJapaneseKit
import MisakiJapanese
import Synchronization
import Testing

/// The live proof that the fix is the SENTENCE PATH, not a per-token patch: in the
/// same environment, the isolated lookup still re-tokenizes 静か and doubles the か,
/// while the in-context pass reads it correctly. Runs only when `OJT_DICT_DIR`
/// points at an unpacked Open JTalk dictionary; unset means SKIPPED, never passed.
@Suite("FuriganaContextLive: in-context readings over the real dictionary",
       .enabled(if: ProcessInfo.processInfo.environment["OJT_DICT_DIR"] != nil,
                "set OJT_DICT_DIR to an unpacked open_jtalk_dic_utf_8 directory to run"))
struct FuriganaContextLiveTests {

    private func reader() throws -> JapaneseReader {
        let path = try #require(ProcessInfo.processInfo.environment["OJT_DICT_DIR"])
        return try #require(JapaneseReader(dictionaryDirectory: URL(fileURLWithPath: path)),
                            "OJT_DICT_DIR does not hold a loadable dictionary")
    }

    @Test("静か reads しずか in context while its isolated re-analysis still doubles the か")
    func shizukaInContext() throws {
        let live = try reader()
        let sentence = "猫が静かな公園を歩いている。"
        let words = live.furiganaWords(in: sentence)
        let shizuka = try #require(words.first { $0.surface == "静か" })
        #expect(shizuka.reading == "しずか")

        let annotations = FuriganaAlignment.align(surfaces: words.map(\.surface), words: words)
        let index = try #require(words.firstIndex { $0.surface == "静か" })
        #expect(annotations[index]?.reading == "しずか")

        // The signature half: the ISOLATED path still yields the doubled reading in
        // this very environment, so the fix demonstrably comes from the sentence.
        #expect(live.furiganaReading(for: "静か") == "しずかか")
    }

    @Test("the sentence path keeps the reconciliation wins")
    func reconciliationPreserved() throws {
        let live = try reader()
        // Sound change: 八百 → はっぴゃく, not はちひゃく.
        let happyaku = live.furiganaWords(in: "八百円を払った。")
        let joined = happyaku.map(\.reading).joined()
        #expect(joined.contains("はっぴゃく"))
        #expect(!joined.contains("はちひゃく"))
        // Orthographic long vowels: 方 → ほう and 先生 → せんせい, not ほお/せんせえ.
        let hou = live.furiganaWords(in: "その方がいい。")
        #expect(hou.map(\.reading).joined().contains("ほう"))
        let sensei = live.furiganaWords(in: "先生は学校へ行った。")
        #expect(sensei.first { $0.surface == "先生" }?.reading == "せんせい")
    }
}

/// The retained per-surface path: callers with no sentence still resolve a lone
/// surface, exactly as before this unit. The dictionary comes from `OJT_DICT_DIR`
/// alone: nothing here reads a host-specific location, so the suite skips rather
/// than passing or failing by accident of what a particular machine happens to
/// have downloaded.
private func retainedDictionary() -> URL? {
    guard let env = ProcessInfo.processInfo.environment["OJT_DICT_DIR"] else { return nil }
    let directory = URL(fileURLWithPath: env)
    return FileManager.default.fileExists(atPath: directory.appendingPathComponent("sys.dic").path)
        ? directory : nil
}

@Suite("RetainedPerSurface: the no-sentence fallback still resolves a lone surface",
       .enabled(if: retainedDictionary() != nil,
                "set OJT_DICT_DIR to an unpacked open_jtalk_dic_utf_8 directory to run"))
struct RetainedPerSurfaceTests {

    @Test("the per-surface closures and the lone-surface reading remain non-nil")
    func loneSurfaceResolves() throws {
        let directory = try #require(retainedDictionary())
        // The analyser's configured directory is PROCESS-GLOBAL; setting it here and
        // never restoring it is what raced a sibling suite asserting "no dictionary
        // configured". Save and restore it, AND take `openJTalkConfigurationGate`, because
        // save-and-restore alone still interleaves with a suite that reads the global while
        // this one holds it set. The whole region is synchronous, so the gate is enough.
        try openJTalkConfigurationGate.withLock { _ in
            let configured = JapaneseG2PConfiguration.dictionaryDirectory
            defer { JapaneseG2PConfiguration.dictionaryDirectory = configured }
            JapaneseTextAnalysis.useDictionary(at: directory)
            let furigana = JapaneseFurigana.providers(dictionary: nil)
            #expect(furigana.reading?("静か") != nil)
            #expect(furigana.baseForm?("静か") != nil)
            let live = try #require(JapaneseReader(dictionaryDirectory: directory))
            #expect(live.furiganaReading(for: "静か") != nil)
        }
    }
}
