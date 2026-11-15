#if DEBUG
import AppKit
import QuickShareCore
import SwiftUI

/// Debug-only hooks for automated checks (not compiled into Release builds):
///   squickshare://debug-snapshot      renders the main views to PNGs in the app's temporary folder
///   SQUICKSHARE_UI_TEST=1             exercises every window and the menu, then quits
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

    /// Opens Settings and cycles through the tabs; prints progress and quits when done.
    /// If a tab switch hangs, the process never exits, which the caller detects with a timeout.
    func runSettingsTabTest(step: Int = 0) {
        let order: [SettingsTab] = [.general, .trustedDevices, .general, .diagnostics, .general]
        if step == 0 { showSettings() }
        guard step < 40 else {
            print("settings tab test: finished \(step) switches")
            fflush(stdout)
            NSApp.terminate(nil)
            return
        }
        settingsTab = order[step % order.count]
        print("settings tab test: switch \(step + 1) -> \(settingsTab)")
        fflush(stdout)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.runSettingsTabTest(step: step + 1) }
    }

    func renderSnapshotsAndQuit() {
        renderSnapshots()
        NSApp.terminate(nil)
    }

    /// Opens, uses and closes every window and the menu, with the real network running.
    /// Prints each step; prints "ui test: finished" and quits at the end. A crash or a hang
    /// (no "finished" before the caller's timeout) fails the check.
    func runUITest() {
        start()
        let sampleFile = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ui-test-sample.txt")
        try? Data("squick-share UI test\n".utf8).write(to: sampleFile)
        let request = Self.sampleRequest()
        let steps: [(String, () -> Void)] = [
            ("open main window", { self.showMainWindow(section: .send) }),
            ("load sample state", { self.debugLoadSampleState(request: request) }),
            ("welcome sheet", { self.settings.hasSeenWelcome = false }),
            ("dismiss welcome sheet", { self.settings.hasSeenWelcome = true }),
            ("send text sheet", { self.isComposingText = true }),
            ("close send text sheet", { self.isComposingText = false }),
            ("page: receive", { self.section = .receive }),
            ("page: history", { self.section = .history }),
            ("history: received only", { self.historyFilter = .received }),
            ("history: sent only", { self.historyFilter = .sent }),
            ("history: search", { self.historyFilter = .all; self.historyQuery = "IMG" }),
            ("history: focus search", { self.focusSearch() }),
            ("history: no matches", { self.historyQuery = "zzzz" }),
            ("history: clear search", { self.historyQuery = "" }),
            ("page: settings", { self.section = .settings }),
            ("settings: search", { self.settingsQuery = "blue" }),
            ("settings: focus search", { self.focusSearch() }),
            ("settings: clear search", { self.settingsQuery = "" }),
            ("page: send", { self.section = .send }),
            ("build menu", { self.debugBuildMenu() }),
            ("visibility: everyone for 10 minutes", { self.settings.visibility = .temporary }),
            ("build menu with countdown", { self.debugBuildMenu() }),
            ("visibility: no one", { self.settings.visibility = .hidden }),
            ("visibility: everyone", { self.settings.visibility = .everyone }),
            ("add files to send", { self.addSendFiles([sampleFile]) }),
            ("show QR code", { self.showQRCode() }),
            ("hide QR code", { self.hideQRCode() }),
            ("clear send list", { self.clearSendItems() }),
            ("searching state", { self.debugLoadSearchingState() }),
            ("open settings", { self.showSettings(tab: .general) }),
            ("settings: rapid tab switches", {
                for tab in [SettingsTab.trustedDevices, .diagnostics, .general, .trustedDevices, .general] { self.settingsTab = tab }
            }),
            ("settings: trusted devices", { self.settingsTab = .trustedDevices }),
            ("settings: diagnostics", { self.settingsTab = .diagnostics }),
            ("settings: general", { self.settingsTab = .general }),
            ("leave settings", { self.section = .receive }),
            ("rapid page switches", { for page in MainSection.allCases + MainSection.allCases { self.section = page } }),
            ("hide menu bar icon", { self.settings.showInMenuBar = false }),
            ("show menu bar icon", { self.settings.showInMenuBar = true }),
            ("bluetooth off", { self.settings.useBluetooth = false }),
            ("bluetooth on", { self.settings.useBluetooth = true }),
            ("received link (banner and notification)", { self.debugReceiveText("https://example.com/page") }),
            ("page: history with banner", { self.section = .history }),
            ("dismiss received text", { self.dismissReceivedText() }),
            ("received text", { self.debugReceiveText("A note from the phone") }),
            ("copy received text", { if let item = self.receivedText { self.copyReceivedText(item) } }),
            ("always show in Dock on", { self.settings.showInDock = true }),
            ("always show in Dock off", { self.settings.showInDock = false }),
            ("result notification with thumbnail", {
                self.notifications.postResult(title: "Transfer complete", body: "1 file received from Test", reveal: sampleFile)
            }),
            ("minimize main window", { self.windows.mainWindow?.miniaturize(nil) }),
            ("restore main window", { self.windows.mainWindow?.deminiaturize(nil) }),
            ("close main window", { self.windows.close(id: WindowCoordinator.mainID) }),
            ("reopen main window on history", { self.showMainWindow(section: .history) }),
            ("idle state", { self.debugLoadBrowsingState() }),
            ("close main window again", { self.windows.close(id: WindowCoordinator.mainID) }),
        ]
        runSteps(steps, index: 0)
    }

    private func runSteps(_ steps: [(String, () -> Void)], index: Int) {
        guard index < steps.count else {
            print("ui test: finished \(steps.count) steps")
            fflush(stdout)
            // Let pending window and menu work settle before quitting.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.terminate(nil) }
            return
        }
        print("ui test: \(index + 1)/\(steps.count) \(steps[index].0)")
        fflush(stdout)
        steps[index].1()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.runSteps(steps, index: index + 1) }
    }

    /// Builds the status menu's items without opening it (opening would block in menu tracking).
    private func debugBuildMenu() {
        guard let statusItem else { return }
        for _ in 0..<3 {
            let menu = NSMenu()
            statusItem.populate(menu, model: self)
            for item in menu.items { item.view?.layoutSubtreeIfNeeded() }
        }
    }

    static func sampleRequest() -> IncomingTransferRequest {
        let device = RemoteDevice(endpointID: "AB12", name: "Redmi Note 13", type: .phone)
        return IncomingTransferRequest(
            id: UUID(), device: device, pin: "4930",
            files: [FileOffer(name: "IMG_20261002_181512.jpg", size: 4_812_331, mimeType: "image/jpeg", parentFolder: nil),
                    FileOffer(name: "VID_20261002_181700.mp4", size: 182_993_101, mimeType: "video/mp4", parentFolder: nil),
                    FileOffer(name: "notes.pdf", size: 220_100, mimeType: "application/pdf", parentFolder: "Documents/2026")],
            texts: [TextOffer(title: "https://example.com", kind: .url, size: 19)])
    }

    private func renderSnapshots() {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("snapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Theme.solidSidebar = true
        let request = Self.sampleRequest()
        let windowSize = NSSize(width: 1100, height: 720)
        let tallWindow = NSSize(width: 1100, height: 900)
        debugPrepareSnapshot()
        debugLoadSampleState(request: request)

        // The real window, toolbar included, in each state.
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let suffix = appearance == .aqua ? "light" : "dark"
            renderWindow(.send, size: tallWindow, "window-send-busy-\(suffix)", directory, appearance)
            renderWindow(.receive, size: tallWindow, "window-receive-busy-\(suffix)", directory, appearance)
            renderWindow(.history, size: windowSize, "window-history-\(suffix)", directory, appearance)
            settingsTab = .general
            renderWindow(.settings, size: windowSize, "window-settings-\(suffix)", directory, appearance)
            render(MenuPreview().environmentObject(self).environmentObject(settings), width: StatusItemController.menuWidth,
                   "menu-\(suffix)", directory, appearance)
            render(WelcomeSheet().environmentObject(settings).background(Theme.card), width: 480,
                   "welcome-\(suffix)", directory, appearance)
        }
        settingsTab = .trustedDevices
        renderWindow(.settings, size: windowSize, "settings-trusted", directory, .aqua)
        settingsTab = .diagnostics
        renderWindow(.settings, size: windowSize, "settings-diagnostics", directory, .aqua)
        settingsTab = .general
        settingsQuery = "visible"
        renderWindow(.settings, size: windowSize, "settings-search", directory, .aqua)
        settingsQuery = ""
        render(MenuBarIconGallery(), width: 560, "menubar-icons", directory, .aqua)

        showQRCode()
        renderWindow(.send, size: windowSize, "window-qr", directory, .aqua)
        hideQRCode()

        debugLoadBrowsingState()
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let suffix = appearance == .aqua ? "light" : "dark"
            renderWindow(.send, size: windowSize, "window-send-\(suffix)", directory, appearance)
            renderWindow(.receive, size: windowSize, "window-receive-\(suffix)", directory, appearance)
            render(MenuPreview().environmentObject(self).environmentObject(settings), width: StatusItemController.menuWidth,
                   "menu-idle-\(suffix)", directory, appearance)
        }
        debugLoadSearchingState()
        renderWindow(.send, size: windowSize, "window-searching", directory, .aqua)
        windows.close(id: WindowCoordinator.mainID)
        diagnostics.info("debug", "snapshots written")
    }

    /// Shows `section` in the real main window at `size`, lets SwiftUI and AppKit lay it out, and
    /// renders the whole window frame (title bar and toolbar included) to a PNG.
    private func renderWindow(_ page: MainSection, size: NSSize, _ name: String, _ directory: URL,
                              _ appearance: NSAppearance.Name) {
        section = page
        showMainWindow()
        guard let window = windows.mainWindow else { return }
        window.appearance = NSAppearance(named: appearance)
        window.setContentSize(size)
        // Section changes reach the toolbar through the main queue, which doesn't run here.
        windows.updateToolbarItems()
        settle()
        guard let frameView = window.contentView?.superview else { return }
        frameView.layoutSubtreeIfNeeded()
        frameView.displayIfNeeded()
        write(frameView, name, directory)
    }

    /// Runs the run loop briefly so SwiftUI applies pending state changes.
    private func settle(_ seconds: TimeInterval = 0.5) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            RunLoop.current.run(mode: .default, before: until)
        }
    }

    private func render<V: View>(_ view: V, width: CGFloat, _ name: String, _ directory: URL, _ appearance: NSAppearance.Name) {
        render(view, size: nil, width: width, name, directory, appearance)
    }

    private func render<V: View>(_ view: V, size fixed: NSSize?, width: CGFloat = 0, _ name: String, _ directory: URL,
                                 _ appearance: NSAppearance.Name) {
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)
            .background(Color(nsColor: .windowBackgroundColor)))
        hosting.appearance = NSAppearance(named: appearance)
        if let fixed {
            hosting.frame = NSRect(origin: .zero, size: fixed)
        } else {
            let size = hosting.fittingSize
            hosting.frame = NSRect(x: 0, y: 0, width: max(width, size.width), height: max(size.height, 40))
        }
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        write(hosting, name, directory)
    }

    /// Writes `view` to `name`.png, always at 2x (Retina), whatever screen this runs on: CI machines have 1x displays.
    private func write(_ view: NSView, _ name: String, _ directory: URL) {
        let scale: CGFloat = 2
        let bounds = view.bounds
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * scale),
                                         pixelsHigh: Int(bounds.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name).png"))
    }
}

/// The status menu as it looks when open: its SwiftUI rows plus the standard items.
private struct MenuPreview: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuHeaderView().frame(height: 56)
            Divider().padding(.horizontal, 10).padding(.vertical, 4)
            ForEach(model.pendingRequests.prefix(1)) { request in
                MenuRequestView(request: request).frame(height: 50)
                row("Accept", "checkmark.circle")
                row("Decline", "xmark.circle")
                Divider().padding(.horizontal, 10).padding(.vertical, 4)
            }
            ForEach(model.transfers.prefix(3)) { transfer in
                MenuTransferView(id: transfer.id).frame(height: 62)
            }
            if !model.transfers.isEmpty { Divider().padding(.horizontal, 10).padding(.vertical, 4) }
            row("Open squick-share", "macwindow")
            row("Send Files…", "square.and.arrow.up")
            row("Visibility", "eye", submenu: true)
            row("Recent Transfers", "clock.arrow.circlepath", submenu: true)
            Divider().padding(.horizontal, 10).padding(.vertical, 4)
            row("Settings…", "gearshape", shortcut: "⌘,")
            row("Quit squick-share", "power", shortcut: "⌘Q")
        }
        .padding(.vertical, 6)
        .frame(width: StatusItemController.menuWidth)
    }

    private func row(_ title: String, _ symbol: String, submenu: Bool = false, shortcut: String? = nil) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).frame(width: 18)
            Text(title)
            Spacer()
            if let shortcut { Text(shortcut).foregroundStyle(.secondary) }
            if submenu { Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 14)
        .frame(height: 24)
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
