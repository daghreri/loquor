# Contributing to Loquor

Thanks for helping. Loquor is small on purpose: fast, private dictation that does
one thing well. Changes that keep it that way are the most welcome.

## Set up

You need an Apple Silicon Mac and the Xcode **Command Line Tools**
(`xcode-select --install`). Xcode isn't required.

```bash
scripts/make-dev-cert.sh         # once: local signing identity, so permissions survive rebuilds
scripts/build-app.sh --install   # build, install to /Applications, launch
```

The first launch asks for Microphone and Accessibility and downloads the speech
model (about 450 MB).

## Before you send a pull request

1. `swift run selftest` passes. Add checks for new logic in `Sources/LoquorCore`.
2. You tried the change in the real app (`scripts/build-app.sh --install`): speak,
   and check the text that lands in a real app. Say in the PR what you tested.
3. Logs never contain dictated text, and nothing new leaves the Mac without the
   user turning it on.
4. Dictation is never lost: any new failure path types the raw transcript or keeps
   it for **Copy Last Dictation**.

## Where things are

- `Sources/LoquorCore`: pure logic, testable without a keyboard or microphone.
- `Sources/Loquor`: the app (AppKit and SwiftUI).
- `docs/design.md`: how it works and why.

## Reporting bugs

Open an issue with your Mac model, macOS version, Loquor version, what you did
and what happened. `~/Library/Logs/Loquor/` has timings (never your words) that
often help.
