import CoreImage
import CoreImage.CIFilterBuiltins
import QuickShareCore
import SwiftUI

/// Picks a nearby device for the pending send items. Used in the popover and in the Send window.
struct SendPanel: View {
    @EnvironmentObject private var model: AppModel
    let showsClose: Bool
    @State private var showGuide = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "square.and.arrow.up").accessibilityHidden(true)
                Text("Send \(model.sendSummary)").font(.headline).lineLimit(2)
                Spacer()
                Button("Clear") { model.clearSendItems() }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Clear items to send")
            }

            if let qr = model.qrSession {
                QRCodePanel(session: qr)
            } else {
                deviceList
                Button {
                    showGuide.toggle()
                } label: {
                    Label("Phone not listed?", systemImage: showGuide ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Help: phone not listed")
                if showGuide || (model.nearbyDevices.isEmpty && model.browserStatus == .browsing) {
                    guide
                }
            }
        }
    }

    @ViewBuilder private var deviceList: some View {
        if model.browserStatus == .localNetworkDenied {
            Text("Local network permission is off, so nearby devices can't be found.")
                .font(.callout).foregroundStyle(.secondary)
        } else if model.nearbyDevices.isEmpty {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Looking for nearby devices…").foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        } else {
            VStack(spacing: 4) {
                ForEach(model.nearbyDevices.filter { $0.name != nil }) { device in
                    Button { model.send(to: device) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: Format.deviceSymbol(device.type))
                                .frame(width: 22)
                                .foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(device.name ?? "").lineLimit(1)
                                Text(Format.deviceTypeName(device.type)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                    }
                    .buttonStyle(.plain)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel("Send to \(device.name ?? "device"), \(Format.deviceTypeName(device.type))")
                }
            }
        }
    }

    private var guide: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Android phones only show up while they are ready to receive:")
                .font(.callout)
            GuideStep(number: 1, text: "Make sure the phone and this Mac are on the same Wi-Fi network.")
            GuideStep(number: 2, text: "On the phone, open **Files › Quick Share › Receive** (or pull down Quick Settings and tap **Quick Share**). Keep that screen open.")
            GuideStep(number: 3, text: "The phone appears in the list above. Click it.")
            Divider()
            Text("Or scan a QR code with the phone's camera:").font(.callout)
            Button {
                model.showQRCode()
            } label: {
                Label("Show QR Code", systemImage: "qrcode")
            }
            .accessibilityHint("Shows a code for the phone to scan; sending starts automatically")
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
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
            Text("Same Wi-Fi network required. If the phone asks, choose to receive from this device.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Back to device list") { model.hideQRCode() }
                .buttonStyle(.borderless)
        }
        .frame(maxWidth: .infinity)
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

    static func render(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}
