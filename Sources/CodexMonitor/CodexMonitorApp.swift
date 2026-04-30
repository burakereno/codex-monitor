import AppKit
import SwiftUI

@main
struct CodexMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusBarController?
    private let statusModel = CodexMonitorModel()

    func applicationWillFinishLaunching(_ notification: Notification) {
        DockIconController.shared.settingsChanged()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusController = StatusBarController(model: statusModel)
        DockIconController.shared.start(model: statusModel)
        statusModel.start()
        UpdateChecker.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        DockIconController.shared.stop()
        statusModel.stop()
        UpdateChecker.shared.stop()
    }
}
