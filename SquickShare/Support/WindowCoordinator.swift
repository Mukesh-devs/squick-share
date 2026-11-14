import AppKit
import QuickShareCore
import SwiftUI

/// Opens and tracks the app's windows (the main window, request prompts, received text).
/// They are AppKit windows hosting SwiftUI, sized once from their content: SwiftUI's automatic window
/// resizing can loop on macOS 26 (each resize changes the window's corner safe area, which re-lays out
/// the content, which resizes the window again) until AppKit throws and the app quits.
@MainActor
final class WindowCoordinator: NSObject, NSWindowDelegate {
    static let mainID = "main"

    private var windows: [String: NSWindow] = [:]
    enum MainWindowEvent { case opened, minimized, restored, closed }
    /// Called when the main window opens, closes, is minimized or restored.
    var onMainWindowChange: ((MainWindowEvent) -> Void)?
    /// Keep the Dock icon even without windows (the menu bar icon is turned off).
    var alwaysShowsDockIcon = false

    var mainWindow: NSWindow? { windows[Self.mainID] }

    private enum Kind {
        /// A regular window: the app shows a Dock icon and menus while it is open.
        case standard(size: NSSize, minSize: NSSize)
        /// A small floating panel that never takes keyboard focus or activates the app.
        case floatingPanel
    }

    private func show<Content: View>(id: String, title: String, kind: Kind, activate: Bool = true,
                                     @ViewBuilder content: () -> Content) {
        if let existing = windows[id] {
            if existing.isMiniaturized { existing.deminiaturize(nil) }
            if activate {
                existing.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            } else {
                existing.orderFrontRegardless()
            }
            return
        }
        let controller = NSHostingController(rootView: content())
        controller.sizingOptions = []
        var size = controller.view.fittingSize
        if case .standard(let fixed, _) = kind { size = fixed }
        if size.width < 1 || size.height < 1 { size = NSSize(width: 400, height: 300) }

        let window: NSWindow
        switch kind {
        case .standard(_, let minSize):
            window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.contentMinSize = minSize
        case .floatingPanel:
            let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                                styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow],
                                backing: .buffered, defer: false)
            panel.isFloatingPanel = true
            panel.becomesKeyOnlyIfNeeded = true
            panel.hidesOnDeactivate = false
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window = panel
        }
        window.contentViewController = controller
        window.setContentSize(size)
        window.title = title
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier(id)
        window.delegate = self
        windows[id] = window

        if case .floatingPanel = kind {
            placeTopRight(window)
        } else if id == Self.mainID {
            // A new name: frames saved for the earlier, smaller window would be too small now.
            window.setFrameAutosaveName("squick-share main window 2")
            if !window.setFrameUsingName("squick-share main window 2") { window.center() }
        } else {
            window.center()
        }

        if activate, case .standard = kind {
            updateActivationPolicy(opening: true)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            window.orderFrontRegardless()
        }
        if id == Self.mainID { onMainWindowChange?(.opened) }
    }

    /// Near the top-right corner of the active screen, where notifications appear.
    private func placeTopRight(_ window: NSWindow) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return window.center() }
        let visible = screen.visibleFrame
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 16, y: visible.maxY - size.height - 16))
    }

    func close(id: String) {
        windows[id]?.close()
        windows[id] = nil
    }

    func isOpen(_ id: String) -> Bool { windows[id] != nil }

    /// Shows a Dock icon and the app's menus while a regular window is open, like other Mac apps;
    /// otherwise the app lives in the menu bar only.
    func updateActivationPolicy(opening: Bool = false) {
        let hasStandardWindow = opening || windows.values.contains { !($0 is NSPanel) && $0.isVisible }
        let policy: NSApplication.ActivationPolicy = alwaysShowsDockIcon || hasStandardWindow ? .regular : .accessory
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
        }
    }

    // MARK: NSWindowDelegate (AppKit calls these on the main thread)

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard let window = notification.object as? NSWindow, let id = window.identifier?.rawValue else { return }
            windows[id] = nil
            if id == Self.mainID { onMainWindowChange?(.closed) }
            // After the window is gone, so it no longer counts as open.
            DispatchQueue.main.async { [weak self] in self?.updateActivationPolicy() }
        }
    }

    nonisolated func windowDidMiniaturize(_ notification: Notification) {
        MainActor.assumeIsolated {
            if (notification.object as? NSWindow)?.identifier?.rawValue == Self.mainID { onMainWindowChange?(.minimized) }
        }
    }

    nonisolated func windowDidDeminiaturize(_ notification: Notification) {
        MainActor.assumeIsolated {
            if (notification.object as? NSWindow)?.identifier?.rawValue == Self.mainID { onMainWindowChange?(.restored) }
        }
    }

    // MARK: Specific windows

    func showMain(model: AppModel) {
        show(id: Self.mainID, title: "squick-share",
             kind: .standard(size: NSSize(width: 860, height: 620), minSize: NSSize(width: 700, height: 480))) {
            MainWindowView()
                .environmentObject(model)
                .environmentObject(model.settings)
        }
    }

    /// The request prompt for when notifications can't be shown. It floats but never takes focus,
    /// so a keystroke meant for another app can't accept a transfer.
    func showIncomingRequest(_ request: IncomingTransferRequest, model: AppModel) {
        show(id: "request-\(request.id)", title: "squick-share", kind: .floatingPanel, activate: false) {
            IncomingRequestView(request: request).environmentObject(model)
                .frame(width: 380)
        }
    }

    /// Received text appears without taking focus from what the user is doing.
    func showReceivedText(text: String, kind: TextKind, from device: String) {
        show(id: "text-\(UUID().uuidString)", title: "Text from \(device)", kind: .floatingPanel, activate: false) {
            ReceivedTextView(text: text, kind: kind)
        }
    }
}
