import Foundation

@MainActor
final class CodexMonitorModel: ObservableObject {
    @Published private(set) var codexSnapshot: RateLimitsSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var codexMessage: String?
    @Published private(set) var codexUsageSummary = CodexUsageSummary.empty()
    @Published private(set) var menuBarTitle = MenuBarTitle(displayVersion: .version1, providers: [])

    private let codexClient: RateLimitsReading
    private let codexUsageReader: CodexUsageSummaryReading
    private var refreshTask: Task<Void, Never>?

    init(
        codexClient: RateLimitsReading = CodexAppServerClient(),
        codexUsageReader: CodexUsageSummaryReading = CodexUsageLogReader()
    ) {
        self.codexClient = codexClient
        self.codexUsageReader = codexUsageReader
    }

    func start() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.refresh()

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(120))
                await self.refresh()
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func refresh() async {
        if isRefreshing { return }
        isRefreshing = true
        defer { isRefreshing = false }

        await refreshCodex()

        lastUpdated = Date()
        updateMenuBarTitleForDisplayModeChange()
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
        do {
            let next = try await codexClient.readRateLimits()
            codexSnapshot = next
            codexMessage = nil
        } catch {
            codexSnapshot = nil
            codexMessage = error.localizedDescription
        }

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
