# Codex Reset Credits Display Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Display available Codex usage-limit reset rights and their expiration dates in Codex Monitor without exposing any control that consumes a reset.

**Architecture:** Decode the optional top-level `rateLimitResetCredits` object already returned by `account/rateLimits/read`, return it alongside the existing rate-limit snapshot, and publish it through the app model. Render the summary in a dedicated read-only SwiftUI card with stable credit identity and locale-aware expiration dates.

**Tech Stack:** Swift 5.9, Swift Package Manager, Foundation JSON decoding, Combine `ObservableObject`, SwiftUI, XCTest

## Global Constraints

- Support macOS 14.0 and newer.
- Read account state only through `codex app-server --listen stdio://`.
- Do not call `account/rateLimitResetCredit/consume`.
- Do not add a `Use reset` button or any other reset-consumption action.
- Keep the existing 120-second polling interval and manual refresh behavior.
- Treat `rateLimitResetCredits`, `credits`, titles, descriptions, and expiration timestamps as optional backend data.
- Treat `availableCount` as authoritative because the backend may cap the detail list.

---

### Task 1: Decode reset-credit summaries

**Files:**
- Modify: `Tests/CodexMonitorTests/CodexMonitorModelTests.swift`
- Modify: `Sources/CodexMonitor/Models.swift`

**Interfaces:**
- Consumes: top-level `rateLimitResetCredits` from `account/rateLimits/read`
- Produces: `RateLimitResetCreditsSummary` and `RateLimitResetCredit`

- [x] **Step 1: Add a failing response-decoding test**

```swift
func testRateLimitsResponseDecodesResetCredits() throws {
    let data = Data(#"""
    {
      "rateLimits": {},
      "rateLimitResetCredits": {
        "availableCount": 3,
        "credits": [{
          "id": "reset-1",
          "title": "Full reset (Weekly + 5 hr)",
          "description": "Promotional reset",
          "resetType": "codexRateLimits",
          "status": "available",
          "grantedAt": 1783730493,
          "expiresAt": 1784335293
        }]
      }
    }
    """#.utf8)

    let response = try JSONDecoder().decode(RateLimitsResponse.self, from: data)

    XCTAssertEqual(response.rateLimitResetCredits?.availableCount, 3)
    XCTAssertEqual(response.rateLimitResetCredits?.credits?.first?.id, "reset-1")
    XCTAssertEqual(
        response.rateLimitResetCredits?.credits?.first?.expirationDate,
        Date(timeIntervalSince1970: 1_784_335_293)
    )
}
```

- [x] **Step 2: Run the focused test and verify red**

Run: `swift test --filter CodexMonitorModelTests/testRateLimitsResponseDecodesResetCredits`

Expected: compilation fails because reset-credit response models do not exist.

- [x] **Step 3: Add the minimal decoding models**

```swift
struct RateLimitsResponse: Decodable {
    let rateLimits: RateLimitsSnapshot
    let rateLimitsByLimitId: [String: RateLimitsSnapshot]?
    let rateLimitResetCredits: RateLimitResetCreditsSummary?
}

struct RateLimitResetCreditsSummary: Decodable, Equatable {
    let availableCount: Int
    let credits: [RateLimitResetCredit]?
}

struct RateLimitResetCredit: Decodable, Equatable, Identifiable {
    let id: String
    let title: String?
    let description: String?
    let resetType: String
    let status: String
    let grantedAt: Int
    let expiresAt: Int?

    var expirationDate: Date? {
        expiresAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }
}
```

- [x] **Step 4: Run the focused test and verify green**

Run: `swift test --filter CodexMonitorModelTests/testRateLimitsResponseDecodesResetCredits`

Expected: the decoding test passes.

### Task 2: Publish reset credits through refresh state

**Files:**
- Modify: `Tests/CodexMonitorTests/CodexMonitorModelTests.swift`
- Modify: `Sources/CodexMonitor/Models.swift`
- Modify: `Sources/CodexMonitor/CodexAppServerClient.swift`
- Modify: `Sources/CodexMonitor/CodexMonitorModel.swift`

**Interfaces:**
- Consumes: decoded `RateLimitsResponse`
- Produces: `CodexAccountSnapshot` and `CodexMonitorModel.rateLimitResetCredits`

- [x] **Step 1: Add a failing refresh-state test**

```swift
func testRefreshPublishesResetCredits() async {
    let summary = RateLimitResetCreditsSummary(availableCount: 3, credits: nil)
    let reader = MockRateLimitsReader(results: [
        .success(CodexAccountSnapshot(
            rateLimits: Self.snapshot(usedPercent: 25),
            rateLimitResetCredits: summary
        ))
    ])
    let model = CodexMonitorModel(codexClient: reader, codexUsageReader: MockUsageSummaryReader())

    await model.refresh()

    XCTAssertEqual(model.rateLimitResetCredits, summary)
}
```

- [x] **Step 2: Run the focused test and verify red**

Run: `swift test --filter CodexMonitorModelTests/testRefreshPublishesResetCredits`

Expected: compilation fails because the account snapshot and published reset state are not implemented.

- [x] **Step 3: Return one composite account snapshot per read**

```swift
struct CodexAccountSnapshot {
    let rateLimits: RateLimitsSnapshot
    let rateLimitResetCredits: RateLimitResetCreditsSummary?
}
```

Change `CodexAccountReading.readRateLimits()` to return `CodexAccountSnapshot`. In `CodexAppServerClient`, select the `codex` rate-limit snapshot as before and return it together with `decoded.rateLimitResetCredits` from the same response.

- [x] **Step 4: Publish and clear reset state with rate-limit state**

```swift
@Published private(set) var rateLimitResetCredits: RateLimitResetCreditsSummary?
```

On refresh success, assign both fields from `CodexAccountSnapshot`. On refresh failure, clear both fields and preserve the existing error behavior.

- [x] **Step 5: Run the focused test and full model tests**

Run: `swift test --filter CodexMonitorModelTests/testRefreshPublishesResetCredits`

Expected: the refresh-state test passes.

Run: `swift test --filter CodexMonitorModelTests`

Expected: all model tests pass.

### Task 3: Render the read-only reset card

**Files:**
- Modify: `Sources/CodexMonitor/StatusPanelView.swift`

**Interfaces:**
- Consumes: `CodexMonitorModel.rateLimitResetCredits`
- Produces: `RateLimitResetCreditsCardView` and stable `RateLimitResetCreditRowView` rows

- [x] **Step 1: Insert the optional card below the rate-limit windows**

```swift
if let resetCredits = model.rateLimitResetCredits {
    RateLimitResetCreditsCardView(summary: resetCredits)
}
```

Place it before daily and token usage cards so it follows the weekly window.

- [x] **Step 2: Build the read-only card and rows**

Use `CardHeaderView` with `arrow.counterclockwise.circle`, `Usage limit resets`, and `N available`. Render returned credits with `ForEach(summary.credits ?? [])`, using the opaque backend `id`. Each row shows the backend title and a locale-aware expiration date through SwiftUI `Text` date formatting. When details are missing, show a neutral count-aware explanation. Add no buttons, gestures, or consume calls.

- [x] **Step 3: Add accessibility semantics**

Hide decorative SF Symbols and combine each title/expiration row into one VoiceOver element. Keep all content read-only and use built-in text styles or the app's existing dynamic text conventions.

- [x] **Step 4: Compile and run the full suite**

Run: `swift test`

Expected: all tests pass and the SwiftUI target compiles.

### Task 4: Verify the native macOS bundle and live read path

**Files:**
- Verify: `.build/Codex Monitor.app`

**Interfaces:**
- Consumes: `scripts/build-app.sh` and the required verification loop in `AGENTS.md`
- Produces: a freshly built and running Codex Monitor app

- [x] **Step 1: Run the required verification loop**

```sh
pkill -x CodexMonitor || true
./scripts/build-app.sh
open ".build/Codex Monitor.app"
```

Expected: release build and signing succeed, the app opens, and `pgrep -x CodexMonitor` returns a process.

- [x] **Step 2: Confirm the live read-only response still includes reset rights**

Send only `initialize`, `initialized`, and `account/rateLimits/read` to the resolved Codex binary. Do not send `account/rateLimitResetCredit/consume`.

Expected: `rateLimitResetCredits.availableCount` is readable and no reset status changes.
