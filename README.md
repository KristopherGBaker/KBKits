# KBKits

Public Swift packages for app-neutral features shared by Kristopher Baker's Apple-platform
apps.

## Packages

- **KBCore**: the shared document, text and reading-position vocabulary every other package speaks.
- **KBDictionaryKit**: JMdict word lookup and KANJIDIC2 kanji lookup over two bundled read-only databases.
- **KBJapaneseKit**: the Japanese reading pipeline, from Open JTalk morphology to validated furigana and pitch accent.
- **KBKanaKit**: romaji-to-kana conversion and character-based edit distance.
- **KBNotificationKit**: a testable local-notification scheduling seam for Apple apps.
- **KBReadingKit**: the SwiftUI-free reading pipeline: tokenizing, the furigana rules, and the value model a renderer draws.

Each product is independently linkable from the package:

```swift
dependencies: [
    .package(url: "https://github.com/KristopherGBaker/KBKits.git", from: "1.0.0")
]
```

The packages target iOS 26 and macOS 26 and use Swift 6 strict concurrency. Run `swift test`
from the repository root to run all package tests.

## Licensing

The source code is Apache-2.0 (`LICENSE`). Three things are not:

- The two databases bundled in KBDictionaryKit are **CC BY-SA 4.0** data from EDRDG, James
  Breen and Doublevil, not Apache-2.0. If you link that package you redistribute them, so you
  must credit the data in your About screen. See `NOTICE` and `Licenses/CC-BY-SA-4.0.txt`.
- The Open JTalk dictionary KBJapaneseKit downloads on first use is under three three-clause
  BSD notices, which a consuming app must reproduce. See
  `Licenses/OpenJTalk-Dictionary-NOTICES.md`.
- KBKanaKit contains code derived from Tsurukame under the Apache License 2.0. See
  `Packages/KBKanaKit/NOTICE` and `Packages/KBKanaKit/LICENSE-Apache-2.0.txt`.

`NOTICE` lists every third-party dependency and its licence.

## Before a release

These are blocking, and none of them is a code change inside this repository:

1. **MisakiSwift must be tagged, and the pin moved to the tag.** `Package.swift` currently pins
   `https://github.com/KristopherGBaker/MisakiSwift` to the `feat/japanese-g2p` BRANCH, because
   the fork carries no tag yet. A branch pin makes every consumer's resolution float, and
   SwiftPM will not accept one at all from a dependency resolved by version, so KBKits cannot
   be tagged while that pin stands. The comment in `Package.swift` marks the spot. No version
   has been invented in the meantime.
2. **The two branch pins MisakiSwift itself carries must be tagged too**, for the same reason:
   `MLXUtilsLibrary` and `ZIPFoundation` are pinned to `kits-android` there. Tagging MisakiSwift
   alone leaves the float one level down.
3. **Decide the MLX graph.** KBJapaneseKit takes only the `MisakiJapanese` product and links no
   MLX, but SwiftPM still resolves mlx-swift, MLXUtilsLibrary, ZIPFoundation and swift-numerics
   through the fork. Splitting an MLX-free package out of the fork removes them; until then they
   are listed in `NOTICE`.
