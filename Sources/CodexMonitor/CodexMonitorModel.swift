import Foundation

@MainActor
final class CodexMonitorModel: ObservableObject {
    @Published private(set) var codexSnapshot: RateLimitsSnapshot?
    @Published private(set) var rateLimitResetCredits: RateLimitResetCreditsSummary?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var codexMessage: String?
    @Published private(set) var codexUsageSummary = CodexUsageSummary.empty()
    @Published private(set) var menuBarTitle = MenuBarTitle(displayVersion: .version1, providers: [])

    private let codexClient: CodexAccountReading
    private let codexUsageReader: CodexUsageSummaryReading
    private var refreshTask: Task<Void, Never>?
    private var rateLimitEventTask: Task<Void, Never>?
    private var isRefreshingRateLimits = false
    private var rateLimitRefreshRequested = false

    init(
        codexClient: CodexAccountReading = CodexAppServerClient(),
        codexUsageReader: CodexUsageSummaryReading = CodexUsageLogReader()
    ) {
        self.codexClient = codexClient
        self.codexUsageReader = codexUsageReader
    }

    func start() {
        refreshTask?.cancel()
        rateLimitEventTask?.cancel()

        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.refresh()

            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(120))
                } catch {
                    return
                }
                await self.refresh()
            }
        }

        rateLimitEventTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                let events = await codexClient.rateLimitUpdateEvents()
                for await _ in events {
                    guard !Task.isCancelled else { return }
                    await refreshRateLimits()
                }

                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    return
                }
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        rateLimitEventTask?.cancel()
        rateLimitEventTask = nil
    }

    func refresh() async {
        if isRefreshing { return }
        isRefreshing = true
        defer { isRefreshing = false }

        await refreshCodex()
    }

    func updateMenuBarTitleForDisplayModeChange() {
        menuBarTitle = title()
    }

    private func title() -> MenuBarTitle {
        var providers: [MenuBarProviderTitle] = []

        if let codexSnapshot {
            providers.append(MenuBarProviderTitle(
                provider: .codex,
                primary: titleValue(for: codexSnapshot.primary),
                weekly: titleValue(for: codexSnapshot.secondary),
                primaryReset: titleResetValue(for: codexSnapshot.primary),
                weeklyReset: titleResetValue(for: codexSnapshot.secondary)
            ))
        }

        if providers.isEmpty {
            providers.append(MenuBarProviderTitle(provider: .codex, primary: "--", weekly: "--"))
        }

        return MenuBarTitle(displayVersion: menuBarDisplayVersion, providers: providers)
    }

    private func titleValue(for window: RateLimitWindow?) -> String {
        guard let percent = displayMode.percent(for: window) else { return "--" }
        return "\(percent)%"
    }

    private func titleResetValue(for window: RateLimitWindow?) -> String? {
        guard menuBarShowsResetTimes else { return nil }
        return window?.compactResetText() ?? "--"
    }

    private var displayMode: LimitDisplayMode {
        let rawValue = UserDefaults.standard.string(forKey: LimitDisplayMode.storageKey)
        return rawValue.flatMap(LimitDisplayMode.init(rawValue:)) ?? .remaining
    }

    private var menuBarDisplayVersion: MenuBarDisplayVersion {
        let rawValue = UserDefaults.standard.string(forKey: MenuBarDisplayVersion.storageKey)
        return rawValue.flatMap(MenuBarDisplayVersion.init(rawValue:)) ?? .version1
    }

    private var menuBarShowsResetTimes: Bool {
        MenuBarResetTimePreference.showsResetTimes
    }

    private func refreshCodex() async {
        await refreshRateLimits()
        await refreshUsageSummary()
    }

    private func refreshRateLimits() async {
        guard !isRefreshingRateLimits else {
            rateLimitRefreshRequested = true
            return
        }

        isRefreshingRateLimits = true
        repeat {
            rateLimitRefreshRequested = false
            await performRateLimitRead()
        } while rateLimitRefreshRequested
        isRefreshingRateLimits = false
    }

    private func performRateLimitRead() async {
        do {
            let next = try await codexClient.readRateLimits()
            codexSnapshot = next.rateLimits
            rateLimitResetCredits = next.rateLimitResetCredits
            codexMessage = nil
            lastUpdated = Date()
        } catch {
            codexSnapshot = nil
            rateLimitResetCredits = nil
            codexMessage = error.localizedDescription
        }

        updateMenuBarTitleForDisplayModeChange()
    }

    private func refreshUsageSummary() async {
        do {
            codexUsageSummary = try await codexUsageReader.readUsageSummary(referenceDate: Date())
        } catch {
            codexUsageSummary = .empty()
        }
    }

}

struct MenuBarTitle: Equatable {
    let displayVersion: MenuBarDisplayVersion
    let providers: [MenuBarProviderTitle]
}

struct MenuBarProviderTitle: Equatable {
    let provider: TokenProvider
    let primary: String
    let primaryReset: String?
    let weekly: String
    let weeklyReset: String?

    init(
        provider: TokenProvider,
        primary: String,
        weekly: String,
        primaryReset: String? = nil,
        weeklyReset: String? = nil
    ) {
        self.provider = provider
        self.primary = primary
        self.primaryReset = primaryReset
        self.weekly = weekly
        self.weeklyReset = weeklyReset
    }
}
