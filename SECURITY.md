# Security policy

XCleaner removes files and can run tasks as an administrator, so security reports are taken seriously.

## Reporting a problem

Please don't open a public issue. Use **Report a vulnerability** on the [Security tab](https://github.com/xazar-mammadli/XCleaner/security/advisories/new) instead, which only the maintainer can see. Describe the problem, how to reproduce it, and what could go wrong.

You'll hear back within a week. Once a fix is released, the report is published, with credit to you if you like.

Examples of what to report:

- XCleaner removes, moves or changes something it shouldn't, or something outside the folder it scanned.
- A way around `SafetyGuard`, the protected locations or the exclusions.
- A way to misuse the administrator run that removes system files or switches launch daemons.
- A way to make the updater install something that isn't a genuine XCleaner release.

## Supported versions

Only the latest release gets fixes.

## Checking a release

Releases are signed with a self-signed certificate named **xazar-mammadli Code Signing**, SHA-1 fingerprint `320C260282F17537C322BED4C0A932B74FAA5EEF`. Each release lists the SHA-256 of its disk image. To check a download:

```bash
shasum -a 256 XCleaner-1.0.0.dmg
codesign -dv --verbose=2 /Applications/XCleaner.app
```

The second command should show `Authority=xazar-mammadli Code Signing`. XCleaner's updater only installs releases signed with the same certificate.
