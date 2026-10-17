<p align="center">
  <img src="docs/images/icon.png" width="128" height="128" alt="XCleaner app icon">
</p>

<h1 align="center">XCleaner</h1>

<p align="center">
  A native macOS cleaner with a clean, safe and simple interface.
</p>

<p align="center">
  <a href="https://github.com/xazar-mammadli/XCleaner/releases/latest"><img src="https://img.shields.io/github/v/release/xazar-mammadli/XCleaner?label=release" alt="Latest release"></a>
  <a href="https://github.com/xazar-mammadli/XCleaner/actions/workflows/ci.yml"><img src="https://github.com/xazar-mammadli/XCleaner/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-111111?logo=apple&logoColor=white" alt="macOS 14+">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green" alt="License: MIT"></a>
</p>

<p align="center">
  <img src="docs/images/cleanup.jpg" width="820" alt="XCleaner reviewing junk found by a scan">
</p>

## Features

- **Cleanup:** system junk, installers and downloads, the Trash, system-level junk and Mail attachments.
- **Applications:** a complete uninstaller, leftovers of deleted apps, app reset and extensions.
- **Performance:** heavy apps, startup items and maintenance tasks.
- **Files:** big and old files, duplicates and a disk map.
- **Privacy:** browser data, app permissions and a background item check.
- **Utilities:** cleanup history, a menu bar monitor and hidden files.

In English, Azerbaijani, Russian and Turkish.

## Safety

- Nothing is removed until you review it, and removed items go to the Trash first.
- macOS, Keychains, iCloud Drive, Mail, Photos and SSH keys are never touched.
- One copy of every duplicate always stays.
- Every action is recorded in the cleanup history.
- No tracking. The only network request is a daily check for a new release.

## Install

1. Download the disk image of the [latest release](https://github.com/xazar-mammadli/XCleaner/releases/latest) and drag XCleaner into Applications.
2. On first launch, open **System Settings › Privacy & Security** and click **Open Anyway**. XCleaner isn't signed with an Apple Developer ID yet.
3. Grant Full Disk Access when XCleaner asks for it.

Updates install from inside the app. XCleaner needs macOS 14 or later.

## Build from source

```bash
git clone https://github.com/xazar-mammadli/XCleaner.git
cd XCleaner
open XCleaner.xcodeproj
```

You need Xcode 26. Run the tests with `swift test --package-path Packages/CleanerCore`.

## Contributing

Issues and pull requests are welcome; see [CONTRIBUTING.md](CONTRIBUTING.md). Please report security problems privately, as [SECURITY.md](SECURITY.md) describes.

## License

[MIT](LICENSE)
