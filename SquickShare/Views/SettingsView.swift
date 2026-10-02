import QuickShareCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            TrustedDevicesSettings().tabItem { Label("Trusted Devices", systemImage: "checkmark.shield") }
            DiagnosticsSettings().tabItem { Label("Diagnostics", systemImage: "stethoscope") }
        }
        .frame(width: 500, height: 460)
        .padding(.top, 8)
    }
}

struct GeneralSettings: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @State private var nameDraft = ""
    @State private var nameError: String?
    @State private var loginError: String?

    var body: some View {
        Form {
            TextField("Device name", text: $nameDraft)
                .onSubmit(commitName)
                .onChange(of: nameDraft) { nameError = AppSettings.validateName($0) }
                .accessibilityHint("The name other devices see")
            if let nameError {
                Text(nameError).font(.caption).foregroundStyle(.red)
            } else if nameDraft != settings.deviceName {
                Button("Save Name", action: commitName)
            }

            Picker("Visibility", selection: $settings.visibility) {
                ForEach(Visibility.allCases) { Text($0.label).tag($0) }
            }
            if settings.visibility == .temporary, let until = settings.temporaryVisibilityUntil {
                Text("Hidden again in \(Format.countdown(until.timeIntervalSince(model.now)))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }

            LabeledContent("Save files to") {
                HStack {
                    Text(settings.downloadFolder.lastPathComponent)
                        .lineLimit(1)
                        .help(settings.downloadFolder.path)
                    Button("Choose…", action: chooseFolder)
                    if !settings.isDefaultDownloadFolder {
                        Button("Use Downloads") { settings.resetDownloadFolder() }
                    }
                }
            }

            Toggle("Launch at login", isOn: Binding(
                get: { settings.launchAtLogin },
                set: { loginError = settings.setLaunchAtLogin($0) }))
            if let loginError { Text(loginError).font(.caption).foregroundStyle(.orange) }

            Toggle("Show notifications", isOn: $settings.notificationsEnabled)

            Picker("Network", selection: $settings.interface) {
                Text("Any network").tag(InterfaceRestriction.any)
                Text("Wi-Fi only").tag(InterfaceRestriction.wifi)
                Text("Ethernet only").tag(InterfaceRestriction.wiredEthernet)
            }
            .help("Limit discovery and transfers to one kind of network interface")
        }
        .formStyle(.grouped)
        .onAppear { nameDraft = settings.deviceName; settings.refreshLaunchAtLogin() }
    }

    private func commitName() {
        guard AppSettings.validateName(nameDraft) == nil else { return }
        settings.deviceName = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        nameDraft = settings.deviceName
    }

    private func chooseFolder() {
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
