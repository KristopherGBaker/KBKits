# Changelog

KBKits is versioned as one package: every product shares the root package's version. See
`README.md`, "Releasing".

## 1.1.0

### Added

- Every library is now a product of the root package, so one versioned dependency on
  `https://github.com/KristopherGBaker/KBKits.git` reaches all of them:
  - KBAnkiKit, KBCore, KBDictionaryKit, KBJapaneseKit and KBReadingKit;
  - KBLLM, KBLLMRuntime, KBLLMTesting, KBLLMAnthropic, KBLLMOpenAI, KBLLMURLSession and KBLLMApple;
  - KBMCPServer;
  - KBMarkdown and KBMarkdownUI.
- `CHANGELOG.md` and the release process in `README.md`.

### Changed

- KBLLM, KBMCPServer and KBMarkdownKit are no longer packages of their own. Their manifests under
  `Packages/` are gone, and their targets are in the root manifest with the settings they had.
  To migrate, depend on the root package and change `package: "KBLLM"`, `"KBMCPServer"` or
  `"KBMarkdownKit"` to `package: "KBKits"`. Product and module names are unchanged.
- The MisakiSwift and ZIPFoundation forks are required by exact version (`1.1.0-kits.1` and
  `0.9.21-kits.1`) instead of by branch, so KBKits resolves as a versioned dependency.
- The package declares `defaultLocalization: "en"` (KBMarkdownUI's String Catalog needs it).

## 1.0.0

- KBKanaKit and KBNotificationKit.
