# Codex Monitor

<p align="center">
  <img src="Sources/CodexStatus/Resources/codex.svg" alt="Codex Monitor" width="128" height="128">
</p>

**Lightweight macOS menu bar Codex usage monitor.** Track 5-hour usage, weekly usage, reset times, and credits at a glance — right from your menu bar.

<p align="center">
  <a href="https://github.com/burakereno/codex-monitor/releases/latest/download/CodexMonitor.dmg">
    <img src="https://img.shields.io/badge/Download-CodexMonitor.dmg-22c55e?style=for-the-badge&logo=apple&logoColor=white&cb=2" alt="Download CodexMonitor.dmg" height="48">
  </a>
  &nbsp;
  <a href="https://github.com/burakereno/codex-monitor/releases/latest">
    <img src="https://img.shields.io/github/v/release/burakereno/codex-monitor?style=for-the-badge&label=Latest&color=2563eb&cb=2" alt="Latest release" height="48">
  </a>
</p>

<p align="center">
  <sub>macOS 13.0+ · local Codex state only · See <a href="#installation">Installation</a> for first-launch instructions</sub>
</p>

## Features

- **5-hour usage** — current Codex rolling-window usage and reset time
- **Weekly usage** — weekly quota status and reset time
- **Credits** — available credit balance when reported by Codex
- **Menu bar display modes** — compact native status item layouts
- **Refresh + dashboard** — manual refresh and quick access to the Codex dashboard
- **Local-only reads** — uses `codex app-server --listen stdio://`; it does not start Codex tasks or send prompts to a model
- **Native macOS** — SwiftUI + AppKit, runs as a menu bar app

## Installation

### Download DMG

1. Go to the [Releases](../../releases/latest) page
2. Download **`CodexMonitor.dmg`**
3. Open the DMG and drag **CodexStatus.app** to your **Applications** folder

### Important: First Launch (Unsigned App)

Since Codex Monitor is not notarized by Apple, macOS may block it on first launch. To fix this, run the following command in Terminal **once** after installing:

```bash
xattr -cr /Applications/CodexStatus.app
```

Then double-click CodexStatus to launch it. The app appears in your menu bar and is shown as **Token Monitor**.

## Build from Source

### Requirements

- macOS 13.0+
- Xcode 16.0+
- Codex installed and logged in locally

### Steps

```bash
git clone https://github.com/burakereno/codex-monitor.git
cd codex-monitor

./scripts/build-app.sh
open .build/CodexStatus.app
```

## Tech Stack

- **SwiftUI** — popover UI
- **AppKit** — NSStatusItem, NSPopover, app lifecycle
- **Swift Package Manager** — build system
- **Codex app server** — local rate-limit state via stdio
