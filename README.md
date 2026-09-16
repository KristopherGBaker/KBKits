# KBKits

Public Swift packages for app-neutral features shared by Kristopher Baker's Apple-platform
apps.

## Packages

- **KBKanaKit**: romaji-to-kana conversion and character-based edit distance.
- **KBNotificationKit**: a testable local-notification scheduling seam for Apple apps.

Each product is independently linkable from the package:

```swift
dependencies: [
    .package(url: "https://github.com/KristopherGBaker/KBKits.git", from: "1.0.0")
]
```

The packages target iOS 26 and macOS 26 and use Swift 6 strict concurrency. Run `swift test`
from the repository root to run all package tests.

KBKanaKit contains code derived from Tsurukame under the Apache License 2.0. See
`Packages/KBKanaKit/NOTICE` and `Packages/KBKanaKit/LICENSE-Apache-2.0.txt`.
