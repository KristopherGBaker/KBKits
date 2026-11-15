# KBKits

KBKits is a set of Swift libraries for Apple-platform apps: a provider-neutral LLM client with an agent loop, an
in-app MCP server, a Markdown model with a SwiftUI renderer and editor, and a Japanese reading pipeline (morphology,
furigana, dictionaries and pitch accent), plus the smaller pieces those apps share.

They come from Kristopher Baker's apps, among them [Silverpoint](https://github.com/KristopherGBaker/Silverpoint), and
are kept app-neutral: nothing in them knows which app links it.

## What's in it

One Swift package, with each library as its own product. An app names only the products it uses, and only those are
built and linked.

**Language models and agents**

| Product | What it is |
|---|---|
| `KBLLM` | A provider-neutral LLM client: one `LanguageModel` protocol, value-typed messages, requests and events, typed errors, JSON schemas, and the `@Tool`/`@Schema` macros. |
| `KBLLMRuntime` | `AgentSession`, the tool loop that runs a model and its tools turn by turn. |
| `KBLLMAnthropic` | The Anthropic Messages API, with server-side web search. |
| `KBLLMOpenAI` | OpenAI's Responses API and any OpenAI-compatible (Chat Completions) endpoint. |
| `KBLLMApple` | Apple's on-device Foundation Models. |
| `KBLLMURLSession` | The live `URLSession` transport the network adapters run over, and the credential stores (the environment, the Keychain). |
| `KBLLMTesting` | Offline fakes for tests. |
| `KBMCPServer` | Host a tool-only MCP server from an app, over loopback Streamable HTTP or stdio, so a local agent such as Claude Code can call into it. No dependencies. |

**Markdown**

| Product | What it is |
|---|---|
| `KBMarkdown` | A `Sendable` block model parsed from CommonMark plus GFM, with a source range on every block and inline, and caller-registered inline tokens (citations, mentions). |
| `KBMarkdownUI` | A SwiftUI renderer for that model, and a plain-text source editor that styles Markdown as it is typed. |

**Reading Japanese**

| Product | What it is |
|---|---|
| `KBJapaneseKit` | Open JTalk morphology, the JMdict furigana tier that validates and repairs its readings, pitch accent, and the on-first-use dictionary download. |
| `KBReadingKit` | The SwiftUI-free reading pipeline: tokenization, the furigana rules a reader sees, and the value model a renderer draws from. |
| `KBDictionaryKit` | JMdict word lookup and KANJIDIC2 kanji lookup over two bundled read-only databases. |
| `KBKanaKit` | Romaji-to-kana transliteration and edit distance. |
| `KBAnkiKit` | Reading and writing Anki `.apkg` decks: note types, decks, notes, media, and export of new cards. |

**Shared**

| Product | What it is |
|---|---|
| `KBCore` | The vocabulary the other libraries speak: the document model, text and script primitives, reading position and timing. |
| `KBNotificationKit` | A testable local-notification seam: a scheduler protocol and its `UNUserNotificationCenter` implementation. |

Each library's folder under `Packages/` has a README with its API and design notes.

## Install

Add KBKits by version and name the products you use:

```swift
dependencies: [
    .package(url: "https://github.com/KristopherGBaker/KBKits.git", from: "1.1.0")
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "KBLLM", package: "KBKits"),
        .product(name: "KBLLMAnthropic", package: "KBKits")
    ])
]
```

In Xcode, add `https://github.com/KristopherGBaker/KBKits.git` as a package dependency and pick the products. In an
XcodeGen `project.yml`:

```yaml
packages:
  KBKits:
    url: https://github.com/KristopherGBaker/KBKits.git
    from: 1.1.0
targets:
  MyApp:
    dependencies:
      - package: KBKits
        product: KBMarkdownUI
```

KBKits needs **Swift 6.2** and targets **iOS 26** and **macOS 26**; building `KBLLMApple` (and so `swift build` of the whole
package) needs the **Xcode 27 SDK**, because it names macOS 27 types behind availability checks. Every library is written
for Swift 6 strict concurrency.

**What gets fetched.** Products decide what is built and linked, not what is fetched. SwiftPM resolves the whole
package's dependencies for every consumer: swift-syntax, swift-markdown, GRDB, zstd, swift-crypto, SWCompression,
swift-toolchain-sqlite, and the MisakiSwift fork with mlx-swift behind it. An app that links only `KBLLM` fetches them
on its first resolve but builds none of them.

**From 1.0.x, or from a path.** Until 1.1.0, KBLLM, KBMCPServer and KBMarkdownKit were packages of their own
(`.package(path: "../KBKits/Packages/KBLLM")`). Depend on the root package instead, and change `package: "KBLLM"`,
`"KBMCPServer"` or `"KBMarkdownKit"` to `package: "KBKits"`. Product and module names are unchanged, so no `import`
changes. `CHANGELOG.md` lists every release's changes.

## Working on KBKits

Clone the repository and run every library's tests from its root:

```sh
swift build
swift test
swift test --filter KBLLM       # one library's tests
```

To work on KBKits from an app, keep the app's versioned dependency and override it with your checkout:

- **SwiftPM:** `swift package edit KBKits --path ../KBKits` in the app's package, and `swift package unedit KBKits`
  when you are done.
- **Xcode:** add your checkout to the project or workspace as a local package. A local package overrides the remote
  one with the same name until you remove it.

`Tools/` holds scripts run by hand, outside every build and test: `KBLLMSmoke` (a live check of KBLLM against a real
server), and the generators for KBDictionaryKit's databases and KBAnkiKit's Unicode case folds.

## Dependencies on forks

Two dependencies are forks, kept because upstream does not have what KBKits needs:

- **[MisakiSwift](https://github.com/KristopherGBaker/MisakiSwift)**: upstream 1.0.6 plus the Japanese G2P, Open JTalk
  and furigana work KBJapaneseKit uses (its `MisakiJapanese` product, which links no MLX). It reaches ZIPFoundation
  through a fork of [MLXUtilsLibrary](https://github.com/KristopherGBaker/MLXUtilsLibrary).
- **[ZIPFoundation](https://github.com/KristopherGBaker/ZIPFoundation)**: upstream's `development` branch plus
  in-memory archives on Android, which KBAnkiKit needs and no upstream release has yet.

Each fork is tagged `<next upstream version>-kits.<N>` (`1.1.0-kits.1`, `0.0.7-kits.1`, `0.9.21-kits.1`). That's a
pre-release, so it can never collide with an upstream version. KBKits requires each fork's exact version
(`exact: "1.1.0-kits.1"`), and so do the forks of each other. A range would not be safe: a fork can carry upstream's
release tags (the MLXUtilsLibrary fork carries 0.0.2 to 0.0.7), and SwiftPM ranks a release above a pre-release, so a
range would take upstream's code. There is no branch pin anywhere in the graph.

SwiftPM identifies a package by the last part of its URL. An app that also depends on upstream `mlalma/MisakiSwift` or
`weichsel/ZIPFoundation` therefore conflicts with KBKits; use the forks.

## Releasing

KBKits is versioned as one package: every product shares the root package's semantic version.

1. **Forks first.** After changing a fork: commit, tag the next `-kits.N`, push the tag, and move the exact
   requirement on it (in KBKits, and in any fork that depends on it) to the new tag.
2. **Validate everything**, not only what one app uses: `swift package resolve`, `swift build`, `swift test`.
3. **Changelog.** Add the version's entry to `CHANGELOG.md`: what was added, changed or fixed, and what a consumer must
   change.
4. **Tag and publish.** `git tag -a X.Y.Z -m "KBKits X.Y.Z"`, push `main` and the tag, then create the GitHub release
   from the changelog entry.
5. **Update the apps.** Raise each app's requirement if it needs the new version, update the package
   (`swift package update KBKits`, or Xcode's Update to Latest Package Versions), commit its `Package.resolved`, and run
   its checks.

## Licensing

The source code is Apache-2.0 (`LICENSE`). Three things are not:

- The two databases bundled in KBDictionaryKit are **CC BY-SA 4.0** data from EDRDG, James Breen and Doublevil, not
  Apache-2.0. If you link that library you redistribute them, so you must credit the data in your About screen. See
  `NOTICE` and `Licenses/CC-BY-SA-4.0.txt`.
- The Open JTalk dictionary KBJapaneseKit downloads on first use is under three three-clause BSD notices, which a
  consuming app must reproduce. See `Licenses/OpenJTalk-Dictionary-NOTICES.md`.
- KBKanaKit contains code derived from Tsurukame under the Apache License 2.0. See `Packages/KBKanaKit/NOTICE` and
  `Packages/KBKanaKit/LICENSE-Apache-2.0.txt`.

`NOTICE` lists every third-party dependency and its license.
