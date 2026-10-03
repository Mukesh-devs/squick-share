import AppKit
import SwiftUI

@main
struct SquickShareApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environmentObject(appDelegate.model)
                .environmentObject(appDelegate.model.settings)
        } label: {
            MenuBarLabel().environmentObject(appDelegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Image(nsImage: MenuBarIcon.image(for: model.menuBarState))
            .accessibilityLabel(model.menuBarAccessibilityLabel)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor lazy var model = AppModel()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // squickshare:// URLs (from the share extension) arrive as Apple Events; handle them directly
        // so they work regardless of how SwiftUI routes URL opens for a menu bar app.
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleGetURL(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: string) else { return }
        MainActor.assumeIsolated {
            model.start()
            model.handleOpen([url])
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        // SQUICKSHARE_SNAPSHOT=1: render the UI to PNGs and quit, without starting the network.
        // SQUICKSHARE_SETTINGS_TEST=1: open Settings, switch tabs repeatedly, then quit (hang check).
        if ProcessInfo.processInfo.environment["SQUICKSHARE_SETTINGS_TEST"] != nil {
            MainActor.assumeIsolated { model.runSettingsTabTest() }
            return
        }
        if ProcessInfo.processInfo.environment["SQUICKSHARE_SNAPSHOT"] != nil {
            MainActor.assumeIsolated { model.renderSnapshotsAndQuit() }
            return
        }
        #endif
        MainActor.assumeIsolated { model.start() }
    }

    /// Files and squickshare:// URLs from the share extension or "Open With".
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            model.start()
            model.handleOpen(urls)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { model.windows.showSettings(model: model) }
        return true
    }
}
