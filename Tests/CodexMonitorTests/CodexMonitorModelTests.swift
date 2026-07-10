import XCTest
@testable import CodexMonitor

@MainActor
final class CodexMonitorModelTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: LimitDisplayMode.storageKey)
        UserDefaults.standard.removeObject(forKey: MenuBarDisplayVersion.storageKey)
        UserDefaults.standard.removeObject(forKey: MenuBarResetTimePreference.storageKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: LimitDisplayMode.storageKey)
        UserDefaults.standard.removeObject(forKey: MenuBarDisplayVersion.storageKey)
        UserDefaults.standard.removeObject(forKey: MenuBarResetTimePreference.storageKey)
        super.tearDown()
    }

    func testRefreshClearsSnapshotAndShowsMessageAfterFailure() async {
        let resetCredits = RateLimitResetCreditsSummary(availableCount: 3, credits: nil)
        let reader = MockRateLimitsReader(results: [
            .success(Self.accountSnapshot(
                usedPercent: 25,
                rateLimitResetCredits: resetCredits
            )),
            .failure(CodexAppServerError.timeout)
        ])
        let model = CodexMonitorModel(codexClient: reader, codexUsageReader: MockUsageSummaryReader())

        await model.refresh()

        XCTAssertNotNil(model.codexSnapshot)
        XCTAssertEqual(model.rateLimitResetCredits, resetCredits)
        XCTAssertNil(model.codexMessage)
        XCTAssertEqual(model.menuBarTitle.providers.first?.primary, "75%")

        await model.refresh()

        XCTAssertNil(model.codexSnapshot)
        XCTAssertNil(model.rateLimitResetCredits)
        XCTAssertEqual(model.codexMessage, CodexAppServerError.timeout.localizedDescription)
        XCTAssertEqual(model.menuBarTitle.providers.first?.primary, "--")
        XCTAssertEqual(model.menuBarTitle.providers.first?.weekly, "--")
    }

    func testRemainingPercentIsClamped() {
        XCTAssertEqual(RateLimitWindow(usedPercent: -10, resetsAt: nil, windowDurationMins: 300).remainingPercent, 100)
        XCTAssertEqual(RateLimitWindow(usedPercent: 45, resetsAt: nil, windowDurationMins: 300).remainingPercent, 55)
        XCTAssertEqual(RateLimitWindow(usedPercent: 125, resetsAt: nil, windowDurationMins: 300).remainingPercent, 0)
    }

    func testCompactResetTextUsesMinutesHoursAndDays() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertEqual(
            RateLimitWindow(
                usedPercent: 10,
                resetsAt: Int(now.addingTimeInterval(35 * 60).timeIntervalSince1970),
                windowDurationMins: 300
            ).compactResetText(relativeTo: now),
            "35m"
        )
        XCTAssertEqual(
            RateLimitWindow(
                usedPercent: 10,
                resetsAt: Int(now.addingTimeInterval(90 * 60).timeIntervalSince1970),
                windowDurationMins: 300
            ).compactResetText(relativeTo: now),
            "2h"
        )
        XCTAssertEqual(
            RateLimitWindow(
                usedPercent: 10,
                resetsAt: Int(now.addingTimeInterval(3 * 24 * 60 * 60).timeIntervalSince1970),
                windowDurationMins: 10_080
            ).compactResetText(relativeTo: now),
            "3d"
        )
    }

    func testMenuBarTitleIncludesResetTimesWhenEnabled() async {
        let now = Date()
        UserDefaults.standard.set(true, forKey: MenuBarResetTimePreference.storageKey)
        let reader = MockRateLimitsReader(results: [
            .success(Self.accountSnapshot(
                usedPercent: 25,
                primaryResetsAt: Int(now.addingTimeInterval(90 * 60).timeIntervalSince1970),
                secondaryResetsAt: Int(now.addingTimeInterval(3 * 24 * 60 * 60).timeIntervalSince1970)
            ))
        ])
        let model = CodexMonitorModel(codexClient: reader, codexUsageReader: MockUsageSummaryReader())

        await model.refresh()

        XCTAssertEqual(model.menuBarTitle.providers.first?.primaryReset, "2h")
        XCTAssertEqual(model.menuBarTitle.providers.first?.weeklyReset, "3d")
    }

    func testRefreshUpdatesUsageSummary() async {
        let reader = MockRateLimitsReader(results: [
            .success(Self.accountSnapshot(usedPercent: 25))
        ])
        let usageSummary = Self.usageSummary(totalTokens: 42)
        let model = CodexMonitorModel(
            codexClient: reader,
            codexUsageReader: MockUsageSummaryReader(summary: usageSummary)
        )

        await model.refresh()

        XCTAssertEqual(model.codexUsageSummary.today.totalTokens, 42)
    }

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

    func testVersionComparisonHandlesDifferentSegmentCounts() {
        XCTAssertTrue(UpdateChecker.compare("1.0.1", isNewerThan: "1.0.0"))
        XCTAssertTrue(UpdateChecker.compare("1.1", isNewerThan: "1.0.9"))
        XCTAssertFalse(UpdateChecker.compare("1.0.0", isNewerThan: "1.0"))
        XCTAssertFalse(UpdateChecker.compare("1.0.0", isNewerThan: "1.0.1"))
    }

    func testReleaseInfoNormalizesResolvedLatestURL() throws {
        let url = try XCTUnwrap(URL(string: "https://github.com/burakereno/codex-monitor/releases/tag/v1.0.8"))

        let info = try UpdateChecker.releaseInfo(fromResolvedLatestURL: url)

        XCTAssertEqual(info.version, "1.0.8")
        XCTAssertEqual(
            info.downloadURL.absoluteString,
            "https://github.com/burakereno/codex-monitor/releases/download/v1.0.8/CodexMonitor.dmg"
        )
    }

    func testReleaseInfoThrowsWhenLatestURLDidNotResolveToTag() throws {
        let url = try XCTUnwrap(URL(string: "https://github.com/burakereno/codex-monitor/releases/latest"))

        XCTAssertThrowsError(try UpdateChecker.releaseInfo(fromResolvedLatestURL: url)) { error in
            XCTAssertEqual(error.localizedDescription, "GitHub release is missing a version tag")
        }
    }

    func testRateLimitsResponseDecodesResetCredits() throws {
        let data = Data(
            """
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
            """.utf8
        )

        let response = try JSONDecoder().decode(RateLimitsResponse.self, from: data)

        XCTAssertEqual(response.rateLimitResetCredits?.availableCount, 3)
        XCTAssertEqual(response.rateLimitResetCredits?.credits?.first?.id, "reset-1")
        XCTAssertEqual(
            response.rateLimitResetCredits?.credits?.first?.expirationDate,
            Date(timeIntervalSince1970: 1_784_335_293)
        )
    }

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

    private static func snapshot(
        usedPercent: Int,
        primaryResetsAt: Int? = nil,
        secondaryResetsAt: Int? = nil
    ) -> RateLimitsSnapshot {
        RateLimitsSnapshot(
            limitId: "codex",
            limitName: "Codex",
            primary: RateLimitWindow(usedPercent: usedPercent, resetsAt: primaryResetsAt, windowDurationMins: 300),
            secondary: RateLimitWindow(usedPercent: 10, resetsAt: secondaryResetsAt, windowDurationMins: 10_080),
            credits: nil,
            planType: nil,
            rateLimitReachedType: nil
        )
    }

    private static func accountSnapshot(
        usedPercent: Int,
        primaryResetsAt: Int? = nil,
        secondaryResetsAt: Int? = nil,
        rateLimitResetCredits: RateLimitResetCreditsSummary? = nil
    ) -> CodexAccountSnapshot {
        CodexAccountSnapshot(
            rateLimits: snapshot(
                usedPercent: usedPercent,
                primaryResetsAt: primaryResetsAt,
                secondaryResetsAt: secondaryResetsAt
            ),
            rateLimitResetCredits: rateLimitResetCredits
        )
    }

    private static func usageSummary(totalTokens: Int) -> CodexUsageSummary {
        CodexUsageSummary(
            dailyUsage: CodexUsageSummary.empty().dailyUsage,
            today: TokenUsageTotals(
                inputTokens: totalTokens,
                cachedInputTokens: 0,
                outputTokens: 0,
                reasoningOutputTokens: 0,
                totalTokens: totalTokens
            ),
            currentMonth: .zero,
            modelBreakdown: []
        )
    }
}

private actor MockRateLimitsReader: CodexAccountReading {
    private var results: [Result<CodexAccountSnapshot, Error>]

    init(results: [Result<CodexAccountSnapshot, Error>]) {
        self.results = results
    }

    func readRateLimits() async throws -> CodexAccountSnapshot {
        let result = results.isEmpty ? Result<CodexAccountSnapshot, Error>.failure(CodexAppServerError.missingRateLimits) : results.removeFirst()
        return try result.get()
    }
}

private struct MockUsageSummaryReader: CodexUsageSummaryReading {
    var summary = CodexUsageSummary.empty()

    func readUsageSummary(referenceDate: Date) async throws -> CodexUsageSummary {
        summary
    }
}

final class CodexUsageLogReaderTests: XCTestCase {
    func testReaderAggregatesDailyMonthAndModelUsage() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexMonitorUsageTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try writeLog(
            rootURL: rootURL,
            year: "2026",
            month: "07",
            day: "09",
            name: "today.jsonl",
            lines: [
                turnContextLine(model: "gpt-5.5"),
                tokenLine(
                    timestamp: "2026-07-09T08:00:00.000Z",
                    input: 1_000,
                    cache: 200,
                    output: 300,
                    reasoning: 50,
                    total: 1_300
                )
            ]
        )

        try writeLog(
            rootURL: rootURL,
            year: "2026",
            month: "07",
            day: "08",
            name: "yesterday.jsonl",
            lines: [
                turnContextLine(model: "gpt-5.5"),
                tokenLine(
                    timestamp: "2026-07-08T08:00:00.000Z",
                    input: 500,
                    cache: 100,
                    output: 200,
                    reasoning: 25,
                    total: 700
                )
            ]
        )

        try writeLog(
            rootURL: rootURL,
            year: "2026",
            month: "07",
            day: "01",
            name: "month-only.jsonl",
            lines: [
                sessionMetaLine(model: "gpt-5.4"),
                tokenLine(
                    timestamp: "2026-07-01T08:00:00.000Z",
                    input: 700,
                    cache: 150,
                    output: 300,
                    reasoning: 60,
                    total: 1_000
                )
            ]
        )

        let reader = CodexUsageLogReader(rootURL: rootURL, calendar: calendar)
        let referenceDate = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 9, hour: 12)))

        let summary = try await reader.readUsageSummary(referenceDate: referenceDate)

        XCTAssertEqual(summary.today.inputTokens, 1_000)
        XCTAssertEqual(summary.today.outputTokens, 300)
        XCTAssertEqual(summary.today.cachedInputTokens, 200)
        XCTAssertEqual(summary.today.totalTokens, 1_300)

        XCTAssertEqual(summary.currentMonth.totalTokens, 3_000)
        XCTAssertEqual(summary.dailyUsage.count, 7)
        XCTAssertEqual(summary.dailyUsage[5].totalTokens, 700)
        XCTAssertEqual(summary.dailyUsage[6].totalTokens, 1_300)

        XCTAssertEqual(summary.modelBreakdown.first?.model, "gpt-5.5")
        XCTAssertEqual(summary.modelBreakdown.first?.percentage, 67)
        XCTAssertEqual(summary.modelBreakdown.last?.model, "gpt-5.4")
        XCTAssertEqual(summary.modelBreakdown.last?.percentage, 33)
    }

    private func writeLog(
        rootURL: URL,
        year: String,
        month: String,
        day: String,
        name: String,
        lines: [String]
    ) throws {
        let directory = rootURL
            .appendingPathComponent(year)
            .appendingPathComponent(month)
            .appendingPathComponent(day)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent(name)
        try lines.joined(separator: "\n").write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private func sessionMetaLine(model: String) -> String {
        """
        {"timestamp":"2026-07-09T08:00:00.000Z","type":"session_meta","payload":{"model":"\(model)"}}
        """
    }

    private func turnContextLine(model: String) -> String {
        """
        {"timestamp":"2026-07-09T08:00:00.000Z","type":"turn_context","payload":{"model":"\(model)","collaboration_mode":{"settings":{"model":"\(model)"}}}}
        """
    }

    private func tokenLine(
        timestamp: String,
        input: Int,
        cache: Int,
        output: Int,
        reasoning: Int,
        total: Int
    ) -> String {
        """
        {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":\(input),"cached_input_tokens":\(cache),"output_tokens":\(output),"reasoning_output_tokens":\(reasoning),"total_tokens":\(total)}}}}
        """
    }
}
