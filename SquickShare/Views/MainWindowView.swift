import QuickShareCore
import SwiftUI
import UniformTypeIdentifiers

/// The main window, modelled on Finder's AirDrop window: nearby devices you can click or drop files on,
/// what is happening now, recent transfers, and who can see this Mac.
struct MainWindowView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @State private var dropTargeted = false
    @State private var composingText = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    banners
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
                    NearbySection(composingText: $composingText)
                    if !model.transfers.isEmpty {
                        WindowSection(title: "In Progress") {
                            ForEach(model.transfers) { TransferRow(transfer: $0) }
                        }
                    }
                    if !model.recents.isEmpty {
                        WindowSection(title: "Recent", trailing: AnyView(
                            Button("Clear") { model.clearRecents() }
                                .buttonStyle(.link)
                                .accessibilityLabel("Clear recent transfers"))) {
                            GroupedList(items: Array(model.recents.prefix(8))) { RecentRow(recent: $0) }
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            StatusBar()
        }
        .frame(minWidth: 520, maxWidth: .infinity, minHeight: 420, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onDrop(of: DropLoader.types, isTargeted: $dropTargeted) { providers in
            DropLoader.load(providers) { files, texts in
                if !files.isEmpty { model.addSendFiles(files) }
                texts.forEach { model.addSendText($0) }
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

    @ViewBuilder private var banners: some View {
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
        if let notice = model.notice {
            Banner(symbol: "info.circle.fill", tint: .blue, text: notice) {
                Button("OK") { model.notice = nil }
            }
        }
    }
}

/// "Nearby": the send list, then the devices, or a searching state with tips.
private struct NearbySection: View {
    @EnvironmentObject private var model: AppModel
    @Binding var composingText: Bool
    @State private var showGuide = false

    private let columns = [GridItem(.adaptive(minimum: 118, maximum: 150), spacing: 12, alignment: .top)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Nearby").font(.title2.weight(.semibold))
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button { model.chooseFiles() } label: {
                    Label("Choose Files…", systemImage: "doc.badge.plus")
                }
                .help("Pick files or folders to send")
                Button { composingText = true } label: {
                    Label("Send Text…", systemImage: "text.bubble")
                }
                .help("Send a link or a note")
            }

            if !model.pendingSendItems.isEmpty { SendTray() }

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
    }

    private var subtitle: String {
        if model.pendingSendItems.isEmpty {
            return "Drop files on a device to send them, or click a device to choose files."
        }
        return "Click a device to send \(model.sendSummary)."
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

/// The bar at the bottom: whether this Mac can be found, and by whom.
private struct StatusBar: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(color: model.statusColor)
            Text(model.statusLine).font(.callout).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 12)
            Text("Allow me to be discovered by:").font(.callout).foregroundStyle(.secondary).lineLimit(1)
            Picker("Allow me to be discovered by", selection: $settings.visibility) {
                ForEach(Visibility.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            Button { model.showSettings() } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless)
                .help("Settings")
                .accessibilityLabel("Open settings")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
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
