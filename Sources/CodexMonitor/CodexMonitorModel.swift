import Foundation

@MainActor
final class CodexMonitorModel: ObservableObject {
    @Published private(set) var codexSnapshot: RateLimitsSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var codexMessage: String?
    @Published private(set) var menuBarTitle = MenuBarTitle(displayVersion: .version1, providers: [])

    private let codexClient = CodexAppServerClient()
    private var refreshTask: Task<Void, Never>?

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
                weekly: titleValue(for: codexSnapshot.secondary)
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

    private var displayMode: LimitDisplayMode {
        let rawValue = UserDefaults.standard.string(forKey: LimitDisplayMode.storageKey)
        return rawValue.flatMap(LimitDisplayMode.init(rawValue:)) ?? .remaining
    }

    private var menuBarDisplayVersion: MenuBarDisplayVersion {
        let rawValue = UserDefaults.standard.string(forKey: MenuBarDisplayVersion.storageKey)
        return rawValue.flatMap(MenuBarDisplayVersion.init(rawValue:)) ?? .version1
    }

    private func refreshCodex() async {
        do {
            let next = try await codexClient.readRateLimits()
            codexSnapshot = next
            codexMessage = nil
        } catch {
            codexMessage = error.localizedDescription
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
    let weekly: String
}
