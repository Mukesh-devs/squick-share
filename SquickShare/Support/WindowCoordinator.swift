import AppKit
import QuickShareCore
import SwiftUI

/// Opens and tracks the app's standalone windows (prompts, send, settings, received text).
/// A menu bar app can't rely on SwiftUI scenes being open, so these are AppKit windows hosting SwiftUI.
@MainActor
final class WindowCoordinator: NSObject, NSWindowDelegate {
    private var windows: [String: NSWindow] = [:]

    func show<Content: View>(id: String, title: String, floating: Bool = false, resizable: Bool = false,
                             @ViewBuilder content: () -> Content) {
        if let existing = windows[id] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = NSHostingController(rootView: content())
        // Size the window once from its content instead of letting SwiftUI keep resizing it.
        // Automatic resizing can loop on macOS 26: each resize changes the window's corner safe area,
        // which re-lays out the content, which resizes the window again, until AppKit throws
        // ("more Update Constraints in Window passes than there are views") and the app quits.
        controller.sizingOptions = []
        var size = controller.view.fittingSize
        if size.width < 1 || size.height < 1 { size = NSSize(width: 400, height: 300) }
        let style: NSWindow.StyleMask = resizable ? [.titled, .closable, .resizable] : [.titled, .closable]
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style,
                              backing: .buffered, defer: false)
        window.contentViewController = controller
        window.setContentSize(size)
        if resizable {
            window.contentMinSize = NSSize(width: min(size.width, 320), height: min(size.height, 160))
        }
        window.title = title
        window.isReleasedWhenClosed = false
        window.level = floating ? .floating : .normal
        window.identifier = NSUserInterfaceItemIdentifier(id)
        window.delegate = self
        window.center()
        windows[id] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close(id: String) {
        windows[id]?.close()
        windows[id] = nil
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        // AppKit delivers window delegate calls on the main thread.
        MainActor.assumeIsolated {
            guard let window = notification.object as? NSWindow, let id = window.identifier?.rawValue else { return }
            windows[id] = nil
        }
    }

    // MARK: Specific windows

    func showIncomingRequest(_ request: IncomingTransferRequest, model: AppModel) {
        show(id: "request-\(request.id)", title: "squick-share", floating: true) {
            IncomingRequestView(request: request).environmentObject(model)
                .frame(width: 380)
        }
    }

    func showSend(model: AppModel) {
        // The device list grows while the window is open, so the window has a fixed size and scrolls.
        show(id: "send", title: "Send with squick-share", resizable: true) {
            ScrollView {
                SendPanel(showsClose: false).environmentObject(model)
                    .frame(width: 380)
                    .padding(16)
            }
            .frame(minWidth: 412, idealWidth: 412, minHeight: 300, idealHeight: 460)
        }
    }

    func showSettings(model: AppModel) {
        show(id: "settings", title: "squick-share Settings") {
            SettingsView().environmentObject(model).environmentObject(model.settings)
        }
    }

    func showReceivedText(text: String, kind: TextKind, from device: String) {
        show(id: "text-\(UUID().uuidString)", title: "Text from \(device)", resizable: true) {
            ReceivedTextView(text: text, kind: kind)
        }
    }
}
