import AppKit
import QuickShareCore
import SwiftUI

/// Opens and tracks the main window, an AppKit window hosting SwiftUI, sized once by us: SwiftUI's
/// automatic window resizing can loop on macOS 26 (each resize changes the window's corner safe area,
/// which re-lays out the content, which resizes the window again) until AppKit throws and the app quits.
///
/// The app has no floating or always-on-top windows: requests and received text arrive as notifications
/// and in the main window, so nothing covers other apps or appears over their full-screen spaces.
@MainActor
final class WindowCoordinator: NSObject, NSWindowDelegate {
    static let mainID = "main"
    private static let frameName = "squick-share main window 2"

    private(set) var mainWindow: NSWindow?

    enum MainWindowEvent { case opened, minimized, restored, closed }
    /// Called when the main window opens, closes, is minimized or restored.
    var onMainWindowChange: ((MainWindowEvent) -> Void)?
    /// Keep the Dock icon without windows ("Always show in Dock", or the menu bar icon is off).
    var alwaysShowsDockIcon = false

    func isOpen(_ id: String) -> Bool { id == Self.mainID && mainWindow != nil }

    func close(id: String) {
        guard id == Self.mainID else { return }
        mainWindow?.close()
    }

    // MARK: Main window

    func showMain(model: AppModel) {
        // Become a regular app and activate *before* the window appears. A menu-bar-only app may put
        // windows on top of another app's full-screen space, where clicking that app can't send them
        // behind; a regular, active app's window opens on a normal desktop space instead.
        becomeRegularApp()
        activateApp()
        if let window = mainWindow {
            if window.isMiniaturized { window.deminiaturize(nil) }
            DispatchQueue.main.async { window.makeKeyAndOrderFront(nil) }
            return
        }

        let controller = NSHostingController(rootView: MainWindowView()
            .environmentObject(model)
            .environmentObject(model.settings))
        controller.sizingOptions = []
        let size = NSSize(width: 860, height: 620)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.contentViewController = controller
        window.setContentSize(size)
        window.contentMinSize = NSSize(width: 700, height: 480)
        // The sidebar runs to the top under the window buttons, like Finder and System Settings.
        // The title stays set for the Window menu and Mission Control.
        window.title = "squick-share"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // An ordinary window: it lives on one desktop space, can go full screen itself, and goes
        // behind other apps when they are clicked.
        window.collectionBehavior = [.managed, .participatesInCycle, .fullScreenPrimary]
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier(Self.mainID)
        window.delegate = self
        window.setFrameAutosaveName(Self.frameName)
        if !window.setFrameUsingName(Self.frameName) { window.center() }
        mainWindow = window

        // Order the window in after activation has taken effect, so it opens where the app now is.
        DispatchQueue.main.async { window.makeKeyAndOrderFront(nil) }
        onMainWindowChange?(.opened)
    }

    private func activateApp() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func becomeRegularApp() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
    }

    /// A Dock icon and the app's menus while the window is open, like other Mac apps; otherwise the
    /// app lives in the menu bar only (unless "Always show in Dock" is on).
    func updateActivationPolicy() {
        let windowOpen = mainWindow?.isVisible == true || mainWindow?.isMiniaturized == true
        let policy: NSApplication.ActivationPolicy = alwaysShowsDockIcon || windowOpen ? .regular : .accessory
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
        }
    }

    // MARK: NSWindowDelegate (AppKit calls these on the main thread)

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard let window = notification.object as? NSWindow, window === mainWindow else { return }
            mainWindow = nil
            onMainWindowChange?(.closed)
            // After the window is gone, so it no longer counts as open.
            DispatchQueue.main.async { [weak self] in self?.updateActivationPolicy() }
        }
    }

    nonisolated func windowDidMiniaturize(_ notification: Notification) {
        MainActor.assumeIsolated {
            if (notification.object as? NSWindow) === mainWindow { onMainWindowChange?(.minimized) }
        }
    }

    nonisolated func windowDidDeminiaturize(_ notification: Notification) {
        MainActor.assumeIsolated {
            if (notification.object as? NSWindow) === mainWindow { onMainWindowChange?(.restored) }
        }
    }
}
