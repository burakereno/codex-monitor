import AppKit
import Combine

extension Notification.Name {
    static let codexMonitorDockSettingsChanged = Notification.Name("CodexMonitorDockSettingsChanged")
}

enum DockIconPreference {
    static let showDockIconKey = "showDockIcon"
    static let showDockValuesKey = "showDockValues"

    static var showDockIcon: Bool {
        UserDefaults.standard.object(forKey: showDockIconKey) as? Bool ?? false
    }

    static var showDockValues: Bool {
        UserDefaults.standard.object(forKey: showDockValuesKey) as? Bool ?? false
    }
}

@MainActor
final class DockIconController {
    static let shared = DockIconController()

    private var cancellables = Set<AnyCancellable>()
    private var currentActivationPolicy: NSApplication.ActivationPolicy?
    private var latestTitle = MenuBarTitle(displayVersion: .version1, providers: [])
    private var lastDockState: DockState?

    private init() {}

    func start(model: CodexMonitorModel) {
        loadBundledIcon()
        latestTitle = model.menuBarTitle
        applyActivationPolicy()
        updateDockTile(force: true)

        model.$menuBarTitle
            .receive(on: RunLoop.main)
            .sink { [weak self] title in
                Task { @MainActor in
                    self?.latestTitle = title
                    self?.updateDockTile()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.settingsChanged()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .codexMonitorDockSettingsChanged)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.settingsChanged()
                }
            }
            .store(in: &cancellables)
    }

    func stop() {
        cancellables.removeAll()
        clearDockTile()
    }

    func settingsChanged() {
        applyActivationPolicy()
        updateDockTile(force: true)
    }

    private func loadBundledIcon() {
        guard
            let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
            let icon = NSImage(contentsOf: url)
        else {
            return
        }

        NSApp.applicationIconImage = icon
    }

    private func applyActivationPolicy() {
        let policy: NSApplication.ActivationPolicy = DockIconPreference.showDockIcon ? .regular : .accessory
        guard currentActivationPolicy != policy else { return }

        NSApp.setActivationPolicy(policy)
        currentActivationPolicy = policy

        if policy == .regular {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func updateDockTile(force: Bool = false) {
        guard DockIconPreference.showDockIcon, DockIconPreference.showDockValues else {
            clearDockTile()
            return
        }

        let state = DockState(label: dockLabel)
        guard force || lastDockState != state else { return }

        lastDockState = state
        NSApp.dockTile.contentView = nil
        NSApp.dockTile.badgeLabel = state.label
        NSApp.dockTile.display()
    }

    private func clearDockTile() {
        guard lastDockState != nil || NSApp.dockTile.contentView != nil || NSApp.dockTile.badgeLabel != nil else {
            return
        }

        NSApp.dockTile.badgeLabel = nil
        NSApp.dockTile.contentView = nil
        NSApp.dockTile.display()
        lastDockState = nil
    }

    private var dockLabel: String {
        guard let provider = latestTitle.providers.first else { return "--" }
        return provider.primary
    }
}

private struct DockState: Equatable {
    let label: String
}
