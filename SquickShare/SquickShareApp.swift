import AppKit
import SwiftUI

@main
struct SquickShareApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The app's windows are AppKit windows (see WindowCoordinator) and the menu bar icon is an
        // NSStatusItem (see StatusItemController). This empty scene only provides the standard menus
        // (Edit, Window, Help) shown while a window is open. It is never displayed: "Settings…"
        // opens our own Settings window instead.
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { appDelegate.model.showSettings() }
                    .keyboardShortcut(",")
            }
            CommandGroup(replacing: .newItem) {
                Button("Send Files…") { appDelegate.model.chooseFiles() }
                    .keyboardShortcut("o")
            }
            // Edit › Find puts the cursor in the toolbar's search field (History and Settings).
            CommandGroup(replacing: .textEditing) {
                Button("Find…") { appDelegate.model.focusSearch() }
                    .keyboardShortcut("f")
            }
            // View menu: jump to a page of the main window, like the sidebar.
            CommandGroup(before: .sidebar) {
                Button("Send") { appDelegate.model.showMainWindow(section: .send) }
                    .keyboardShortcut("1")
                Button("Receive") { appDelegate.model.showMainWindow(section: .receive) }
                    .keyboardShortcut("2")
                Button("History") { appDelegate.model.showMainWindow(section: .history) }
                    .keyboardShortcut("3")
                Divider()
            }
            CommandGroup(before: .windowList) {
                Button("squick-share") { appDelegate.model.showMainWindow() }
                    .keyboardShortcut("0")
                Divider()
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor lazy var model = AppModel()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // squickshare:// URLs (from the share extension) arrive as Apple Events; handle them directly
        // so they work regardless of how SwiftUI routes URL opens.
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
        // SQUICKSHARE_UI_TEST=1: open, use and close every window and the menu, then quit (crash check).
        let environment = ProcessInfo.processInfo.environment
        if environment["SQUICKSHARE_SETTINGS_TEST"] != nil {
            MainActor.assumeIsolated { model.runSettingsTabTest() }
            return
        }
        if environment["SQUICKSHARE_SNAPSHOT"] != nil {
            MainActor.assumeIsolated { model.renderSnapshotsAndQuit() }
            return
        }
        if environment["SQUICKSHARE_UI_TEST"] != nil {
            MainActor.assumeIsolated { model.runUITest() }
            return
        }
        #endif
        let launchedAtLogin = Self.launchedAsLoginItem
        MainActor.assumeIsolated {
            model.start()
            // Open the window when the user opens the app, but not when it starts at login.
            // Without the menu bar icon the window is the only way in, so it always opens then.
            if !launchedAtLogin || !model.settings.showInMenuBar, !model.windows.isOpen(WindowCoordinator.mainID) {
                model.showMainWindow()
            }
        }
    }

    /// Whether this launch was a login item starting (rather than the user opening the app).
    private static var launchedAsLoginItem: Bool {
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.eventID == AEEventID(kAEOpenApplication),
           event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem) {
            return true
        }
        // Login items registered with SMAppService don't always carry the flag above: treat a launch
        // shortly after the system started as a login launch when launch at login is on.
        let launchAtLogin = MainActor.assumeIsolated { AppSettings.isLaunchAtLoginEnabled }
        return launchAtLogin && ProcessInfo.processInfo.systemUptime < 300
    }

    /// Files and squickshare:// URLs from the share extension or "Open With".
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            model.start()
            model.handleOpen(urls)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { model.showMainWindow() }
        return true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        MainActor.assumeIsolated { model.statusItem?.makeDockMenu() }
    }

    /// Closing the last window keeps the app running in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
