import CoreImage
import CoreImage.CIFilterBuiltins
import QuickShareCore
import SwiftUI

/// One nearby device. Click it to send (or to choose files), or drop files on it.
/// While sending, its circle shows the progress, like AirDrop.
struct DeviceTile: View {
    @EnvironmentObject private var model: AppModel
    let device: DiscoveredDevice
    @State private var hovering = false
    @State private var targeted = false

    var body: some View {
        let transfer = model.transfer(to: device)
        Button { model.activate(device) } label: {
            VStack(spacing: 8) {
                DeviceAvatar(type: device.type, transfer: transfer)
                VStack(spacing: 2) {
                    Text(device.name ?? "Device")
                        .font(.callout.weight(.medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    Text(status(transfer))
                        .font(.caption)
                        .foregroundStyle(statusColor(transfer))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 146, alignment: .top)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(background))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(targeted ? Color.accentColor : Color.clear, lineWidth: 2))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
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

    private var background: Color {
        if targeted { return Color.accentColor.opacity(0.16) }
        return hovering ? Color.primary.opacity(0.06) : Color.clear
    }

    private func status(_ transfer: ActiveTransfer?) -> String {
        guard let transfer else {
            return device.isAvailable ? Format.deviceTypeName(device.type) : "Not responding"
        }
        switch transfer.phase {
        case .connecting: return "Connecting…"
        case .waitingForAcceptance(let pin): return "Waiting · PIN \(pin)"
        case .transferring: return "Sending \(Int(transfer.fraction * 100))%"
        case .completed: return "Sent"
        case .failed(let message): return message.localizedCaseInsensitiveContains("declined") ? "Declined" : "Failed"
        }
    }

    private func statusColor(_ transfer: ActiveTransfer?) -> Color {
        guard let transfer else { return .secondary }
        switch transfer.phase {
        case .completed: return .green
        case .failed: return .orange
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

/// The device's round icon with a progress ring and a result badge.
struct DeviceAvatar: View {
    let type: DeviceType
    let transfer: ActiveTransfer?

    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [Color.accentColor.opacity(0.75), Color.accentColor],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 62, height: 62)
            Image(systemName: Format.deviceSymbol(type))
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(.white)
            if let transfer, !transfer.isFinished {
                Circle()
                    .stroke(Color.accentColor.opacity(0.2), lineWidth: 3)
                    .frame(width: 72, height: 72)
                Circle()
                    .trim(from: 0, to: max(0.02, transfer.fraction))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 72, height: 72)
                    .animation(.linear(duration: 0.25), value: transfer.fraction)
            }
            if let symbol = badge {
                Image(systemName: symbol.name)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.white, symbol.color)
                    .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).padding(1))
                    .offset(x: 24, y: 24)
            }
        }
        .frame(width: 76, height: 76)
        .accessibilityHidden(true)
    }

    private var badge: (name: String, color: Color)? {
        switch transfer?.phase {
        case .completed?: return ("checkmark.circle.fill", .green)
        case .failed?: return ("exclamationmark.circle.fill", .orange)
        default: return nil
        }
    }
}

/// How to make an Android phone show up.
struct PhoneGuide: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GuideStep(number: 1, text: "Make sure the phone and this Mac are on the same Wi-Fi network (not a guest network).")
            GuideStep(number: 2, text: "On the phone, open **Files › Quick Share › Receive**, or tap **Quick Share** in Quick Settings. Keep that screen open.")
            GuideStep(number: 3, text: "The phone appears here. Click it, or drop files on it.")
            if !model.pendingSendItems.isEmpty, model.qrSession == nil {
                Button { model.showQRCode() } label: {
                    Label("Show QR Code (experimental)", systemImage: "qrcode")
                }
                .buttonStyle(.link)
                .accessibilityHint("Shows a code for the phone to scan; sending starts automatically")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
    }
}

struct GuideStep: View {
    let number: Int
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.accentColor.opacity(0.2)))
                .accessibilityHidden(true)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Shows the QR code and waits for a phone to answer it.
struct QRCodePanel: View {
    @EnvironmentObject private var model: AppModel
    let session: QRCodeSession

    var body: some View {
        VStack(spacing: 10) {
            QRCodeImage(text: session.url.absoluteString)
                .frame(width: 200, height: 200)
                .accessibilityLabel("QR code for Quick Share")
            Text("Scan this with the phone's camera, or in Quick Share tap **Receive › Scan QR code**. Sending starts automatically.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Waiting for the phone…").font(.caption).foregroundStyle(.secondary)
            }
            Text("QR pairing is experimental. Same Wi-Fi network required.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Back to Nearby Devices") { model.hideQRCode() }
                .buttonStyle(.link)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
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
                .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
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
