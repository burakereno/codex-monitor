import XCTest
@testable import CodexMonitor

@MainActor
final class CodexMonitorModelTests: XCTestCase {
    func testRefreshClearsSnapshotAndShowsMessageAfterFailure() async {
        let reader = MockRateLimitsReader(results: [
            .success(Self.snapshot(usedPercent: 25)),
            .failure(CodexAppServerError.timeout)
        ])
        let model = CodexMonitorModel(codexClient: reader)

        await model.refresh()

        XCTAssertNotNil(model.codexSnapshot)
        XCTAssertNil(model.codexMessage)
        XCTAssertEqual(model.menuBarTitle.providers.first?.primary, "75%")

        await model.refresh()

        XCTAssertNil(model.codexSnapshot)
        XCTAssertEqual(model.codexMessage, CodexAppServerError.timeout.localizedDescription)
        XCTAssertEqual(model.menuBarTitle.providers.first?.primary, "--")
        XCTAssertEqual(model.menuBarTitle.providers.first?.weekly, "--")
    }

    func testRemainingPercentIsClamped() {
        XCTAssertEqual(RateLimitWindow(usedPercent: -10, resetsAt: nil, windowDurationMins: 300).remainingPercent, 100)
        XCTAssertEqual(RateLimitWindow(usedPercent: 45, resetsAt: nil, windowDurationMins: 300).remainingPercent, 55)
        XCTAssertEqual(RateLimitWindow(usedPercent: 125, resetsAt: nil, windowDurationMins: 300).remainingPercent, 0)
    }

    func testVersionComparisonHandlesDifferentSegmentCounts() {
        XCTAssertTrue(UpdateChecker.compare("1.0.1", isNewerThan: "1.0.0"))
        XCTAssertTrue(UpdateChecker.compare("1.1", isNewerThan: "1.0.9"))
        XCTAssertFalse(UpdateChecker.compare("1.0.0", isNewerThan: "1.0"))
        XCTAssertFalse(UpdateChecker.compare("1.0.0", isNewerThan: "1.0.1"))
    }

    private static func snapshot(usedPercent: Int) -> RateLimitsSnapshot {
        RateLimitsSnapshot(
            limitId: "codex",
            limitName: "Codex",
            primary: RateLimitWindow(usedPercent: usedPercent, resetsAt: nil, windowDurationMins: 300),
            secondary: RateLimitWindow(usedPercent: 10, resetsAt: nil, windowDurationMins: 10_080),
            credits: nil,
            planType: nil,
            rateLimitReachedType: nil
        )
    }
}

private actor MockRateLimitsReader: RateLimitsReading {
    private var results: [Result<RateLimitsSnapshot, Error>]

    init(results: [Result<RateLimitsSnapshot, Error>]) {
        self.results = results
    }

    func readRateLimits() async throws -> RateLimitsSnapshot {
        let result = results.isEmpty ? Result<RateLimitsSnapshot, Error>.failure(CodexAppServerError.missingRateLimits) : results.removeFirst()
        return try result.get()
    }
}
