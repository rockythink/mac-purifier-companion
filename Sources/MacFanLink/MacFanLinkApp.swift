import AppKit
import SwiftUI

@main
struct MacFanLinkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let controller = WorkerController.shared

    var body: some Scene {
        MenuBarExtra {
            MenuPopoverView(controller: controller)
        } label: {
            MenuBarStatusLabel(controller: controller)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(controller: controller)
        }
        .defaultSize(width: 980, height: 680)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appSettings) {
                SettingsLink { Text("设置…") }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        WorkerController.shared.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        WorkerController.shared.requestApplicationTermination()
    }
}
