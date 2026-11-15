import AppKit
import Combine
import QuickShareCore
import SwiftUI

/// The menu bar icon and its menu. Apple's guidelines ask menu bar extras to show a menu rather than
/// a popover; the main window is where sending happens. The menu is rebuilt each time it opens, and
/// its status and progress rows are SwiftUI views that keep updating while it is open.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    static let menuWidth: CGFloat = 300

    private weak var model: AppModel?
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private var cancellables: Set<AnyCancellable> = []
    private var shownState: MenuBarState?

    init(model: AppModel) {
        self.model = model
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
    }

    func install(visible: Bool) {
        setVisible(visible)
        guard let model, cancellables.isEmpty else { return }
        // @Published sends before storing the new value, so read the model on the next main-queue turn.
        Publishers.CombineLatest3(model.$transfers, model.$pendingRequests, model.settings.$visibility)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.refreshIcon() } }
            .store(in: &cancellables)
    }

    func setVisible(_ visible: Bool) {
        if visible {
            guard statusItem == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.menu = menu
            item.button?.toolTip = "squick-share"
            statusItem = item
            shownState = nil
            refreshIcon()
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    /// Redraws the icon only when what it shows changed (progress is quantized to 2% steps).
    private func refreshIcon() {
        guard let model, let button = statusItem?.button else { return }
        let state = model.menuBarState
        if state != shownState {
            button.image = MenuBarIcon.image(for: state)
            shownState = state
        }
        button.setAccessibilityLabel(model.menuBarAccessibilityLabel)
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let model else { return }
        populate(menu, model: model)
    }

    /// Builds the menu's items. Also used by debug checks, so it must not open anything.
    func populate(_ menu: NSMenu, model: AppModel) {
        menu.addItem(viewItem(MenuHeaderView(), height: 56))
        menu.addItem(.separator())

        for request in model.pendingRequests.prefix(3) {
            menu.addItem(viewItem(MenuRequestView(request: request), height: 50))
            menu.addItem(actionItem("Accept", symbol: "checkmark.circle", action: #selector(acceptRequest(_:)), object: request.id))
            menu.addItem(actionItem("Decline", symbol: "xmark.circle", action: #selector(declineRequest(_:)), object: request.id))
            menu.addItem(.separator())
        }

        let transfers = model.transfers.prefix(3)
        for transfer in transfers {
            menu.addItem(viewItem(MenuTransferView(id: transfer.id), height: 62))
        }
        if model.transfers.count > transfers.count {
            menu.addItem(actionItem("Show All Transfers…", symbol: nil, action: #selector(openReceive), object: nil))
        }
        if !transfers.isEmpty { menu.addItem(.separator()) }

        menu.addItem(actionItem("Open squick-share", symbol: "macwindow", action: #selector(openMain), object: nil))
        menu.addItem(actionItem("Send Files…", symbol: "square.and.arrow.up", action: #selector(sendFiles), object: nil))
        menu.addItem(visibilityItem(model))
        menu.addItem(recentItem(model))
        menu.addItem(.separator())
        let settings = actionItem("Settings…", symbol: "gearshape", action: #selector(openSettings), object: nil)
        settings.keyEquivalent = ","
        menu.addItem(settings)
        let quit = actionItem("Quit squick-share", symbol: "power", action: #selector(quit), object: nil)
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    /// The Dock icon's menu (shown while the app has a Dock icon).
    func makeDockMenu() -> NSMenu? {
        guard let model else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(actionItem("Send Files…", symbol: nil, action: #selector(sendFiles), object: nil))
        menu.addItem(visibilityItem(model))
        return menu
    }

    private func viewItem<V: View>(_ view: V, height: CGFloat) -> NSMenuItem {
        let content = view
            .environmentObject(model!)
            .environmentObject(model!.settings)
            .frame(width: Self.menuWidth, height: height, alignment: .leading)
        let hosting = NSHostingView(rootView: content)
        // A fixed frame: menus measure their items once, and self-sizing views can loop on macOS 26.
        hosting.sizingOptions = []
        hosting.frame = NSRect(x: 0, y: 0, width: Self.menuWidth, height: height)
        let item = NSMenuItem()
        item.view = hosting
        return item
    }

    private func actionItem(_ title: String, symbol: String?, action: Selector, object: Any?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = object
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }

    private func visibilityItem(_ model: AppModel) -> NSMenuItem {
        let item = actionItem("Visibility", symbol: model.settings.visibility == .hidden ? "eye.slash" : "eye", action: #selector(noop), object: nil)
        item.action = nil
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for visibility in Visibility.allCases {
            let option = actionItem(visibility.label, symbol: nil, action: #selector(setVisibility(_:)), object: visibility.rawValue)
            option.state = model.settings.visibility == visibility ? .on : .off
            submenu.addItem(option)
        }
        submenu.addItem(.separator())
        let announce = actionItem("Announce Again", symbol: nil, action: #selector(announceAgain), object: nil)
        announce.isEnabled = model.settings.visibility != .hidden
        announce.toolTip = "Tell nearby phones about this Mac now (useful if a phone just reconnected to Wi-Fi)"
        submenu.addItem(announce)
        item.submenu = submenu
        return item
    }

    private func recentItem(_ model: AppModel) -> NSMenuItem {
        let item = actionItem("Recent Transfers", symbol: "clock.arrow.circlepath", action: #selector(noop), object: nil)
        item.action = nil
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        if model.recents.isEmpty {
            let empty = NSMenuItem(title: "No Recent Transfers", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        }
        for recent in model.recents.prefix(8) {
            let symbol = recent.succeeded ? (recent.direction == .incoming ? "arrow.down.circle" : "arrow.up.circle") : "exclamationmark.triangle"
            let entry = actionItem(recent.title, symbol: symbol, action: #selector(openRecent(_:)), object: recent.id)
            let detail = "\(recent.direction == .incoming ? "From" : "To") \(recent.deviceName) · "
                + recent.date.formatted(.relative(presentation: .named))
            if #available(macOS 14.4, *) { entry.subtitle = detail } else { entry.toolTip = detail }
            submenu.addItem(entry)
        }
        submenu.addItem(.separator())
        submenu.addItem(actionItem("Show History…", symbol: nil, action: #selector(openHistory), object: nil))
        submenu.addItem(actionItem("Open Downloads Folder", symbol: nil, action: #selector(openDownloads), object: nil))
        let clear = actionItem("Clear Recent Transfers", symbol: nil, action: #selector(clearRecents), object: nil)
        clear.isEnabled = !model.recents.isEmpty
        submenu.addItem(clear)
        item.submenu = submenu
        return item
    }

    // MARK: Actions

    @objc private func noop() {}

    @objc private func acceptRequest(_ sender: NSMenuItem) {
        guard let model, let id = sender.representedObject as? UUID,
              let request = model.pendingRequests.first(where: { $0.id == id }) else { return }
        model.accept(request, trust: false)
    }

    @objc private func declineRequest(_ sender: NSMenuItem) {
        guard let model, let id = sender.representedObject as? UUID,
              let request = model.pendingRequests.first(where: { $0.id == id }) else { return }
        model.decline(request)
    }

    @objc private func openMain() { model?.showMainWindow() }

    @objc private func openReceive() { model?.showMainWindow(section: .receive) }

    @objc private func openHistory() { model?.showMainWindow(section: .history) }

    @objc private func sendFiles() { model?.chooseFiles() }

    @objc private func setVisibility(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let visibility = Visibility(rawValue: raw) else { return }
        model?.settings.visibility = visibility
    }

    @objc private func announceAgain() { model?.announceAgain() }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let model, let id = sender.representedObject as? UUID,
              let recent = model.recents.first(where: { $0.id == id }) else { return }
        model.open(recent)
    }

    @objc private func openDownloads() { model?.openDownloadFolder() }

    @objc private func clearRecents() { model?.clearRecents() }

    @objc private func openSettings() { model?.showSettings() }

    @objc private func quit() { NSApp.terminate(nil) }
}

// MARK: - Menu rows

/// Top of the menu: the app, and whether this Mac can be found right now.
struct MenuHeaderView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 34, height: 34)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("squick-share").font(.system(size: 13, weight: .semibold))
                HStack(spacing: 5) {
                    StatusDot(color: model.statusColor)
                    Text(model.shortStatus)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .accessibilityElement(children: .combine)
    }
}

/// A request waiting for Accept or Decline.
struct MenuRequestView: View {
    let request: IncomingTransferRequest

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: Format.deviceSymbol(request.device.type))
                .font(.system(size: 15))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.accentColor.opacity(0.15)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(request.device.name) wants to share")
                    .font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text("\(Format.countSummary(files: request.files.count, texts: request.texts.count, bytes: request.totalBytes)) · PIN \(request.pin)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .accessibilityElement(children: .combine)
    }
}

/// One transfer with live progress.
struct MenuTransferView: View {
    @EnvironmentObject private var model: AppModel
    let id: UUID

    var body: some View {
        if let transfer = model.transfers.first(where: { $0.id == id }) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: transfer.direction == .incoming ? "arrow.down" : "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.accentColor.opacity(0.15)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(transfer.headline).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(detail(transfer))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(transfer.phase.isFailure ? Color.orange : Color.secondary)
                        .lineLimit(1)
                    if transfer.phase == .transferring {
                        TransferProgressBar(fraction: transfer.fraction)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .accessibilityElement(children: .combine)
        } else {
            Text("Finished").font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 14)
        }
    }

    private func detail(_ transfer: ActiveTransfer) -> String {
        switch transfer.phase {
        case .connecting: return transfer.direction == .incoming ? "From \(transfer.deviceName)" : "To \(transfer.deviceName)"
        case .waitingForAcceptance(let pin): return "Check that \(transfer.deviceName) shows PIN \(pin)"
        case .transferring: return transfer.progressLine ?? "Starting…"
        case .completed: return "Done"
        case .failed(let message): return message
        }
    }
}

struct StatusDot: View {
    let color: Color

    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
    }
}

extension ActiveTransfer.Phase {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

extension AppModel {
    /// Green when this Mac can be found, grey when hidden, orange when something is wrong.
    var statusColor: Color {
        if localNetworkDenied || !hasNetwork { return .orange }
        if case .failed = receiverStatus { return .orange }
        return isDiscoverable ? .green : Color.secondary
    }

    /// "Visible · 2 devices nearby", "Hidden", "Visible for 9:41".
    var shortStatus: String {
        if localNetworkDenied { return "Local network access is off" }
        if !hasNetwork { return "No network" }
        if case .failed = receiverStatus { return "Can't be discovered right now" }
        var text: String
        switch settings.visibility {
        case .everyone: text = "Visible"
        case .hidden: text = "Hidden"
        case .temporary: text = "Visible for \(Format.countdown((settings.temporaryVisibilityUntil ?? now).timeIntervalSince(now)))"
        }
        if browserStatus == .browsing {
            let count = visibleDevices.count
            text += " · " + (count == 0 ? "Looking for devices" : count == 1 ? "1 device nearby" : "\(count) devices nearby")
        }
        return text
    }
}
