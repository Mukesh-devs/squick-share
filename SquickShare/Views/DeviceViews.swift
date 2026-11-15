import CoreImage
import CoreImage.CIFilterBuiltins
import QuickShareCore
import SwiftUI

// MARK: - Send page

struct SendPage: View {
    @EnvironmentObject private var model: AppModel
    @State private var showGuide = false

    private let columns = [GridItem(.adaptive(minimum: 168), spacing: 14, alignment: .top)]

    var body: some View {
        let outgoing = model.transfers(.outgoing)
        PageScroll {
            PageTitle(title: "Send", subtitle: "Share files with Android phones, tablets and PCs on your Wi-Fi.")
            if model.hasStatusBanner { StatusBanners() }
            if !model.pendingRequests.isEmpty { RequestStrip() }
            if model.pendingSendItems.isEmpty {
                DropHero()
            } else {
                SendTray()
            }

            if model.localNetworkDenied {
                SectionHeader(title: "Nearby Devices")
                EmptyStateView(symbol: "network.slash", title: "Can't look for devices",
                               message: "Allow squick-share to find devices on your local network in System Settings.")
            } else if let qr = model.qrSession {
                SectionHeader(title: "Scan to Send")
                QRCodePanel(session: qr)
            } else if model.visibleDevices.isEmpty {
                SectionHeader(title: "Nearby Devices")
                SearchingView()
            } else {
                SectionHeader(title: "Nearby Devices", linkTitle: showGuide ? "Hide Help" : "Phone not listed?") {
                    showGuide.toggle()
                }
                if showGuide { PhoneGuide() }
                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    ForEach(model.visibleDevices) { DeviceCard(device: $0) }
                }
            }

            if !outgoing.isEmpty {
                SectionHeader(title: "Sending")
                ForEach(outgoing) { TransferCard(transfer: $0) }
            }
        }
    }
}

/// The blue drop area at the top of Send. Clicking it chooses files.
private struct DropHero: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.windowDropTargeted) private var targeted

    var body: some View {
        Button { model.chooseFiles() } label: {
            HeroCard(dashed: true, lifted: targeted) {
                HStack(spacing: 22) {
                    HeroIcon(symbol: "doc.badge.arrow.up")
                    VStack(alignment: .leading, spacing: 4) {
                        Text(targeted ? "Drop to add to the send list" : "Drop files here to share")
                            .font(.system(size: 22, weight: .bold))
                        Text("Photos, videos, documents, folders and links. Or drop them right on a device below.")
                            .font(.system(size: 13.5))
                            .opacity(0.88)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(targeted ? 1.01 : 1)
        .animation(.easeOut(duration: 0.15), value: targeted)
        .help("Drop files here, or click to choose files (⌘O)")
        .accessibilityLabel("Drop files here to share")
        .accessibilityHint("Choose files to send")
    }
}

/// The files and text waiting to be sent.
private struct SendTray: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            DocIconStack(kinds: AppModel.kinds(of: model.pendingSendItems), size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("Ready to send \(model.sendSummary)")
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text((model.pendingSendBytes > 0 ? Format.bytes(model.pendingSendBytes) + " · " : "") + "Click a device below, or drop more files.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if model.qrSession == nil {
                Button { model.showQRCode() } label: { Image(systemName: "qrcode") }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                    .help("Show a QR code for a phone to scan (experimental)")
                    .accessibilityLabel("Show QR code")
            }
            Button("Add Files") { model.chooseFiles() }
                .buttonStyle(PillButtonStyle(kind: .secondary))
            Button("Clear") { model.clearSendItems() }
                .buttonStyle(PillButtonStyle(kind: .gray))
                .accessibilityLabel("Clear items to send")
        }
        .padding(14)
        .card(highlighted: true)
    }
}

// MARK: - Devices

/// One nearby device. Click it to send (or to choose files), or drop files on it.
/// While sending, a ring around its icon shows the progress, like AirDrop.
struct DeviceCard: View {
    @EnvironmentObject private var model: AppModel
    let device: DiscoveredDevice
    @State private var hovering = false
    @State private var targeted = false

    var body: some View {
        let transfer = model.transfer(to: device)
        Button { model.activate(device) } label: {
            VStack(spacing: 10) {
                DeviceAvatar(type: device.type, transfer: transfer)
                VStack(spacing: 2) {
                    Text(device.name ?? "Device")
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Text(status(transfer))
                        .font(.system(size: 12, weight: transfer == nil ? .regular : .semibold))
                        .foregroundStyle(statusColor(transfer))
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
            }
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity)
            .card(highlighted: targeted)
            .offset(y: hovering ? -1 : 0)
            .shadow(color: .black.opacity(hovering ? 0.08 : 0), radius: 8, y: 4)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onDrop(of: DropLoader.types, isTargeted: $targeted) { providers in
            DropLoader.load(providers) { files, texts in
                model.send(SendItems.expand(files) + texts.map { SendItem.text($0) }, to: device)
            }
        }
        .opacity(device.isAvailable ? 1 : 0.5)
        .help(help(transfer))
        .contextMenu {
            Button("Send Files…") { model.chooseFiles(for: device) }
            if !model.pendingSendItems.isEmpty {
                Button("Send \(model.sendSummary)") { model.send(to: device) }
            }
            if let transfer, !transfer.isFinished {
                Divider()
                Button("Cancel Transfer") { model.cancel(transfer) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(device.name ?? "Device"), \(status(transfer))")
        .accessibilityHint(model.pendingSendItems.isEmpty ? "Choose files to send" : "Sends \(model.sendSummary)")
        .accessibilityAddTraits(.isButton)
    }

    private func status(_ transfer: ActiveTransfer?) -> String {
        guard let transfer else {
            return device.isAvailable ? Format.deviceTypeName(device.type) : "Not responding"
        }
        switch transfer.phase {
        case .connecting: return "Connecting…"
        case .waitingForAcceptance(let pin): return "Waiting · PIN \(pin)"
        case .transferring: return "Sending · \(Int(transfer.fraction * 100))%"
        case .completed: return "Sent"
        case .failed(let message): return message.localizedCaseInsensitiveContains("declined") ? "Declined" : "Failed"
        }
    }

    private func statusColor(_ transfer: ActiveTransfer?) -> Color {
        guard let transfer else { return .secondary }
        switch transfer.phase {
        case .completed: return Theme.successText
        case .failed: return Theme.warningText
        case .transferring, .waitingForAcceptance: return .accentColor
        case .connecting: return .secondary
        }
    }

    private func help(_ transfer: ActiveTransfer?) -> String {
        if case .failed(let message)? = transfer?.phase { return message }
        if case .waitingForAcceptance(let pin)? = transfer?.phase {
            return "Accept on \(device.name ?? "the device") and check it shows PIN \(pin)."
        }
        return model.pendingSendItems.isEmpty ? "Click to choose files, or drop files here" : "Click to send \(model.sendSummary)"
    }
}

/// A device's symbol on a soft grey circle.
struct DeviceGlyph: View {
    let type: DeviceType
    var size: CGFloat = 66

    var body: some View {
        Image(systemName: Format.deviceSymbol(type))
            .font(.system(size: size * 0.38, weight: .regular))
            .foregroundStyle(Color.accentColor)
            .frame(width: size, height: size)
            .background(Circle().fill(Theme.neutralCircle))
            .overlay(Circle().strokeBorder(Theme.neutralRing, lineWidth: 1))
            .accessibilityHidden(true)
    }
}

/// The device's icon with a progress ring and a result badge.
struct DeviceAvatar: View {
    let type: DeviceType
    let transfer: ActiveTransfer?

    var body: some View {
        ZStack {
            if let transfer, !transfer.isFinished {
                Circle()
                    .stroke(Theme.accentSoft, lineWidth: 4)
                    .frame(width: 80, height: 80)
            }
            if let transfer, transfer.phase == .transferring {
                Circle()
                    .trim(from: 0, to: max(0.02, transfer.fraction))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 80, height: 80)
                    .animation(.linear(duration: 0.25), value: transfer.fraction)
            }
            DeviceGlyph(type: type, size: 66)
            if let badge {
                Image(systemName: badge.name)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(badge.color))
                    .overlay(Circle().strokeBorder(Theme.card, lineWidth: 3).padding(-3))
                    .offset(x: 26, y: 24)
            }
        }
        .frame(width: 84, height: 84)
        .accessibilityHidden(true)
    }

    private var badge: (name: String, color: Color)? {
        switch transfer?.phase {
        case .completed?: return ("checkmark", Theme.success)
        case .failed?: return ("exclamationmark", .orange)
        default: return nil
        }
    }
}

/// Shown until the first device appears.
private struct SearchingView: View {
    var body: some View {
        VStack(spacing: 16) {
            RadarSymbol()
            VStack(spacing: 4) {
                Text("Looking for nearby devices…").font(.system(size: 15, weight: .semibold))
                Text("Android phones appear here while their Quick Share screen is open.")
                    .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            PhoneGuide(embedded: true)
                .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 20)
        .card()
    }
}

/// A gently animated radar symbol (static before macOS 14).
private struct RadarSymbol: View {
    var body: some View {
        let image = Image(systemName: "dot.radiowaves.left.and.right")
            .font(.system(size: 28, weight: .regular))
            .foregroundStyle(Color.accentColor)
            .frame(width: 66, height: 66)
            .background(Circle().fill(Theme.neutralCircle))
            .accessibilityHidden(true)
        if #available(macOS 14.0, *) {
            image.symbolEffect(.variableColor.iterative, options: .repeating)
        } else {
            image
        }
    }
}

/// How to make an Android phone show up.
struct PhoneGuide: View {
    @EnvironmentObject private var model: AppModel
    /// Inside another card: no card of its own.
    var embedded = false

    var body: some View {
        let content = VStack(alignment: .leading, spacing: 10) {
            GuideStep(number: 1, text: "Make sure the phone and this Mac are on the same Wi-Fi network (not a guest network).")
            GuideStep(number: 2, text: "On the phone, open **Files › Quick Share › Receive**, or tap **Quick Share** in Quick Settings. Keep that screen open.")
            GuideStep(number: 3, text: "The phone appears here. Click it, or drop files on it.")
            if !model.pendingSendItems.isEmpty, model.qrSession == nil {
                Button { model.showQRCode() } label: {
                    Label("Show QR Code (experimental)", systemImage: "qrcode")
                }
                .buttonStyle(PillButtonStyle(kind: .secondary))
                .accessibilityHint("Shows a code for the phone to scan; sending starts automatically")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if embedded {
            content
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.page))
        } else {
            content
                .padding(16)
                .card()
        }
    }
}

struct GuideStep: View {
    let number: Int
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Theme.accentSoft))
                .accessibilityHidden(true)
            Text(text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Shows the QR code and waits for a phone to answer it.
struct QRCodePanel: View {
    @EnvironmentObject private var model: AppModel
    let session: QRCodeSession

    var body: some View {
        VStack(spacing: 12) {
            QRCodeImage(text: session.url.absoluteString)
                .frame(width: 200, height: 200)
                .accessibilityLabel("QR code for Quick Share")
            Text("Scan this with the phone's camera, or in Quick Share tap **Receive › Scan QR code**. Sending starts automatically.")
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Waiting for the phone…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Text("QR pairing is experimental. Same Wi-Fi network required.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Back to Nearby Devices") { model.hideQRCode() }
                .buttonStyle(PillButtonStyle(kind: .secondary))
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .card()
    }
}

struct QRCodeImage: View {
    let text: String

    var body: some View {
        if let image = Self.render(text) {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .padding(8)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.cardBorder))
        } else {
            Text(text).font(.caption).textSelection(.enabled)
        }
    }

    /// Rendering a QR code is costly; the view redraws often while it waits, so keep the last one.
    @MainActor private static var cached: (text: String, image: NSImage)?

    @MainActor static func render(_ text: String) -> NSImage? {
        if let cached, cached.text == text { return cached.image }
        guard let image = makeImage(text) else { return nil }
        cached = (text, image)
        return image
    }

    private static func makeImage(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}
