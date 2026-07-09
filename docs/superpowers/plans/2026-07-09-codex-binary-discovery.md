# Codex Binary Discovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore Codex Monitor data after the Codex executable moved from `Codex.app` into `ChatGPT.app`, while keeping older installations working and showing local usage when rate limits are unavailable.

**Architecture:** Extract executable discovery into a small injectable locator. Resolve the installed Codex application through its stable bundle identifier first, then try explicit new, legacy, and command-line fallback paths. Keep local session-log presentation independent from app-server rate-limit availability.

**Tech Stack:** Swift 5.9, Swift Package Manager, AppKit `NSWorkspace`, SwiftUI, XCTest

## Global Constraints

- Support macOS 14.0 and newer.
- Read rate limits only through `codex app-server --listen stdio://`.
- Do not start Codex tasks or send prompts to a model.
- Preserve conservative 120-second polling.
- Preserve compatibility with both `ChatGPT.app` and legacy `Codex.app` installations.
- Do not create a git commit unless the user requests one.

---

### Task 1: Add executable-discovery regression coverage

**Files:**
- Modify: `Tests/CodexMonitorTests/CodexMonitorModelTests.swift`

**Interfaces:**
- Consumes: `CodexBinaryLocator.init(applicationURLProvider:fallbackPaths:)`
- Produces: coverage proving that a bundle resolved by identifier is converted to `Contents/Resources/codex` and must be executable

- [x] **Step 1: Add a failing test for the new ChatGPT bundle layout**

```swift
func testBinaryLocatorFindsCodexInsideResolvedApplicationBundle() throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("CodexBinaryLocatorTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let appURL = rootURL.appendingPathComponent("ChatGPT.app")
    let binaryURL = appURL.appendingPathComponent("Contents/Resources/codex")
    try FileManager.default.createDirectory(
        at: binaryURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    XCTAssertTrue(FileManager.default.createFile(atPath: binaryURL.path, contents: Data()))
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: binaryURL.path
    )

    let locator = CodexBinaryLocator(
        applicationURLProvider: { appURL },
        fallbackPaths: []
    )

    XCTAssertEqual(try locator.locate(), binaryURL)
}
```

- [x] **Step 2: Run the focused test and verify it fails before implementation**

Run: `swift test --filter CodexMonitorModelTests/testBinaryLocatorFindsCodexInsideResolvedApplicationBundle`

Expected: compilation fails because `CodexBinaryLocator` is not defined.

### Task 2: Implement robust Codex executable discovery

**Files:**
- Modify: `Sources/CodexMonitor/CodexAppServerClient.swift`

**Interfaces:**
- Consumes: application URL from `NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")`
- Produces: `CodexBinaryLocator.locate() throws -> URL`

- [x] **Step 1: Add AppKit and the injectable locator**

```swift
import AppKit
import Foundation

struct CodexBinaryLocator: @unchecked Sendable {
    private let fileManager: FileManager
    private let applicationURLProvider: () -> URL?
    private let fallbackPaths: [String]

    init(
        fileManager: FileManager = .default,
        applicationURLProvider: @escaping () -> URL? = {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")
        },
        fallbackPaths: [String] = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/usr/bin/codex"
        ]
    ) {
        self.fileManager = fileManager
        self.applicationURLProvider = applicationURLProvider
        self.fallbackPaths = fallbackPaths
    }

    func locate() throws -> URL {
        var candidates: [URL] = []
        if let applicationURL = applicationURLProvider() {
            candidates.append(applicationURL.appendingPathComponent("Contents/Resources/codex"))
        }
        candidates.append(contentsOf: fallbackPaths.map(URL.init(fileURLWithPath:)))

        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        throw CodexAppServerError.codexBinaryNotFound
    }
}
```

- [x] **Step 2: Inject the locator into the app-server client**

```swift
final class CodexAppServerClient: RateLimitsReading, @unchecked Sendable {
    private let decoder = JSONDecoder()
    private let binaryLocator: CodexBinaryLocator

    init(binaryLocator: CodexBinaryLocator = CodexBinaryLocator()) {
        self.binaryLocator = binaryLocator
    }
}
```

Replace `locateCodexBinary()` with `binaryLocator.locate()` and remove the old hard-coded method.

- [x] **Step 3: Run the focused test and full test suite**

Run: `swift test --filter CodexMonitorModelTests/testBinaryLocatorFindsCodexInsideResolvedApplicationBundle`

Expected: the focused test passes.

Run: `swift test`

Expected: all tests pass.

### Task 3: Decouple local usage presentation from rate-limit availability

**Files:**
- Modify: `Sources/CodexMonitor/StatusPanelView.swift`

**Interfaces:**
- Consumes: `CodexUsageSummary` already loaded from `~/.codex/sessions`
- Produces: usage cards rendered whether or not `RateLimitsSnapshot` exists

- [x] **Step 1: Make the provider accessory independent of a snapshot**

Change `@ViewBuilder let accessory: (RateLimitsSnapshot) -> Accessory` to `@ViewBuilder let accessory: () -> Accessory`, remove the unused closure argument at the call site, and render `accessory()` after the snapshot/error conditional.

- [x] **Step 2: Compile and test the SwiftUI change**

Run: `swift test`

Expected: all tests pass and the app target compiles.

### Task 4: Verify the native macOS app

**Files:**
- Verify: `.build/Codex Monitor.app`

**Interfaces:**
- Consumes: the project-local `scripts/build-app.sh` workflow required by `AGENTS.md`
- Produces: a freshly built and running menu bar application

- [x] **Step 1: Run the required verification loop**

```sh
pkill -x CodexMonitor || true
./scripts/build-app.sh
open ".build/Codex Monitor.app"
```

Expected: release build and signing succeed, `open` returns successfully, and `pgrep -x CodexMonitor` finds the relaunched process.

- [x] **Step 2: Verify the executable actually resolves and the app-server protocol still responds**

Run a read-only diagnostic against the resolved executable using `initialize`, `initialized`, and `account/rateLimits/read`.

Expected: initialization succeeds and the result contains `rateLimits` plus a `codex` entry in `rateLimitsByLimitId`.
