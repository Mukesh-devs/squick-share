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
        let window = NSWindow(contentViewController: controller)
        window.title = title
        window.styleMask = resizable ? [.titled, .closable, .resizable] : [.titled, .closable]
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
        show(id: "send", title: "Send with squick-share") {
            SendPanel(showsClose: false).environmentObject(model)
                .frame(width: 380)
                .padding(16)
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
