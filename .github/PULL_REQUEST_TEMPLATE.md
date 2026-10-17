## What and why

<!-- What does this change, and why? Link the issue it closes, if any: "Closes #123". -->

## How it was checked

<!-- Tests you added or ran, and what you tried in the app. Screenshots for anything you can see. -->

## Checklist

- [ ] `swift test --package-path Packages/CleanerCore` passes, and the app builds.
- [ ] Anything that removes or moves files goes through `Cleaner` and `SafetyGuard`, and comes with tests that use a sandbox.
- [ ] New interface text is in `Localizable.xcstrings`, translated into Azerbaijani, Russian and Turkish, or with a note that translations are needed.
- [ ] No new network requests, tracking or third-party services.
