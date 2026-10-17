# Contributing to XCleaner

Thanks for helping! Bug reports, ideas, translations and code are all welcome.

## Before you start

- **Bugs and ideas:** open an issue with one of the templates. Search the existing issues first.
- **Larger changes:** open an issue to talk about it before you write the code, so no work goes to waste.
- **Security problems:** don't open a public issue. Report them privately, as [SECURITY.md](SECURITY.md) describes.

Everyone taking part follows the [code of conduct](CODE_OF_CONDUCT.md).

## Setting up

You need macOS 14 or later and Xcode 26 or later.

```bash
git clone https://github.com/<your-account>/XCleaner.git
cd XCleaner
open XCleaner.xcodeproj
```

Run the tests before and after your change:

```bash
swift test --package-path Packages/CleanerCore
xcodebuild -project XCleaner.xcodeproj -scheme XCleaner -configuration Debug -derivedDataPath .build/DerivedData build
```

Debug builds start in Test Mode, so scans work as usual but nothing is removed. Keep it on while you work. Test Mode doesn't exist in release builds.

## Rules for the code

XCleaner removes files, so safety comes before everything else.

- **One way to remove.** Everything that removes files goes through `Cleaner`, which checks each item again with `SafetyGuard` right before it is touched and records it in the history. Never call `removeItem` or `trashItem` on the user's files anywhere else.
- **Allowlists, not guesses.** An item may only be removed from inside the folder its scan looked in. Protected locations, such as the system, Keychains, iCloud Drive, Mail, Photos and SSH keys, stay untouched.
- **Tests with sandboxes.** Every change to scanning or removing comes with tests that work in a throwaway `Sandbox` and a `FakeTrash`. Tests never touch real files.
- **No tricks.** No fake speed-ups, scare messages or inflated numbers. No tracking, analytics or new network requests: the only request XCleaner makes is the daily check for a newer release.
- **Clear words.** Interface text is short and plain, and says what will happen before it happens.

Match the style of the code around your change. The engine in `Packages/CleanerCore` has no interface code; the app in `App` has no file logic of its own.

## Translations

Every piece of interface text lives in `App/Resources/Localizable.xcstrings` and needs an Azerbaijani translation. If you can't write one, say so in the pull request, and the maintainer will add it.

## Pull requests

1. Fork the repository and create a branch from `master`.
2. Keep each pull request to one change, with a short description of what and why. Add screenshots for anything you can see.
3. Make sure CI passes.
4. The maintainer reviews every pull request. Only the maintainer merges into `master` and publishes releases.

By contributing, you agree that your work is published under the [MIT License](LICENSE).

## Releases (maintainer)

Releases are signed with the maintainer's own certificate, made once with `scripts/make-signing-identity.sh`. `scripts/release.sh <version>` builds, signs and packages a release into `.build/release`. Update `MARKETING_VERSION` first, then publish the disk image and its checksum as a GitHub release with a `v<version>` tag.
