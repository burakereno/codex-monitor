import Foundation
import Testing
@testable import CodexMonitor

struct CodexAppServerRecoveryTests {
    @Test(.timeLimit(.minutes(1)))
    func reloadsSavedSessionAfterUnauthorizedAndReusesRecoveredConnection() async throws {
        let server = try RecoveryTestServer(unauthorizedLaunches: 1)
        let client = server.client()
        let events = await client.rateLimitUpdateEvents()

        let recovered = try await client.readRateLimits()
        let next = try await client.readRateLimits()

        #expect(recovered.rateLimits.planType == "pro")
        #expect(recovered.rateLimits.primary == nil)
        #expect(recovered.rateLimits.secondary?.usedPercent == 0)
        #expect(next.rateLimits.secondary?.windowDurationMins == 10_080)
        #expect(try server.launchCount == 2)
        #expect(try server.readCount == 3)

        // The old subscription finishes so the model can subscribe again.
        var iterator = events.makeAsyncIterator()
        #expect(await iterator.next() == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func persistentUnauthorizedRetriesOnlyOnceAndReportsSignIn() async throws {
        let server = try RecoveryTestServer(unauthorizedLaunches: 99)
        let client = server.client()

        do {
            _ = try await client.readRateLimits()
            Issue.record("Expected authentication failure")
        } catch CodexAppServerError.authenticationRequired {
            #expect(try server.launchCount == 2)
            #expect(try server.readCount == 2)
        }
        #expect(CodexAppServerError.authenticationRequired.localizedDescription.contains("giris"))
    }

    @Test(.timeLimit(.minutes(1)))
    func unrelatedServerErrorsDoNotRestartTheConnection() async throws {
        let server = try RecoveryTestServer(unauthorizedLaunches: 99, errorMessage: "503 Service Unavailable")
        let client = server.client()

        do {
            _ = try await client.readRateLimits()
            Issue.record("Expected service failure")
        } catch CodexAppServerError.serverError(let message) {
            #expect(message == "503 Service Unavailable")
        }
        #expect(try server.launchCount == 1)
        #expect(try server.readCount == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectedInitializationDoesNotAttemptAccountRequests() async throws {
        let server = try RecoveryTestServer(unauthorizedLaunches: 0, rejectInitialization: true)
        let client = server.client()

        do {
            _ = try await client.readRateLimits()
            Issue.record("Expected initialization failure")
        } catch CodexAppServerError.serverError(let message) {
            #expect(message == "Initialization rejected")
        }
        #expect(try server.launchCount == 1)
        #expect(try server.readCount == 0)
    }

    @Test(arguments: ["pro", "prolite", "plus", "free", "team", "enterprise", "future-plan"])
    func decodesWeeklyOnlyLimitsWithoutPlanNameAssumptions(plan: String) throws {
        let data = Data("""
        {"rateLimits":{"planType":"\(plan)","primary":{"usedPercent":0,"windowDurationMins":10080},"secondary":null}}
        """.utf8)
        let response = try JSONDecoder().decode(RateLimitsResponse.self, from: data)
        let snapshot = response.rateLimits.normalizedCodexWindows

        #expect(snapshot.planType == plan)
        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary?.usedPercent == 0)
    }

    @Test
    func planChangeDoesNotKeepWindowsAndCreditsFromPreviousPlan() {
        let old = RateLimitsSnapshot(
            limitId: "codex", limitName: nil,
            primary: RateLimitWindow(usedPercent: 90, resetsAt: nil, windowDurationMins: 300),
            secondary: RateLimitWindow(usedPercent: 80, resetsAt: nil, windowDurationMins: 10_080),
            credits: CreditsSnapshot(balance: "50", hasCredits: true, unlimited: false),
            planType: "plus", rateLimitReachedType: "weekly"
        )
        let update = RateLimitsSnapshot(
            limitId: "codex", limitName: nil,
            primary: RateLimitWindow(usedPercent: 0, resetsAt: nil, windowDurationMins: 10_080),
            secondary: nil, credits: nil, planType: "pro", rateLimitReachedType: nil
        )

        let merged = old.mergingSparseUpdate(update)
        #expect(merged.planType == "pro")
        #expect(merged.primary == nil)
        #expect(merged.secondary?.usedPercent == 0)
        #expect(merged.credits == nil)
        #expect(merged.rateLimitReachedType == nil)
    }

    @Test
    func sparseUpdatesOnSamePlanKeepExistingWindows() {
        let old = RateLimitsSnapshot(
            limitId: "codex", limitName: nil,
            primary: RateLimitWindow(usedPercent: 20, resetsAt: nil, windowDurationMins: 300),
            secondary: RateLimitWindow(usedPercent: 40, resetsAt: nil, windowDurationMins: 10_080),
            credits: nil, planType: "pro", rateLimitReachedType: nil
        )
        let update = RateLimitsSnapshot(
            limitId: "codex", limitName: nil, primary: nil,
            secondary: RateLimitWindow(usedPercent: 41, resetsAt: nil, windowDurationMins: 10_080),
            credits: nil, planType: "pro", rateLimitReachedType: nil
        )

        let merged = old.mergingSparseUpdate(update)
        #expect(merged.primary?.usedPercent == 20)
        #expect(merged.secondary?.usedPercent == 41)
    }

    @Test @MainActor
    func planUpgradePublishesNewAllowanceWithoutRejectingTheUsageDrop() async {
        let old = RateLimitsSnapshot(
            limitId: "codex", limitName: nil, primary: nil,
            secondary: RateLimitWindow(usedPercent: 80, resetsAt: nil, windowDurationMins: 10_080),
            credits: nil, planType: "plus", rateLimitReachedType: nil
        )
        let upgraded = RateLimitsSnapshot(
            limitId: "codex", limitName: nil, primary: nil,
            secondary: RateLimitWindow(usedPercent: 0, resetsAt: nil, windowDurationMins: 10_080),
            credits: nil, planType: "pro", rateLimitReachedType: nil
        )
        let client = PlanChangeAccountReader(snapshots: [old, upgraded])
        let model = CodexMonitorModel(codexClient: client, codexUsageReader: EmptyUsageReader())

        await model.refresh()
        await model.refresh()

        #expect(model.codexSnapshot?.planType == "pro")
        #expect(model.codexSnapshot?.secondary?.usedPercent == 0)
        #expect(model.codexMessage == nil)
        #expect(await client.readCount == 2)
    }
}

private actor PlanChangeAccountReader: CodexAccountReading {
    private var snapshots: [RateLimitsSnapshot]
    private(set) var readCount = 0

    init(snapshots: [RateLimitsSnapshot]) {
        self.snapshots = snapshots
    }

    func readRateLimits() async throws -> CodexAccountSnapshot {
        readCount += 1
        guard !snapshots.isEmpty else { throw CodexAppServerError.missingRateLimits }
        return CodexAccountSnapshot(rateLimits: snapshots.removeFirst(), rateLimitResetCredits: nil)
    }
}

private struct EmptyUsageReader: CodexUsageSummaryReading {
    func readUsageSummary(referenceDate: Date) async throws -> CodexUsageSummary {
        .empty(referenceDate: referenceDate)
    }
}

private final class RecoveryTestServer {
    private let directory: URL
    private let executable: URL

    init(
        unauthorizedLaunches: Int,
        errorMessage: String = "failed to fetch codex rate limits: 401 Unauthorized",
        rejectInitialization: Bool = false
    ) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CodexRecovery-\(UUID())")
        executable = directory.appendingPathComponent("fake-codex")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        root="$(dirname "$0")"
        printf 'launch\\n' >> "$root/launches"
        launch_count=$(wc -l < "$root/launches" | tr -d ' ')
        while IFS= read -r line; do
          request_id=$(printf '%s' "$line" | sed -nE 's/.*"id":([0-9]+).*/\\1/p')
          case "$line" in
            *rateLimits*read*)
              printf 'read\\n' >> "$root/reads"
              if [ "$launch_count" -le \(unauthorizedLaunches) ]; then
                printf '{"id":%s,"error":{"code":-32603,"message":"\(errorMessage)"}}\\n' "$request_id"
              else
                printf '{"id":%s,"result":{"rateLimits":{"planType":"pro","primary":{"usedPercent":0,"windowDurationMins":10080},"secondary":null}}}\\n' "$request_id"
              fi
              ;;
            *initialize*)
              if [ -n "$request_id" ]; then
                if [ \(rejectInitialization ? "1" : "0") -eq 1 ]; then
                  printf '{"id":%s,"error":{"code":-32603,"message":"Initialization rejected"}}\\n' "$request_id"
                else
                  printf '{"id":%s,"result":{}}\\n' "$request_id"
                fi
              fi
              ;;
          esac
        done
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func client() -> CodexAppServerClient {
        CodexAppServerClient(binaryLocator: CodexBinaryLocator(
            applicationURLProvider: { nil }, fallbackPaths: [executable.path]
        ))
    }

    var launchCount: Int { get throws { try countLines("launches") } }
    var readCount: Int { get throws { try countLines("reads") } }

    private func countLines(_ name: String) throws -> Int {
        let file = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: file.path) else { return 0 }
        return try String(contentsOf: file, encoding: .utf8).split(separator: "\n").count
    }
}
