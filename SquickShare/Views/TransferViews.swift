import AppKit
import QuickShareCore
import SwiftUI
import UniformTypeIdentifiers

/// Accept/decline prompt, shown on the main window's Receive page.
struct IncomingRequestView: View {
    @EnvironmentObject private var model: AppModel
    let request: IncomingTransferRequest
    /// Inside the main window: no Return/Escape shortcuts, so typing elsewhere can't answer it.
    var inline = false
    @State private var trust = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: Format.deviceSymbol(request.device.type))
                    .font(.system(size: 30))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(request.device.name).font(.headline)
                    Text("wants to share with you").foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)

            PinBadge(pin: request.pin, caption: "Check that the other device shows the same PIN")

            OfferList(request: request)

            Toggle("Always accept from \(request.device.name)", isOn: $trust)
                .help("Future transfers from a device with this name and type are accepted without asking. Names are not verified.")
                .accessibilityHint("Adds this device to your trusted devices")

            HStack {
                Button("Decline", role: .cancel) { model.decline(request) }
                    .keyboardShortcut(inline ? nil : .cancelAction)
                    .accessibilityHint("Rejects this transfer")
                Spacer()
                // A standard button: the prominent style draws white-on-white in windows that aren't
                // active, which is exactly where this prompt appears (it never takes focus).
                Button("Accept") { model.accept(request, trust: trust) }
                    .keyboardShortcut(inline ? nil : .defaultAction)
                    .accessibilityHint("Saves to \(model.settings.downloadFolder.lastPathComponent)")
            }
            HStack {
                Text("Files are saved to \(model.settings.downloadFolder.lastPathComponent). They are never opened automatically.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("PIN doesn't match") { model.declineForPinMismatch(request) }
                    .buttonStyle(.link).font(.caption)
                    .accessibilityHint("Declines because the other device shows a different PIN")
            }
        }
        .padding(18)
    }
}

struct PinBadge: View {
    let pin: String
    let caption: String

    var body: some View {
        HStack(spacing: 10) {
            Text(pin)
                .font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
                .tracking(4)
            Text(caption).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("PIN \(spelled(pin)). \(caption)")
    }
}

/// Reads a PIN digit by digit for VoiceOver.
func spelled(_ pin: String) -> String { pin.map(String.init).joined(separator: " ") }

struct OfferList: View {
    let request: IncomingTransferRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(request.files.prefix(8).enumerated()), id: \.offset) { _, file in
                HStack(spacing: 8) {
                    Image(nsImage: icon(for: file.mimeType))
                        .resizable().frame(width: 24, height: 24)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 0) {
                        Text((file.parentFolder.map { $0 + "/" } ?? "") + file.name).lineLimit(1).truncationMode(.middle)
                        Text(Format.bytes(file.size)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if request.files.count > 8 {
                Text("and \(request.files.count - 8) more files").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(request.texts.enumerated()), id: \.offset) { _, text in
                Label(text.kind == .url ? "Link" : "Text", systemImage: text.kind == .url ? "link" : "text.alignleft")
            }
            if request.totalBytes > 0 {
                Text("Total \(Format.bytes(request.totalBytes))").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func icon(for mimeType: String) -> NSImage {
        let type = UTType(mimeType: mimeType) ?? .data
        return NSWorkspace.shared.icon(for: type)
    }
}

/// One active transfer with progress, speed, ETA and cancel.
struct TransferRow: View {
    @EnvironmentObject private var model: AppModel
    let transfer: ActiveTransfer

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: transfer.direction == .incoming ? "arrow.down.circle" : "arrow.up.circle")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel(transfer.direction == .incoming ? "Receiving" : "Sending")
                Text(transfer.summary).lineLimit(1).truncationMode(.middle)
                Spacer()
                if transfer.isFinished {
                    Button { model.dismiss(transfer) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Dismiss")
                } else if transfer.cancelling {
                    Text("Cancelling…").font(.caption).foregroundStyle(.secondary)
                } else {
                    Button("Cancel") { model.cancel(transfer) }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Cancel transfer")
                }
            }
            Text((transfer.direction == .incoming ? "From " : "To ") + transfer.deviceName)
                .font(.caption).foregroundStyle(.secondary)
            switch transfer.phase {
            case .connecting:
                ProgressView().progressViewStyle(.linear).accessibilityLabel("Connecting")
                Text("Connecting…").font(.caption).foregroundStyle(.secondary)
            case .waitingForAcceptance(let pin):
                PinBadge(pin: pin, caption: "Waiting for \(transfer.deviceName) to accept. Check it shows the same PIN.")
                Button("PIN doesn't match") { model.cancelForPinMismatch(transfer) }
                    .buttonStyle(.link).font(.caption)
                    .accessibilityHint("Cancels because the other device shows a different PIN")
            case .transferring:
                TransferProgressBar(fraction: transfer.fraction)
                    .accessibilityLabel("Progress")
                    .accessibilityValue("\(Int(transfer.fraction * 100)) percent")
                HStack {
                    Text("\(Format.bytes(transfer.bytes)) of \(Format.bytes(transfer.totalBytes))")
                    Spacer()
                    if transfer.meter.bytesPerSecond > 0 { Text(Format.speed(transfer.meter.bytesPerSecond)) }
                    if let eta = transfer.eta { Text("· \(Format.duration(eta)) left") }
                }
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            case .completed:
                Label("Done", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct RecentRow: View {
    @EnvironmentObject private var model: AppModel
    let recent: RecentTransfer

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: recent.succeeded ? (recent.direction == .incoming ? "arrow.down" : "arrow.up") : "exclamationmark.triangle")
                .foregroundStyle(recent.succeeded ? Color.secondary : Color.orange)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(recent.title).lineLimit(1).truncationMode(.middle)
                Text("\(recent.direction == .incoming ? "From" : "To") \(recent.deviceName) · \(recent.date.formatted(.relative(presentation: .named)))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if recent.direction == .incoming, !recent.fileURLs.isEmpty {
                Button { model.showInFinder(recent) } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.borderless)
                    .help("Show in Finder")
                    .accessibilityLabel("Show \(recent.title) in Finder")
            } else if let text = recent.text {
                Button { copy(text) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .help("Copy")
                    .accessibilityLabel("Copy text")
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// A slim progress bar drawn in SwiftUI (matches the menu bar ring and renders in snapshots).
struct TransferProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule().fill(Color.accentColor)
                    .frame(width: max(6, geometry.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 6)
        .animation(.linear(duration: 0.2), value: fraction)
        .accessibilityElement()
    }
}
