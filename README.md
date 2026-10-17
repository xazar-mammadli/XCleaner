<p align="center">
  <img src="docs/images/icon.png" width="128" height="128" alt="XCleaner app icon">
</p>

<h1 align="center">XCleaner</h1>

<p align="center">
  A native macOS cleaner with a clean, safe and simple interface.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-111111?logo=apple&logoColor=white" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white" alt="Swift 6">
  <img src="https://img.shields.io/badge/UI-SwiftUI-0A84FF" alt="SwiftUI">
  <a href="https://github.com/xazar-mammadli/XCleaner/releases/latest"><img src="https://img.shields.io/github/v/release/xazar-mammadli/XCleaner?label=release" alt="Latest release"></a>
  <a href="https://github.com/xazar-mammadli/XCleaner/actions/workflows/ci.yml"><img src="https://github.com/xazar-mammadli/XCleaner/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green" alt="License: MIT"></a>
</p>

<p align="center">
  <img src="docs/images/cleanup.jpg" width="820" alt="XCleaner reviewing junk found by a scan">
</p>

## About

XCleaner finds the clutter that builds up on a Mac and helps you remove it without putting anything important at risk. That clutter includes caches, logs, files left behind by deleted apps, old installers and duplicates.

It aims to cover what popular commercial cleaners do, but more calmly and openly. There are no scare tactics and no inflated numbers, and nothing is ever removed behind your back.

Everything in the [feature table](#features) works today: cleanup of system junk, installers, downloads and the Trash, a complete app uninstaller, a finder for files left behind by deleted apps, a disk map, finders for big files and duplicates, a monitor for heavy apps, a startup items manager, maintenance tasks, extensions, browser data, app permissions, a background item check, hidden files, a menu bar monitor and a full cleanup history.

## Download

Get the disk image of the [latest release](https://github.com/xazar-mammadli/XCleaner/releases/latest), open it, and drag XCleaner into the Applications folder.

> [!IMPORTANT]
> XCleaner is signed, but not with an Apple Developer ID yet, so macOS can't check it with Apple. The first time you open it, macOS says it can't verify the developer. Open **System Settings › Privacy & Security**, scroll down and click **Open Anyway** next to the message about XCleaner. You only need to do this once.

XCleaner then walks you through granting Full Disk Access, which it needs to see caches and app leftovers in protected folders.

**Updates.** Once a day, XCleaner asks GitHub whether a newer release exists, and offers to install it. It installs only releases signed with the same certificate as the copy you have, so Full Disk Access stays granted. You can turn the check off under Settings › General. To check a download yourself, see [SECURITY.md](SECURITY.md#checking-a-release).

## Safety first

Every removal passes through a single gate that checks the item again right before it is touched.

- **Nothing is removed until you review it.** Scans only produce a list, and you decide what goes.
- **The Trash comes first.** By default removed items go to the Trash, so you can put them back. Files you pick yourself, such as large files or duplicates, always go to the Trash.
- **An allowlist, not a guess.** An item can only be removed from inside the folder its scan looked in. Symlinks are never followed, and `..` tricks are refused.
- **Protected locations stay untouched.** XCleaner never removes macOS system folders, Keychains, iCloud Drive and other cloud storage, Mail, Messages or the Photos library. Automatic cleanup rules never reach into your personal folders, such as Desktop, Documents and Downloads.
- **App bundles stay sealed.** XCleaner never edits files inside an app, so code signatures stay valid.
- **One copy always stays.** Duplicates are compared by content, and a copy only goes while another one stays, unchanged since the scan. Merging folders moves files within one disk without ever replacing anything, and every move is recorded.
- **Keys and passwords stay put.** SSH and GnuPG keys and the sign-ins of command-line tools such as `~/.aws` or `~/.docker/config.json` are never removed, nor is any folder that holds them.
- **Root only when you ask, and only for that.** Removing system files, switching launch daemons and maintenance tasks ask for your password each time. XCleaner then runs itself as root for that one job, checks every path again against a short list of system folders, and exits. Nothing keeps running in the background with those rights.
- **A full history.** Every action is recorded in a local log in `~/Library/Logs/XCleaner` and listed under Utilities.
- **Exclusions.** Folders you add under Settings › Exclusions are never scanned or removed.
- **Apps in use are left alone.** Files that belong to a running app are flagged and left unselected.
- **Test Mode.** Scan and review as usual while nothing is removed. Debug builds start with Test Mode on.
- **Private by design.** Your files never leave your Mac, and XCleaner collects no data. The only request it makes is the daily check for a newer release, which sends nothing about your Mac.
- **Genuine updates only.** An update replaces XCleaner only when its signature matches the copy you have. The previous version goes to the Trash.

## Features

| Area | Tools | Status |
|---|---|---|
| Overview | Disk usage, Full Disk Access status, one-click scan | Available |
| Cleanup | System junk, installers and downloads, Trash bins | Available |
| | System-level junk (asks for your password) | Available |
| | Mail attachments | Available |
| Applications | Uninstaller, remaining files of deleted apps, app reset | Available |
| | Extensions | Available |
| Performance | Heavy apps, startup items, maintenance tasks | Available |
| Files | Biggest and old files | Available |
| | Duplicates, with Smart Select and folder merging | Available |
| | Disk map | Available |
| Privacy | Browser data | Available |
| | App permissions, background item check | Available |
| Utilities | Cleanup history | Available |
| | Menu bar monitor | Available |
| | Hidden files | Available |

## Screenshots

| Overview | Safety settings |
|---|---|
| <img src="docs/images/overview.jpg" width="400" alt="Overview screen with disk usage"> | <img src="docs/images/settings-safety.jpg" width="400" alt="Safety settings"> |

## Requirements

- macOS 14 Sonoma or later
- Xcode 26 or later, to build from source

## Building from source

```bash
git clone https://github.com/xazar-mammadli/XCleaner.git
cd XCleaner
open XCleaner.xcodeproj
```

In Xcode, choose the **XCleaner** scheme and press **Run** (⌘R). Debug builds start in Test Mode, where scans work as usual but nothing is removed.

To build from the terminal instead:

```bash
xcodebuild -project XCleaner.xcodeproj -scheme XCleaner -configuration Debug -derivedDataPath .build/DerivedData build
open .build/DerivedData/Build/Products/Debug/XCleaner.app
```

### Full Disk Access

XCleaner needs Full Disk Access to see caches, logs and app leftovers in protected folders. On first launch, the app walks you through granting it under System Settings › Privacy & Security › Full Disk Access.

macOS ties this permission to the app's code signature. Builds that are only signed to run locally get a new signature every time, so you may need to grant the permission again after each build. To avoid that, choose your team under **Signing & Capabilities** in Xcode. A free personal team is enough. Releases don't have this problem: they are all signed with the same certificate.

## Running tests

Unit tests cover the safety engine. They run in throwaway folders and never touch your real files:

```bash
swift test --package-path Packages/CleanerCore
```

In Xcode, ⌘U runs the same tests through the XCleaner scheme.

## Project structure

```
XCleaner/
├── App/                        SwiftUI app (interface only)
│   ├── DesignSystem/           Shared components
│   ├── Features/               Overview, onboarding, settings and section screens
│   ├── Navigation/             Sidebar and window layout
│   ├── Resources/              App icon, colors, Localizable.xcstrings
│   └── Support/                Preferences and helpers
├── .github/                    CI, issue and pull request templates, code owners
├── Packages/CleanerCore/       Cleaning engine (no UI)
│   ├── Sources/CleanerCore/
│   │   ├── Apps/               App inventory, leftovers, remaining files, extensions
│   │   ├── Cleaning/           Cleaner, Trash handling, audit log
│   │   ├── DiskMap/            Folder tree and treemap layout
│   │   ├── Duplicates/         Duplicate files and folders, Smart Select, folder merging
│   │   ├── HiddenFiles/        Hidden items, Finder's hidden flag and setting
│   │   ├── Model/              Cleanable items and safety levels
│   │   ├── Performance/        Process usage, launch agents and login items
│   │   ├── Privacy/            Browser data, app permissions, background item check
│   │   ├── Privileged/         The one-off root run behind administrator tasks
│   │   ├── Safety/             SafetyGuard and SafetyPolicy
│   │   ├── Scanning/           Scanners for junk, downloads, the Trash and big files
│   │   ├── System/             Full Disk Access check, disk, memory, processor, GPU, network and battery
│   │   └── Updates/            Release check and signature-checked self-update
│   └── Tests/CleanerCoreTests/
├── docs/images/                Images used in this README
├── scripts/                    Signing identity and release packaging
└── XCleaner.xcodeproj
```

## Localization

The interface is available in English and Azerbaijani. XCleaner follows the macOS language by default, and you can switch under **Settings › General › Language**. All strings are in `App/Resources/Localizable.xcstrings`.

## Roadmap

- [x] **Phase 0: Foundation.** Safety engine, app shell, Full Disk Access guide, settings, English and Azerbaijani.
- [x] **Phase 1: Cleanup basics.** Quick and deep cleanup, biggest and old files, cleanup history, exclusions.
- [x] **Phase 2: Applications and disk map.** Uninstaller, remaining files, app reset, disk map.
- [x] **Phase 3: System tools.** System-level junk and other administrator tasks without a resident helper, maintenance, startup items, heavy apps, Mail attachments, extensions, browser data and a menu bar monitor.
- [x] **Phase 4: Advanced tools.** Duplicates with Smart Select and folder merging, app permissions, background item check and hidden files.
- [x] **Phase 5: Release.** Signed releases on GitHub, a DMG installer, and updates that install themselves.
- [ ] **Later.** Signing with an Apple Developer ID and notarization, so macOS no longer asks on first launch.

## Contributing

Bug reports, ideas, translations and pull requests are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) before you start; for larger changes, open an issue first.

- Every pull request is reviewed by the maintainer, and CI must pass. Only the maintainer merges into `master` and publishes releases.
- Any code that removes files must go through `Cleaner` and `SafetyGuard` and must come with tests.
- Report security problems privately, as [SECURITY.md](SECURITY.md) describes.
- Everyone taking part follows the [code of conduct](CODE_OF_CONDUCT.md).

## License

XCleaner is available under the MIT License. See [LICENSE](LICENSE) for details.
