import XCTest
@testable import CodexMonitor

final class DailyUsageBarMetricsTests: XCTestCase {
    func testScaleUsesActualMaximumWithoutAnIsolatedOutlier() {
        let scale = DailyUsageBarScale(tokenCounts: [1_000, 700, 400, 100])

        XCTAssertEqual(scale.displayMaximumTokens, 1_000)
        XCTAssertFalse(scale.hasCappedOutlier)
        XCTAssertFalse(scale.isCapped(1_000))
    }

    func testScaleCapsAnIsolatedOutlierWithHeadroomAboveTypicalUsage() {
        let scale = DailyUsageBarScale(tokenCounts: [2_756, 400, 200, 100])

        XCTAssertEqual(scale.displayMaximumTokens, 480)
        XCTAssertTrue(scale.hasCappedOutlier)
        XCTAssertTrue(scale.isCapped(2_756))
        XCTAssertFalse(scale.isCapped(400))
    }

    func testHeightPreservesLinearUsageRatiosBelowTheOutlierCap() {
        let scale = DailyUsageBarScale(tokenCounts: [2_756, 400, 200, 100])
        let lowerHeight = DailyUsageBarMetrics.height(
            for: 200,
            relativeTo: scale.displayMaximumTokens
        )
        let doubledHeight = DailyUsageBarMetrics.height(
            for: 400,
            relativeTo: scale.displayMaximumTokens
        )

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
