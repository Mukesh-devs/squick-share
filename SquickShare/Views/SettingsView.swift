import QuickShareCore
import SwiftUI

/// The Settings page's views: the overview (`.general`) and its two subpages.
enum SettingsTab: Hashable, CaseIterable {
    case general, trustedDevices, diagnostics
}

/// Settings, laid out like System Settings: grouped rows in one column. Trusted Devices and
/// Diagnostics open as subpages.
struct SettingsPage: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Group {
            switch model.settingsTab {
            case .general:
                SettingsOverview()
            case .trustedDevices:
                SettingsSubpage(title: "Trusted Devices",
                                subtitle: "Devices whose transfers can be accepted without asking.") {
                    TrustedDevicesSettings()
                }
            case .diagnostics:
                SettingsSubpage(title: "Diagnostics",
                                subtitle: "A log of protocol steps, for reporting problems.") {
                    DiagnosticsSettings()
                }
            }
        }
        // Change state only when it differs, so appearing can't trigger another update (see refreshLaunchAtLogin).
        .onAppear { settings.refreshLaunchAtLogin() }
    }
}

/// Every setting, in groups. The toolbar's search field filters them.
private struct SettingsOverview: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let query = model.settingsQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        PageScroll(spacing: 0) {
            PageTitle(title: "Settings", subtitle: "How this Mac appears to others, where files go, and more.")
                .padding(.bottom, 8)
            Group {
                if !query.isEmpty {
                    let matches = SettingsItem.allCases.filter { $0.matches(query) }
                    if matches.isEmpty {
                        EmptyStateView(symbol: "magnifyingglass", title: "No matching settings",
                                       message: "Nothing matches “\(query)”.")
                            .padding(.top, 12)
                    } else {
                        SettingsGroup(title: "Results", items: matches)
                    }
                } else {
                    SettingsGroup(title: "This Mac", items: SettingsItem.thisMac)
                    SettingsGroup(title: "App", items: SettingsItem.app)
                    SettingsGroup(title: "Connection", items: SettingsItem.connection)
                }
            }
            // One readable column, like System Settings.
            .frame(maxWidth: 680, alignment: .leading)
        }
    }
}

/// One setting on the overview.
enum SettingsItem: CaseIterable {
    case name, visibility, saveTo, launchAtLogin, menuBar, dock, notifications, bluetooth, network, trustedDevices, diagnostics

    static let thisMac: [SettingsItem] = [.name, .visibility, .saveTo]
    static let app: [SettingsItem] = [.launchAtLogin, .menuBar, .dock, .notifications]
    static let connection: [SettingsItem] = [.bluetooth, .network, .trustedDevices, .diagnostics]

    var title: String {
        switch self {
        case .name: "Name"
        case .visibility: "Visible to"
        case .saveTo: "Save files to"
        case .launchAtLogin: "Open at login"
        case .menuBar: "Show in menu bar"
        case .dock: "Always show in Dock"
        case .notifications: "Notifications"
        case .bluetooth: "Detect phones with Bluetooth"
        case .network: "Network"
        case .trustedDevices: "Trusted Devices"
        case .diagnostics: "Diagnostics"
        }
    }

    private var keywords: String {
        switch self {
        case .name: "device name computer rename"
        case .visibility: "visibility discoverable hidden everyone no one 10 minutes receive"
        case .saveTo: "downloads folder location files save"
        case .launchAtLogin: "launch start login startup"
        case .menuBar: "menu bar status icon"
        case .dock: "dock icon"
        case .notifications: "notifications alerts accept decline"
        case .bluetooth: "bluetooth ble detect phones"
        case .network: "network wi-fi wifi ethernet interface"
        case .trustedDevices: "trusted devices auto accept automatically"
        case .diagnostics: "diagnostics log logging verbose debug protocol advanced"
        }
    }

    func matches(_ query: String) -> Bool {
        title.localizedCaseInsensitiveContains(query) || keywords.localizedCaseInsensitiveContains(query)
    }
}

/// A titled group of settings on one card.
private struct SettingsGroup: View {
    let title: String
    let items: [SettingsItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    SettingsItemRow(item: item)
                    if index < items.count - 1 {
                        Rectangle().fill(Theme.cardBorder).frame(height: 1).padding(.leading, 16)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .card()
        }
        .padding(.top, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsItemRow: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    let item: SettingsItem

    var body: some View {
        switch item {
        case .name:
            NameRow()
        case .visibility:
            SettingsRow(title: item.title, subtitle: visibilitySubtitle) {
                Picker(item.title, selection: $settings.visibility) {
                    ForEach(Visibility.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
        case .saveTo:
            SettingsRow(title: item.title) {
                Menu {
                    Button("Choose…") { FolderChooser.choose(settings) }
                    if !settings.isDefaultDownloadFolder {
                        Button("Use Downloads") { settings.resetDownloadFolder() }
                    }
                    Divider()
                    Button("Show in Finder") { model.openDownloadFolder() }
                } label: {
                    Text(settings.downloadFolder.lastPathComponent)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(settings.downloadFolder.path)
            }
        case .launchAtLogin:
            LaunchAtLoginRow()
        case .menuBar:
            SettingsRow(title: item.title,
                        subtitle: settings.showInMenuBar ? nil : "The Dock icon stays while this is off") {
                SettingsSwitch(title: item.title, isOn: $settings.showInMenuBar)
            }
        case .dock:
            SettingsRow(title: item.title,
                        subtitle: "Otherwise only while this window is open") {
                SettingsSwitch(title: item.title, isOn: $settings.showInDock)
                    .disabled(!settings.showInMenuBar)
            }
        case .notifications:
            SettingsRow(title: item.title, subtitle: notificationSubtitle,
                        subtitleIsWarning: notificationsBlocked) {
                HStack(spacing: 10) {
                    if notificationsBlocked {
                        Button("Open Settings") {
                            let id = Bundle.main.bundleIdentifier ?? ""
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                    }
                    SettingsSwitch(title: item.title, isOn: $settings.notificationsEnabled)
                }
            }
        case .bluetooth:
            SettingsRow(title: item.title,
                        subtitle: settings.useBluetooth ? Self.bluetoothMessage(model.beaconStatus) : "Only listens; nothing is sent over Bluetooth") {
                HStack(spacing: 10) {
                    if settings.useBluetooth, model.beaconStatus == .notAllowed {
                        Button("Open Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                    }
                    SettingsSwitch(title: item.title, isOn: $settings.useBluetooth)
                }
            }
            .help("When a nearby phone opens Quick Share, this Mac announces itself right away. Nothing is sent over Bluetooth.")
        case .network:
            SettingsRow(title: item.title) {
                Picker(item.title, selection: $settings.interface) {
                    Text("Any network").tag(InterfaceRestriction.any)
                    Text("Wi-Fi only").tag(InterfaceRestriction.wifi)
                    Text("Ethernet only").tag(InterfaceRestriction.wiredEthernet)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            .help("Limit discovery and transfers to one kind of network interface")
        case .trustedDevices:
            SettingsLinkRow(title: item.title,
                            value: settings.trustedDevices.isEmpty ? "None" : "\(settings.trustedDevices.count)") {
                model.settingsTab = .trustedDevices
            }
        case .diagnostics:
            SettingsLinkRow(title: item.title,
                            value: settings.verboseLogging ? "Verbose" : nil) {
                model.settingsTab = .diagnostics
            }
        }
    }

    private var visibilitySubtitle: String? {
        guard settings.visibility == .temporary, let until = settings.temporaryVisibilityUntil else { return nil }
        return "Hidden again in \(Format.countdown(until.timeIntervalSince(model.now)))"
    }

    private var notificationsBlocked: Bool { settings.notificationsEnabled && !model.notificationsAllowed }

    private var notificationSubtitle: String {
        notificationsBlocked ? "Turned off for squick-share in System Settings" : "Accept and Decline from the notification"
    }

    static func bluetoothMessage(_ status: BeaconListenerStatus) -> String {
        switch status {
        case .listening: return "Listening · only listens, nothing is sent"
        case .bluetoothOff: return "Bluetooth is off. Phones still find this Mac over Wi-Fi."
        case .notAllowed: return "squick-share isn't allowed to use Bluetooth"
        case .unsupported: return "This Mac has no Bluetooth LE"
        case .off: return "Starting…"
        }
    }
}

/// The name other devices see, edited in place.
private struct NameRow: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var draft = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        SettingsRow(title: "Name",
                    subtitle: error ?? (focused ? "Press Return to save" : nil), subtitleIsWarning: error != nil) {
            TextField("Name", text: $draft)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(focused ? Color.primary : Color.secondary)
                .frame(minWidth: 120, maxWidth: 220)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: draft) { error = AppSettings.validateName($0) }
                .onChange(of: focused) { if !$0 { commit() } }
                .accessibilityLabel("Device name")
                .accessibilityHint("The name other devices see")
        }
        .onAppear { if draft != settings.deviceName { draft = settings.deviceName } }
    }

    private func commit() {
        guard AppSettings.validateName(draft) == nil else {
            // Leaving the field with an invalid name puts the saved one back.
            if !focused {
                draft = settings.deviceName
                error = nil
            }
            return
        }
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if name != settings.deviceName { settings.deviceName = name }
        if draft != settings.deviceName { draft = settings.deviceName }
    }
}

private struct LaunchAtLoginRow: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var error: String?

    var body: some View {
        SettingsRow(title: "Open at login", subtitle: error, subtitleIsWarning: true) {
            SettingsSwitch(title: "Open at login", isOn: Binding(
                get: { settings.launchAtLogin },
                set: { error = settings.setLaunchAtLogin($0) }))
        }
    }
}

/// A row: title, optional subtitle, and a control on the right.
struct SettingsRow<Accessory: View>: View {
    let title: String
    var subtitle: String? = nil
    var subtitleIsWarning = false
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13.5))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(subtitleIsWarning ? Theme.warningText : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 10)
            accessory()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minHeight: 44)
    }
}

/// A row that opens a subpage.
private struct SettingsLinkRow: View {
    let title: String
    var value: String? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            SettingsRow(title: title) {
                HStack(spacing: 6) {
                    if let value { Text(value).font(.system(size: 13)).foregroundStyle(.secondary) }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .background(hovering ? Theme.fill.opacity(0.5) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
        .accessibilityValue(value ?? "")
    }
}

private struct SettingsSwitch: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(title, isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.switch)
    }
}

/// A symbol on a coloured rounded square (the Receive page's "saved to" card).
struct SettingsIcon: View {
    let symbol: String
    let tint: LinearGradient
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.47, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).fill(tint))
            .accessibilityHidden(true)
    }

    private static func pair(_ top: (Double, Double, Double), _ bottom: (Double, Double, Double)) -> LinearGradient {
        Theme.tile(Color(red: top.0 / 255, green: top.1 / 255, blue: top.2 / 255),
                   Color(red: bottom.0 / 255, green: bottom.1 / 255, blue: bottom.2 / 255))
    }

    static let blue = pair((28, 160, 255), (0, 98, 230))
    static let sky = pair((90, 200, 250), (0, 150, 230))
    static let cyan = pair((64, 210, 230), (0, 160, 200))
    static let indigo = pair((120, 120, 245), (80, 70, 220))
    static let purple = pair((190, 130, 250), (140, 70, 230))
    static let red = pair((255, 105, 97), (235, 50, 60))
    static let green = pair((52, 211, 153), (5, 150, 105))
    static let orange = pair((255, 190, 60), (245, 130, 0))
    static let gray = pair((160, 165, 175), (110, 115, 125))
}

/// Trusted Devices and Diagnostics: a back button, a title and the form.
private struct SettingsSubpage<Content: View>: View {
    @EnvironmentObject private var model: AppModel
    let title: String
    let subtitle: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Button { model.settingsTab = .general } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                        Text("Settings")
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .keyboardShortcut("[", modifiers: .command)
                .help("Back to Settings (⌘[)")
                PageTitle(title: title, subtitle: subtitle)
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            content()
                // The page's own background, not the form's.
                .scrollContentBackground(.hidden)
                .frame(maxWidth: 720, maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Picks the folder received files are saved to.
@MainActor
enum FolderChooser {
    static func choose(_ settings: AppSettings) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = settings.downloadFolder
        if panel.runModal() == .OK, let url = panel.url { settings.setDownloadFolder(url) }
    }
}

struct TrustedDevicesSettings: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Toggle("Accept automatically from trusted devices", isOn: $settings.autoAcceptTrusted)
            Text("A device becomes trusted when you tick “Always accept” on its request. Devices are recognized by their name and type only, which anyone on your network could copy. Only use this on networks you trust.")
                .font(.caption).foregroundStyle(.secondary)
            if settings.trustedDevices.isEmpty {
                Text("No trusted devices yet.").foregroundStyle(.secondary)
            } else {
                ForEach(settings.trustedDevices) { device in
                    HStack {
                        Image(systemName: Format.deviceSymbol(device.type)).accessibilityHidden(true)
                        VStack(alignment: .leading) {
                            Text(device.name)
                            Text("Added \(device.added.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove") { settings.trustedDevices.removeAll { $0.id == device.id } }
                            .accessibilityLabel("Remove \(device.name)")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct DiagnosticsSettings: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @State private var copied = false
    @State private var showAdvanced = false

    var body: some View {
        Form {
            Toggle("Verbose protocol logging", isOn: $settings.verboseLogging)
            Text("Logs every protocol step: frame types, order, sizes and states. Never file contents, file names, paths or keys.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(copied ? "Copied" : "Copy Diagnostic Log") {
                    model.copyDiagnosticLog()
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                }
                Button("Clear Log") { model.log.clear() }
                Spacer()
                Text("\(model.log.count) entries").font(.caption).foregroundStyle(.secondary)
            }

            DisclosureGroup("Advanced protocol options", isExpanded: $showAdvanced) {
                ProtocolOptionsEditor(options: $settings.protocolOptions)
            }
        }
        .formStyle(.grouped)
    }
}

/// Switches for the protocol details that still need device testing (docs/PROTOCOL_NOTES.md §14).
struct ProtocolOptionsEditor: View {
    @Binding var options: ProtocolOptions

    var body: some View {
        Text("Only change these when troubleshooting. Changes apply immediately and restart discovery.")
            .font(.caption).foregroundStyle(.secondary)
        Picker("EndpointInfo version (V2)", selection: $options.endpointInfoVersion) {
            Text("0").tag(UInt8(0))
            Text("1").tag(UInt8(1))
        }
        Picker("Advertise as", selection: $options.advertisedDeviceType) {
            ForEach([DeviceType.laptop, .tablet, .phone, .unknown], id: \.self) { Text(Format.deviceTypeName($0)).tag($0) }
        }
        Toggle("10-byte mDNS name (UWB + WebRTC bytes)", isOn: $options.serviceNameExtraBytes)
        Toggle("Send OS info in ConnectionResponse", isOn: $options.sendOSInfo)
        Toggle("Send legacy status field in ConnectionResponse", isOn: $options.sendLegacyStatusField)
        Toggle("Sender sends ConnectionResponse first (V3)", isOn: $options.senderSendsConnectionResponseFirst)
            .help("Turning this off makes sending to RQuickShare hang: it waits for the sender's response first.")
        Toggle("End files with an empty last chunk", isOn: $options.sendTrailingEmptyChunk)
        Toggle("Reply UPGRADE_FAILURE to bandwidth upgrades (V9)", isOn: $options.rejectBandwidthUpgrade)
        Picker("Re-announce on the network", selection: $options.reannounceInterval) {
            Text("Never").tag(TimeInterval(0))
            Text("Every 10 s").tag(TimeInterval(10))
            Text("Every 20 s").tag(TimeInterval(20))
            Text("Every 60 s").tag(TimeInterval(60))
        }
        .help("Phones that rejoin Wi-Fi after opening Quick Share only notice the Mac after a fresh announcement")
        Stepper("Keep-alive every \(Int(options.keepAliveInterval)) s", value: $options.keepAliveInterval, in: 2...20, step: 1)
        Stepper("Idle timeout \(Int(options.idleTimeout)) s", value: $options.idleTimeout, in: 15...180, step: 15)
        Picker("Send chunk size", selection: $options.chunkSize) {
            Text("128 KB").tag(128 * 1024)
            Text("512 KB").tag(512 * 1024)
            Text("1 MB").tag(1024 * 1024)
        }
        Button("Reset to Defaults") { options = ProtocolOptions() }
    }
}
