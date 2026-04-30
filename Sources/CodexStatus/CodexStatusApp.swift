import AppKit
import SwiftUI

@main
struct CodexStatusApp: App {
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
    private let statusModel = CodexStatusModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusController = StatusBarController(model: statusModel)
        statusModel.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusModel.stop()
    }
}
