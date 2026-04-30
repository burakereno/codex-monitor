# Agent Instructions

This project is a native macOS menu bar app built with Swift Package Manager, SwiftUI, and AppKit.

## Project Commands

- Build debug: `swift build`
- Run debug: `swift run CodexStatus`
- Build app bundle: `./scripts/build-app.sh`
- Run app bundle: `open .build/CodexStatus.app`
- Kill local app: `pkill -x CodexStatus || true`

## Required Local Verification Loop

After making any change, always run this sequence before handing off:

```sh
pkill -x CodexStatus || true
./scripts/build-app.sh
open .build/CodexStatus.app
```

The goal is to verify that the local menu bar app rebuilds and launches after every edit.

## Codex Usage Safety

- Do not start Codex tasks or send prompts to a model from this app.
- The app should only read local rate-limit state through `codex app-server --listen stdio://`.
- Keep polling conservative unless an event-based path is implemented and verified.

## App Design

- Keep the app as native as possible: AppKit status item, SwiftUI popover, system symbols, native controls.
- The menu bar item should remain compact.
- The popover should show 5-hour usage, weekly usage, reset times, credits, refresh, dashboard, and quit.

