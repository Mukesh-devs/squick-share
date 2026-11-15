import AppKit
import Combine
import QuickShareCore
import SwiftUI

/// Opens and tracks the main window, an AppKit window hosting SwiftUI, sized once by us: SwiftUI's
/// automatic window resizing can loop on macOS 26 (each resize changes the window's corner safe area,
/// which re-lays out the content, which resizes the window again) until AppKit throws and the app quits.
///
/// The window has a native unified toolbar whose items follow the selected page. The app has no
/// floating or always-on-top windows: requests and received text arrive as notifications and in the
/// main window, so nothing covers other apps or appears over their full-screen spaces.
@MainActor
final class WindowCoordinator: NSObject, NSWindowDelegate, NSToolbarDelegate, NSSearchFieldDelegate {
    static let mainID = "main"
    private static let frameName = "squick-share main window 3"

    private(set) var mainWindow: NSWindow?
    private weak var model: AppModel?
    private var toolbar: NSToolbar?
    private var sectionObserver: AnyCancellable?
    private weak var historySearch: NSSearchToolbarItem?
    private weak var settingsSearch: NSSearchToolbarItem?

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
        self.model = model

        let controller = NSHostingController(rootView: MainWindowView()
            .environmentObject(model)
            .environmentObject(model.settings))
        controller.sizingOptions = []
        let size = NSSize(width: 1100, height: 720)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.contentViewController = controller
        window.setContentSize(size)
        window.contentMinSize = NSSize(width: 760, height: 520)
        // The sidebar runs to the top under the window buttons, like Finder and System Settings.
        // The title stays set for the Window menu and Mission Control.
        window.title = "SQuick Share"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none

        let toolbar = NSToolbar(identifier: "squick-share.main")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        self.toolbar = toolbar

        // An ordinary window: it lives on one desktop space, can go full screen itself, and goes
        // behind other apps when they are clicked.
        window.collectionBehavior = [.managed, .participatesInCycle, .fullScreenPrimary]
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier(Self.mainID)
        window.delegate = self
        window.setFrameAutosaveName(Self.frameName)
        if !window.setFrameUsingName(Self.frameName) { window.center() }
        mainWindow = window

        // The toolbar's items follow the selected page.
        sectionObserver = model.$section
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.updateToolbarItems() } }

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

    /// Puts the cursor in the toolbar's search field on History or Settings.
    func focusSearch() {
        switch model?.section {
        case .history?: historySearch?.beginSearchInteraction()
        case .settings?: settingsSearch?.beginSearchInteraction()
        default: break
        }
    }

    // MARK: Toolbar

    private static let sendTextID = NSToolbarItem.Identifier("squick-share.sendText")
    private static let chooseFilesID = NSToolbarItem.Identifier("squick-share.chooseFiles")
    private static let historyFilterID = NSToolbarItem.Identifier("squick-share.historyFilter")
    private static let historySearchID = NSToolbarItem.Identifier("squick-share.historySearch")
    private static let settingsSearchID = NSToolbarItem.Identifier("squick-share.settingsSearch")

    private static func identifiers(for section: MainSection) -> [NSToolbarItem.Identifier] {
        switch section {
        case .send: return [.flexibleSpace, sendTextID, chooseFilesID]
        case .receive: return []
        case .history: return [.flexibleSpace, historyFilterID, historySearchID]
        case .settings: return [.flexibleSpace, settingsSearchID]
        }
    }

    /// Swaps the toolbar's items for the selected page.
    func updateToolbarItems() {
        guard let toolbar, let model else { return }
        let wanted = Self.identifiers(for: model.section)
        guard toolbar.items.map(\.itemIdentifier) != wanted else { return }
        while !toolbar.items.isEmpty { toolbar.removeItem(at: 0) }
        for (index, identifier) in wanted.enumerated() {
            toolbar.insertItem(withItemIdentifier: identifier, at: index)
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.identifiers(for: model?.section ?? .send)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.sendTextID, Self.chooseFilesID, Self.historyFilterID,
         Self.historySearchID, Self.settingsSearchID]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let model else { return nil }
        switch identifier {
        case Self.sendTextID:
            return hostedItem(identifier, label: "Send Text") {
                ToolbarPill(title: "Send Text", symbol: "text.bubble") { model.isComposingText = true }
            }
        case Self.chooseFilesID:
            return hostedItem(identifier, label: "Choose Files") {
                ToolbarPill(title: "Choose Files", symbol: "plus", prominent: true) { model.chooseFiles() }
            }
        case Self.historyFilterID:
            return hostedItem(identifier, label: "Show") { HistoryFilterPicker().environmentObject(model) }
        case Self.historySearchID, Self.settingsSearchID:
            let item = NSSearchToolbarItem(itemIdentifier: identifier)
            let isHistory = identifier == Self.historySearchID
            item.searchField.placeholderString = isHistory ? "Search" : "Search settings"
            item.searchField.stringValue = isHistory ? model.historyQuery : model.settingsQuery
            item.searchField.delegate = self
            item.preferredWidthForSearchField = 210
            if isHistory { historySearch = item } else { settingsSearch = item }
            return item
        default:
            return nil
        }
    }

    private func hostedItem<V: View>(_ identifier: NSToolbarItem.Identifier, label: String,
                                     @ViewBuilder _ content: () -> V) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        let hosting = NSHostingView(rootView: content())
        hosting.sizingOptions = [.intrinsicContentSize]
        item.view = hosting
        item.label = label
        return item
    }

    // MARK: NSSearchFieldDelegate

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSSearchField, let model else { return }
        if field === historySearch?.searchField {
            model.historyQuery = field.stringValue
        } else if field === settingsSearch?.searchField {
            model.settingsQuery = field.stringValue
        }
    }

    // MARK: NSWindowDelegate (AppKit calls these on the main thread)

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard let window = notification.object as? NSWindow, window === mainWindow else { return }
            mainWindow = nil
            toolbar = nil
            sectionObserver = nil
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
