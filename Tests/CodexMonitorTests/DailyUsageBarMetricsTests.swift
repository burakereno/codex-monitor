import XCTest
@testable import CodexMonitor

final class DailyUsageBarMetricsTests: XCTestCase {
    func testHeightPreservesLinearUsageRatiosAboveMinimum() {
        let lowerHeight = DailyUsageBarMetrics.height(for: 250, relativeTo: 1_000)
        let doubledHeight = DailyUsageBarMetrics.height(for: 500, relativeTo: 1_000)

        XCTAssertEqual(doubledHeight, lowerHeight * 2, accuracy: 0.001)
    }

    func testHeightUsesTheAvailableRangeAndKeepsSmallBarsVisible() {
        XCTAssertEqual(
            DailyUsageBarMetrics.height(for: 1_000, relativeTo: 1_000),
            DailyUsageBarMetrics.maximumHeight
        )
        XCTAssertEqual(
            DailyUsageBarMetrics.height(for: 1, relativeTo: 1_000),
            DailyUsageBarMetrics.minimumNonzeroHeight
        )
        XCTAssertEqual(
            DailyUsageBarMetrics.height(for: 0, relativeTo: 1_000),
            DailyUsageBarMetrics.zeroHeight
        )
    }
}
