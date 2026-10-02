import QuickShareCore
import SwiftUI
import UniformTypeIdentifiers

/// The menu bar popover.
struct PopoverView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    banners
                    if !model.pendingRequests.isEmpty {
                        PopoverSection(title: "Requests") {
                            ForEach(model.pendingRequests) { request in
                                IncomingRequestCard(request: request)
                            }
                        }
                    }
                    if model.pendingSendItems.isEmpty {
                        DropZone()
                    } else {
                        SendPanel(showsClose: true)
                    }
                    if !model.transfers.isEmpty {
                        PopoverSection(title: "Active") {
                            ForEach(model.transfers) { TransferRow(transfer: $0) }
                        }
                    }
                    if !model.recents.isEmpty {
                        PopoverSection(title: "Recent", trailing: AnyView(
                            Button("Clear") { model.clearRecents() }
                                .buttonStyle(.link).font(.caption)
                                .accessibilityLabel("Clear recent transfers"))) {
                            ForEach(model.recents.prefix(6)) { RecentRow(recent: $0) }
                        }
                    }
                }
                .padding(14)
            }
            .frame(maxHeight: 520)
            Divider()
            footer
        }
        .frame(width: 360)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: model.menuBarSymbol)
                .font(.title2)
                .foregroundStyle(settings.visibility == .hidden ? Color.secondary : Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("squick-share").font(.headline)
                Text(model.statusLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityLabel("Status: \(model.statusLine)")
            }
            Spacer()
            Menu {
                Picker("Visibility", selection: $settings.visibility) {
                    ForEach(Visibility.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "eye")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Who can see this Mac")
            .accessibilityLabel("Visibility")
        }
        .padding(14)
    }

    @ViewBuilder private var banners: some View {
        if model.localNetworkDenied {
            Banner(symbol: "exclamationmark.triangle.fill", tint: .orange,
                   text: "Local network permission is off. squick-share can't find or be found by nearby devices.") {
                Button("Open System Settings") { model.openLocalNetworkSettings() }
            }
        } else if !model.hasNetwork {
            Banner(symbol: "wifi.slash", tint: .orange,
                   text: "Not connected to a network. Both devices must be on the same Wi-Fi network.") { EmptyView() }
        } else if case .failed(let message) = model.receiverStatus {
            Banner(symbol: "exclamationmark.triangle.fill", tint: .orange, text: "Can't be discovered: \(message)") { EmptyView() }
        }
        if let notice = model.notice {
            Banner(symbol: "info.circle.fill", tint: .blue, text: notice) {
                Button("OK") { model.notice = nil }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button {
                model.windows.showSettings(model: model)
            } label: {
                Label("Settings…", systemImage: "gearshape")
            }
            .accessibilityLabel("Open settings")
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .accessibilityLabel("Quit squick-share")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// A titled group in the popover.
struct PopoverSection<Content: View>: View {
    let title: String
    var trailing: AnyView? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                Spacer()
                if let trailing { trailing }
            }
            content()
        }
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

/// Accepts dropped files, folders, links and text to start a send.
struct DropZone: View {
    @EnvironmentObject private var model: AppModel
    @State private var targeted = false
    @State private var composingText = false
    @State private var text = ""

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.and.arrow.up.on.square")
                .font(.system(size: 28))
                .foregroundStyle(targeted ? Color.accentColor : .secondary)
                .accessibilityHidden(true)
            Text("Drop files, folders or text here to send")
                .font(.callout)
                .multilineTextAlignment(.center)
            HStack {
                Button("Choose Files…") { chooseFiles() }
                    .accessibilityHint("Pick files or folders to send")
                Button("Send Text…") { composingText.toggle() }
                    .accessibilityHint("Type text or a link to send")
            }
            if composingText {
                HStack {
                    TextField("Text or link", text: $text)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(submitText)
                        .accessibilityLabel("Text or link to send")
                    Button("Next", action: submitText).disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                .foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.5))
        )
        .onDrop(of: [.fileURL, .url, .plainText], isTargeted: $targeted, perform: handleDrop)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Drop area for sending")
    }

    private func submitText() {
        model.addSendText(text)
        text = ""
        composingText = false
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Send"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK { model.addSendFiles(panel.urls) }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { model.addSendFiles([url]) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { model.addSendText(url.absoluteString) }
                }
            } else if provider.canLoadObject(ofClass: String.self) {
                handled = true
                _ = provider.loadObject(ofClass: String.self) { string, _ in
                    guard let string else { return }
                    DispatchQueue.main.async { model.addSendText(string) }
                }
            }
        }
        return handled
    }
}
