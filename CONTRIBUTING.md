# Contributing

Thanks for wanting to help. Point and Yap is small on purpose: it should stay simple, local and fast.

## Before you start

- For a bug, open an issue with the bug template first.
- For a feature, open an issue to talk about it before writing code, so nobody builds something that does not fit.
- Small fixes (typos, docs, a clear bug with a test) can go straight to a pull request.

## Build and test

You need macOS 26 and Xcode 26 (Swift 6.2 or later).

```bash
swift build
swift test
```

The tests run against a synthetic recording in a temporary folder and never touch `~/PointAndYap`.
`.build/debug/PointAndYap --render-ui <dir>` draws the window, the pill and Settings as PNGs for a design check.

## Pull requests

- One change per pull request, with a test when it changes behaviour.
- Keep it local: no network calls, analytics or accounts. Everything a recording holds stays on the user's Mac.
- Never commit a real recording. Use example data in tests and screenshots.
- UI text: short, sentence case, no em dashes.

By contributing you agree that your contribution is licensed under the MIT licence of this project.
