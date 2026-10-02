#if DEBUG
import AppKit
import QuickShareCore
import SwiftUI

/// Debug-only hooks for automated checks (not compiled into Release builds):
///   squickshare://debug-snapshot      renders the main views to PNGs in the app's temporary folder
///   squickshare://debug-send?to=NAME  sends the pending items to the nearby device called NAME
extension AppModel {
    func handleDebugURL(_ url: URL) -> Bool {
        guard url.scheme == "squickshare", let host = url.host, host.hasPrefix("debug-") else { return false }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        switch host {
        case "debug-snapshot":
            renderSnapshots()
        case "debug-send":
            let name = query.first { $0.name == "to" }?.value ?? ""
            debugSend(to: name, attempts: 40)
        default:
            break
        }
        return true
    }

    private func debugSend(to name: String, attempts: Int) {
        if let device = nearbyDevices.first(where: { $0.name == name }) {
            diagnostics.info("debug", "debug-send to endpoint \(device.endpointID)")
            send(to: device)
        } else if attempts > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.debugSend(to: name, attempts: attempts - 1) }
        } else {
            diagnostics.error("debug", "debug-send: device not found")
        }
    }

    func renderSnapshotsAndQuit() {
        renderSnapshots()
        NSApp.terminate(nil)
    }

    private func renderSnapshots() {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("snapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let device = RemoteDevice(endpointID: "AB12", name: "Redmi Note 13", type: .phone)
        let request = IncomingTransferRequest(
            id: UUID(), device: device, pin: "4930",
            files: [FileOffer(name: "IMG_20261002_181512.jpg", size: 4_812_331, mimeType: "image/jpeg", parentFolder: nil),
                    FileOffer(name: "VID_20261002_181700.mp4", size: 182_993_101, mimeType: "video/mp4", parentFolder: nil),
                    FileOffer(name: "notes.pdf", size: 220_100, mimeType: "application/pdf", parentFolder: "Documents/2026")],
            texts: [TextOffer(title: "https://example.com", kind: .url, size: 19)])
        debugLoadSampleState(request: request)

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let suffix = appearance == .aqua ? "light" : "dark"
            render(PopoverView().environmentObject(self).environmentObject(settings), width: 360, "popover-\(suffix)", directory, appearance)
            render(IncomingRequestView(request: request).environmentObject(self).frame(width: 380), width: 380, "request-\(suffix)", directory, appearance)
        }
        render(GeneralSettings().environmentObject(self).environmentObject(settings).frame(width: 500, height: 420), width: 500, "settings-general", directory, .aqua)
        render(DiagnosticsSettings().environmentObject(self).environmentObject(settings).frame(width: 500, height: 420), width: 500, "settings-diagnostics", directory, .aqua)
        render(TrustedDevicesSettings().environmentObject(settings).frame(width: 500, height: 300), width: 500, "settings-trusted", directory, .aqua)
        render(ReceivedTextView(text: "https://example.com/a/very/long/link?with=query", kind: .url), width: 380, "text", directory, .aqua)
        showQRCode()
        render(SendPanel(showsClose: true).environmentObject(self).frame(width: 332).padding(14), width: 360, "send-qr", directory, .aqua)
        hideQRCode()
        render(SendPanel(showsClose: true).environmentObject(self).frame(width: 332).padding(14), width: 360, "send-list", directory, .aqua)
        render(MenuBarIconGallery(), width: 560, "menubar-icons", directory, .aqua)
        diagnostics.info("debug", "snapshots written")
    }

    private func render<V: View>(_ view: V, width: CGFloat, _ name: String, _ directory: URL, _ appearance: NSAppearance.Name) {
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)
            .background(Color(nsColor: .windowBackgroundColor)))
        hosting.appearance = NSAppearance(named: appearance)
        let size = hosting.fittingSize
        hosting.frame = NSRect(x: 0, y: 0, width: max(width, size.width), height: max(size.height, 40))
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
/// The menu bar icon in each state, enlarged, on light and dark menu bars.
private struct MenuBarIconGallery: View {
    let states: [(String, MenuBarState)] = [
        ("Visible", MenuBarState(activity: .idle(hidden: false), needsAttention: false)),
        ("Hidden", MenuBarState(activity: .idle(hidden: true), needsAttention: false)),
        ("Request", MenuBarState(activity: .idle(hidden: false), needsAttention: true)),
        ("Receiving 30%", MenuBarState(activity: .transferring(progress: 0.3, incoming: true, outgoing: false), needsAttention: false)),
        ("Sending 75%", MenuBarState(activity: .transferring(progress: 0.75, incoming: false, outgoing: true), needsAttention: false)),
        ("Both + request", MenuBarState(activity: .transferring(progress: 0.5, incoming: true, outgoing: true), needsAttention: true)),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach([false, true], id: \.self) { dark in
                HStack(spacing: 18) {
                    ForEach(states, id: \.0) { label, state in
                        VStack(spacing: 4) {
                            HStack(spacing: 6) {
                                icon(state, scale: 1, dark: dark)
                                icon(state, scale: 3, dark: dark)
                            }
                            Text(label).font(.caption2).foregroundStyle(dark ? .white : .black)
                        }
                    }
                }
                .padding(10)
                .background(dark ? Color(white: 0.15) : Color(white: 0.93))
            }
        }
        .padding(8)
    }

    private func icon(_ state: MenuBarState, scale: CGFloat, dark: Bool) -> some View {
        Image(nsImage: MenuBarIcon.image(for: state))
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .frame(width: MenuBarIcon.size.width * scale, height: MenuBarIcon.size.height * scale)
            .foregroundStyle(dark ? Color.white : Color.black)
    }
}
#endif
