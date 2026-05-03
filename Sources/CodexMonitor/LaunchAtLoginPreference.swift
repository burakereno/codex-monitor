import Combine
import Foundation
import ServiceManagement

@MainActor
final class LaunchAtLoginPreference: ObservableObject {
    static let shared = LaunchAtLoginPreference()
    static let storageKey = "openAtLogin"

    @Published var isEnabled: Bool {
        didSet {
            guard !isReverting else { return }
            if apply(isEnabled) {
                UserDefaults.standard.set(isEnabled, forKey: Self.storageKey)
            } else {
                revertToSystemState()
            }
        }
    }

    @Published private(set) var lastError: String?

    private var isReverting = false

    private init() {
        self.isEnabled = Self.isEnabledInSystem
        UserDefaults.standard.set(isEnabled, forKey: Self.storageKey)
    }

    func refresh() {
        setIsEnabled(Self.isEnabledInSystem)
        UserDefaults.standard.set(isEnabled, forKey: Self.storageKey)
    }

    private static var isEnabledInSystem: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @discardableResult
    private func apply(_ enabled: Bool) -> Bool {
        let service = SMAppService.mainApp

        do {
            if enabled {
                if service.status != .enabled {
                    try service.register()
                }
            } else if service.status == .enabled {
                try service.unregister()
            }

            lastError = nil
            return true
        } catch {
            NSLog("CodexMonitor: open-at-login update failed: \(error.localizedDescription)")
            lastError = error.localizedDescription
            return false
        }
    }

    private func revertToSystemState() {
        let actual = Self.isEnabledInSystem
        UserDefaults.standard.set(actual, forKey: Self.storageKey)
        setIsEnabled(actual)
    }

    private func setIsEnabled(_ value: Bool) {
        guard isEnabled != value else { return }

        isReverting = true
        isEnabled = value
        isReverting = false
    }
}
