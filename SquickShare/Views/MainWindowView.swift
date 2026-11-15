import QuickShareCore
import SwiftUI
import UniformTypeIdentifiers

/// The main window: a sidebar with Send, Receive, History and Settings, and the chosen page.
///
/// A plain sidebar list next to the page, rather than NavigationSplitView: the window keeps one fixed
/// layout and never resizes itself, which keeps it clear of the SwiftUI window-resizing loops seen on
/// macOS 26 (see WindowCoordinator).
struct MainWindowView: View {
    @EnvironmentObject private var model: AppModel
    @State private var dropTargeted = false
    @State private var composingText = false

    var body: some View {
        // The title bar is transparent and the window content runs under it (WindowCoordinator):
        // backgrounds fill that strip, so the sidebar reaches the top under the window buttons, while
        // the content itself stays in the safe area below it.
        HStack(spacing: 0) {
            Sidebar()
                .frame(width: 200)
            Divider()
                .ignoresSafeArea()
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        }
        .frame(minWidth: 700, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
        // Files dropped anywhere in the window go to the send list.
        .onDrop(of: DropLoader.types, isTargeted: $dropTargeted) { providers in
            DropLoader.load(providers) { files, texts in
                if !files.isEmpty { model.addSendFiles(files) }
                texts.forEach { model.addSendText($0) }
                if model.section != .send { model.section = .send }
            }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .sheet(isPresented: $composingText) {
            ComposeTextSheet().environmentObject(model)
        }
    }

    @ViewBuilder private var page: some View {
        switch model.section {
        case .send: SendPage(composingText: $composingText)
        case .receive: ReceivePage()
        case .history: HistoryPage()
        case .settings: SettingsPage()
        }
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            List(selection: selection) {
                Section {
                    ForEach([MainSection.send, .receive, .history]) { row($0) }
                }
                Section {
                    row(.settings)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            Divider()
            SidebarStatus()
        }
        .background(SidebarBackground().ignoresSafeArea())
    }

    private func row(_ section: MainSection) -> some View {
        Label(section.title, systemImage: section.symbol)
            .badge(model.badge(for: section))
            .tag(section)
            .accessibilityHint(section == .receive && !model.pendingRequests.isEmpty ? "A request is waiting" : "")
    }

    /// The list needs an optional selection; clicking empty space must not deselect the page.
    private var selection: Binding<MainSection?> {
        Binding(get: { model.section },
                set: { new in if let new, new != model.section { model.section = new } })
    }
}

/// Whether this Mac can be found, at the bottom of the sidebar. Clicking it opens Receive.
private struct SidebarStatus: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Button { model.section = .receive } label: {
            HStack(alignment: .top, spacing: 8) {
                StatusDot(color: model.statusColor).padding(.top, 5)
                Text(model.statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Who can see this Mac")
        .accessibilityLabel("Status: \(model.statusLine)")
    }
}

/// The translucent sidebar material Finder and System Settings use.
private struct SidebarBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

// MARK: - Page building blocks

/// A scrolling page with standard margins.
private struct Page<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                content()
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A page's title, a line about what it is for, and its main actions.
struct PageHeader<Actions: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title.weight(.semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            actions()
        }
    }
}

extension PageHeader where Actions == EmptyView {
    init(title: String, subtitle: String) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Problems that stop discovery, and one-off notices.
private struct StatusBanners: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.localNetworkDenied {
                Banner(symbol: "exclamationmark.triangle.fill", tint: .orange,
                       text: "Local network access is off, so squick-share can't find or be found by nearby devices.") {
                    Button("Open System Settings") { model.openLocalNetworkSettings() }
                }
            } else if !model.hasNetwork {
                Banner(symbol: "wifi.slash", tint: .orange,
                       text: "This Mac isn't connected to a network. Both devices must be on the same Wi-Fi network.") { EmptyView() }
            } else if case .failed(let message) = model.receiverStatus {
                Banner(symbol: "exclamationmark.triangle.fill", tint: .orange,
                       text: "This Mac can't be discovered right now (\(message)). squick-share keeps retrying.") { EmptyView() }
            }
            if let item = model.receivedText {
                Banner(symbol: item.webURL != nil ? "link" : "text.bubble", tint: .accentColor,
                       text: "\(item.deviceName) sent \(item.webURL != nil ? "a link" : "text"): \(String(item.text.prefix(300)))") {
                    HStack {
                        if item.webURL != nil {
                            Button("Open Link") { model.openReceivedText(item) }
                        }
                        Button("Copy") { model.copyReceivedText(item) }
                        Button("Dismiss") { model.dismissReceivedText() }
                            .buttonStyle(.link)
                    }
                }
            }
            if let notice = model.notice {
                Banner(symbol: "info.circle.fill", tint: .blue, text: notice) {
                    Button("OK") { model.notice = nil }
                }
            }
        }
    }
}

/// A request waiting for an answer, shown on pages other than Receive so it is never missed.
private struct RequestStrip: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 8) {
            ForEach(model.pendingRequests) { request in
                HStack(spacing: 10) {
                    Image(systemName: Format.deviceSymbol(request.device.type))
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(request.device.name) wants to share").font(.callout.weight(.semibold)).lineLimit(1)
                        Text("\(Format.countSummary(files: request.files.count, texts: request.texts.count, bytes: request.totalBytes)) · PIN \(request.pin)")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Button("Details") { model.section = .receive }
                        .buttonStyle(.link)
                    Button("Decline") { model.decline(request) }
                    Button("Accept") { model.accept(request, trust: false) }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.1)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.accentColor.opacity(0.25)))
                .accessibilityElement(children: .contain)
            }
        }
    }
}

// MARK: - Send

private struct SendPage: View {
    @EnvironmentObject private var model: AppModel
    @Binding var composingText: Bool
    @State private var showGuide = false

    private let columns = [GridItem(.adaptive(minimum: 118, maximum: 150), spacing: 12, alignment: .top)]

    var body: some View {
        let outgoing = model.transfers(.outgoing)
        Page {
            PageHeader(title: "Send", subtitle: subtitle) {
                Button { model.chooseFiles() } label: {
                    Label("Choose Files…", systemImage: "doc.badge.plus")
                }
                .help("Pick files or folders to send (⌘O)")
                Button { composingText = true } label: {
                    Label("Send Text…", systemImage: "text.bubble")
                }
                .help("Send a link or a note")
            }
            if model.hasStatusBanner { StatusBanners() }
            if !model.pendingRequests.isEmpty { RequestStrip() }
            if !model.pendingSendItems.isEmpty { SendTray() }

            WindowSection(title: "Nearby Devices") {
                if model.localNetworkDenied {
                    EmptyStateView(symbol: "network.slash", title: "Can't look for devices",
                                   message: "Allow squick-share to find devices on your local network in System Settings.")
                } else if let qr = model.qrSession {
                    QRCodePanel(session: qr)
                } else if model.visibleDevices.isEmpty {
                    SearchingView()
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(model.visibleDevices) { DeviceTile(device: $0) }
                    }
                    DisclosureGroup("Phone not listed?", isExpanded: $showGuide) {
                        PhoneGuide().padding(.top, 8)
                    }
                    .font(.callout)
                }
            }

            if !outgoing.isEmpty {
                WindowSection(title: "Sending") {
                    ForEach(outgoing) { TransferRow(transfer: $0) }
                }
            }
        }
    }

    private var subtitle: String {
        if model.pendingSendItems.isEmpty {
            return "Drop files on a device, or click a device to choose files."
        }
        return "Click a device to send \(model.sendSummary)."
    }
}

// MARK: - Receive

private struct ReceivePage: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let incoming = model.transfers(.incoming)
        Page {
            PageHeader(title: "Receive", subtitle: "Android phones send to this Mac with Quick Share.")
            if model.hasStatusBanner { StatusBanners() }
            VisibilityCard()

            if !model.pendingRequests.isEmpty {
                WindowSection(title: "Requests") {
                    ForEach(model.pendingRequests) { request in
                        IncomingRequestView(request: request, inline: true)
                            .padding(16)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.accentColor.opacity(0.08)))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.accentColor.opacity(0.25)))
                    }
                }
            }

            if !incoming.isEmpty {
                WindowSection(title: "Receiving") {
                    ForEach(incoming) { TransferRow(transfer: $0) }
                }
            }

            WindowSection(title: "Saved To") {
                SaveLocationRow()
            }

            WindowSection(title: "How to Send from a Phone") {
                VStack(alignment: .leading, spacing: 8) {
                    GuideStep(number: 1, text: "On the phone, share a photo, video or file and choose **Quick Share**.")
                    GuideStep(number: 2, text: "Tap **\(model.identity.name)**. Both devices must be on the same Wi-Fi network.")
                    GuideStep(number: 3, text: "Check that both show the same PIN, then click **Accept** here or in the notification.")
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
            }
        }
    }
}

/// Who can see this Mac, and the control to change it.
private struct VisibilityCard: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle()
                    .fill(model.isDiscoverable
                          ? AnyShapeStyle(LinearGradient(colors: [Color.accentColor.opacity(0.75), Color.accentColor],
                                                         startPoint: .top, endPoint: .bottom))
                          : AnyShapeStyle(Color.secondary.opacity(0.35)))
                    .frame(width: 56, height: 56)
                Image(systemName: settings.visibility == .hidden ? "antenna.radiowaves.left.and.right.slash" : "antenna.radiowaves.left.and.right")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.statusLine).font(.headline)
                    Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Text("Allow me to be discovered by:")
                        .font(.callout)
                        .fixedSize()
                    Picker("Allow me to be discovered by", selection: $settings.visibility) {
                        ForEach(Visibility.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Button("Announce Again") { model.announceAgain() }
                        .fixedSize()
                        .disabled(settings.visibility == .hidden)
                        .help("Tell nearby phones about this Mac now (useful if a phone just reconnected to Wi-Fi)")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    private var detail: String {
        if model.localNetworkDenied || !model.hasNetwork { return "Phones can't see this Mac until this is fixed." }
        switch settings.visibility {
        case .everyone: return "Nearby phones on this Wi-Fi network can send to this Mac."
        case .temporary: return "Nearby phones can send to this Mac until the timer ends."
        case .hidden: return "Phones can't see this Mac. Choose Everyone to receive files."
        }
    }
}

private struct SaveLocationRow: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: settings.downloadFolder.path))
                .resizable()
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(settings.downloadFolder.lastPathComponent).font(.callout.weight(.medium))
                Text("Received files are never opened automatically.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Show in Finder") { model.openDownloadFolder() }
            Button("Change…") { model.showSettings(tab: .general) }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
    }
}

// MARK: - History

private struct HistoryPage: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""
    @State private var selection: UUID?
    @FocusState private var searchFocused: Bool

    private var filtered: [RecentTransfer] {
        let terms = query.trimmingCharacters(in: .whitespaces)
        guard !terms.isEmpty else { return model.recents }
        return model.recents.filter { recent in
            ([recent.title, recent.deviceName, recent.text ?? ""] + recent.itemNames)
                .contains { $0.localizedCaseInsensitiveContains(terms) }
        }
    }

    var body: some View {
        let items = filtered
        Page {
            PageHeader(title: "History", subtitle: "Your last 30 transfers. Double-click or press Return to open one.") {
                if !model.recents.isEmpty {
                    TextField("Search", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                        .focused($searchFocused)
                        .help("Search (⌘F)")
                        .accessibilityLabel("Search history")
                    Button("Clear History") { model.clearRecents() }
                }
            }
            if model.hasStatusBanner { StatusBanners() }
            if !model.pendingRequests.isEmpty { RequestStrip() }
            if model.recents.isEmpty {
                EmptyStateView(symbol: "clock", title: "No transfers yet",
                               message: "Files and links you send or receive appear here.")
            } else if items.isEmpty {
                EmptyStateView(symbol: "magnifyingglass", title: "No matches",
                               message: "Nothing in your history matches “\(query)”.")
            } else {
                GroupedList(items: items) { recent in
                    RecentRow(recent: recent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(selection == recent.id ? Color.accentColor.opacity(0.18) : Color.clear))
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { model.open(recent) }
                        .onTapGesture { selection = recent.id }
                        .accessibilityAddTraits(selection == recent.id ? .isSelected : [])
                }
                Button("Open Downloads Folder") { model.openDownloadFolder() }
            }
        }
        .background {
            // Keyboard: ⌘F searches; Return opens the selected entry; Escape clears the search.
            Group {
                Button("Search") { searchFocused = true }
                    .keyboardShortcut("f")
                Button("Open Selected") {
                    if let id = selection, let recent = model.recents.first(where: { $0.id == id }) { model.open(recent) }
                }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(selection == nil || searchFocused)
                Button("Clear Search") {
                    query = ""
                    searchFocused = false
                }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(query.isEmpty && !searchFocused)
            }
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
    }
}

// MARK: - Settings

private struct SettingsPage: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Settings", subtitle: "Name, visibility, files and more.") {
                SettingsTabPicker()
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 4)
            SettingsView(showsTabPicker: false)
        }
    }
}

extension AppModel {
    /// Whether `StatusBanners` has something to show.
    var hasStatusBanner: Bool {
        if case .failed = receiverStatus { return true }
        return localNetworkDenied || !hasNetwork || notice != nil || receivedText != nil
    }
}

/// The files and text waiting to be sent.
private struct SendTray: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            ItemIcons(items: model.pendingSendItems)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.sendSummary).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Text(model.pendingSendBytes > 0 ? Format.bytes(model.pendingSendBytes) : "Ready to send")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.qrSession == nil {
                Button { model.showQRCode() } label: { Image(systemName: "qrcode") }
                    .buttonStyle(.borderless)
                    .help("Show a QR code for a phone to scan (experimental)")
                    .accessibilityLabel("Show QR code")
            }
            Button("Clear") { model.clearSendItems() }
                .accessibilityLabel("Clear items to send")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.08)))
    }
}

/// Up to three overlapping file icons.
private struct ItemIcons: View {
    let items: [SendItem]

    var body: some View {
        ZStack {
            ForEach(Array(items.prefix(3).enumerated()), id: \.offset) { index, item in
                Image(nsImage: icon(item))
                    .resizable()
                    .frame(width: 32, height: 32)
                    .offset(x: CGFloat(index) * 7, y: CGFloat(index) * -3)
            }
        }
        .frame(width: 48, height: 36, alignment: .leading)
        .accessibilityHidden(true)
    }

    private func icon(_ item: SendItem) -> NSImage {
        switch item {
        case .file(let url, _): return NSWorkspace.shared.icon(forFile: url.path)
        case .text: return NSWorkspace.shared.icon(for: .plainText)
        }
    }
}

/// Shown until the first device appears.
private struct SearchingView: View {
    var body: some View {
        VStack(spacing: 14) {
            RadarSymbol()
            VStack(spacing: 4) {
                Text("Looking for nearby devices…").font(.headline)
                Text("Android phones appear here while their Quick Share screen is open.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            PhoneGuide()
                .frame(maxWidth: 440)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
}

/// A gently animated radar symbol (static before macOS 14).
private struct RadarSymbol: View {
    var body: some View {
        let image = Image(systemName: "dot.radiowaves.left.and.right")
            .font(.system(size: 34, weight: .regular))
            .foregroundStyle(Color.accentColor)
            .frame(height: 44)
            .accessibilityHidden(true)
        if #available(macOS 14.0, *) {
            image.symbolEffect(.variableColor.iterative, options: .repeating)
        } else {
            image
        }
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 30)).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(title).font(.headline)
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

/// A titled group in the window.
struct WindowSection<Content: View>: View {
    let title: String
    var trailing: AnyView? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                if let trailing { trailing }
            }
            content()
        }
    }
}

/// Rows separated by dividers on one rounded background, like a grouped list.
struct GroupedList<Item: Identifiable, Row: View>: View {
    let items: [Item]
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                row(item).padding(.horizontal, 12).padding(.vertical, 8)
                if index < items.count - 1 { Divider().padding(.leading, 12) }
            }
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
    }
}

struct Banner<Actions: View>: View {
    let symbol: String
    let tint: Color
    let text: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
                actions()
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}

/// Text or a link to send.
private struct ComposeTextSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Send Text or a Link").font(.headline)
            TextEditor(text: $text)
                .font(.body)
                .frame(height: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
                .accessibilityLabel("Text or link to send")
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    model.addSendText(text)
                    dismiss()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .help("Add (⌘↩)")
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

/// Loads dropped files, links and text.
enum DropLoader {
    static let types: [UTType] = [.fileURL, .url, .plainText]

    /// Calls `completion` once, on the main queue, with everything that could be loaded.
    @discardableResult
    static func load(_ providers: [NSItemProvider], completion: @escaping @MainActor ([URL], [String]) -> Void) -> Bool {
        let collected = Collected()
        let group = DispatchGroup()
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { collected.add(file: url) }
                    group.leave()
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                handled = true
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { collected.add(text: url.absoluteString) }
                    group.leave()
                }
            } else if provider.canLoadObject(ofClass: String.self) {
                handled = true
                group.enter()
                _ = provider.loadObject(ofClass: String.self) { string, _ in
                    if let string { collected.add(text: string) }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            let (files, texts) = collected.values
            MainActor.assumeIsolated { completion(files, texts) }
        }
        return handled
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var files: [URL] = []
        private var texts: [String] = []

        func add(file: URL) { lock.lock(); files.append(file); lock.unlock() }
        func add(text: String) { lock.lock(); texts.append(text); lock.unlock() }
        var values: ([URL], [String]) { lock.lock(); defer { lock.unlock() }; return (files, texts) }
    }
}
