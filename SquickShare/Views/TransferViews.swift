import AppKit
import QuickShareCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Document icons

/// A document icon like Finder's: a white page with a folded corner, a type symbol and a type label.
struct DocIcon: View {
    let kind: DocKind
    var size: CGFloat = 34

    var body: some View {
        let height = size * 1.22
        ZStack(alignment: .top) {
            DocPageShape()
                .fill(Color.white)
                .shadow(color: .black.opacity(0.14), radius: 1.2, y: 0.6)
            DocPageShape()
                .stroke(Color.black.opacity(0.14), lineWidth: 0.75)
            DocFoldShape()
                .fill(Color(white: 0.89))
            DocFoldShape()
                .stroke(Color.black.opacity(0.12), lineWidth: 0.75)
            VStack(spacing: size * 0.04) {
                Image(systemName: kind.symbol)
                    .font(.system(size: size * 0.36, weight: .medium))
                Text(kind.label)
                    .font(.system(size: max(6, size * 0.22), weight: .bold, ))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .foregroundStyle(kind.tint)
            .padding(.top, height * 0.24)
            .padding(.horizontal, size * 0.06)
        }
        .frame(width: size, height: height)
        .accessibilityHidden(true)
    }
}

/// A page outline with the top-right corner cut off.
struct DocPageShape: Shape {
    func path(in rect: CGRect) -> Path {
        let fold = rect.width * 0.3
        let radius = rect.width * 0.1
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - fold, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + fold))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// The folded corner.
struct DocFoldShape: Shape {
    func path(in rect: CGRect) -> Path {
        let fold = rect.width * 0.3
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX - fold, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - fold, y: rect.minY + fold * 0.8))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - fold * 0.8, y: rect.minY + fold),
                          control: CGPoint(x: rect.maxX - fold, y: rect.minY + fold))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + fold))
        path.closeSubpath()
        return path
    }
}

/// Up to four overlapping document icons, then "+N".
struct DocIconStack: View {
    let kinds: [DocKind]
    var size: CGFloat = 30

    var body: some View {
        HStack(spacing: -size * 0.22) {
            ForEach(Array(kinds.prefix(4).enumerated()), id: \.offset) { _, kind in
                DocIcon(kind: kind, size: size)
            }
            if kinds.count > 4 {
                Text("+\(kinds.count - 4)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, size * 0.32)
            }
        }
        .accessibilityHidden(true)
    }
}

extension DocKind {
    var symbol: String {
        switch category {
        case .image: return "photo"
        case .video: return label == "MOV" ? "film" : "play"
        case .audio: return "music.note"
        case .pdf: return "doc.text"
        case .document: return label == "KEY" || label == "PPTX" || label == "PPT" ? "rectangle.on.rectangle" : "doc.plaintext"
        case .archive: return "archivebox"
        case .link: return "link"
        case .text: return "text.alignleft"
        case .other: return "doc"
        }
    }

    var tint: Color {
        switch category {
        case .image, .link, .text: return Color(red: 10 / 255, green: 132 / 255, blue: 1)
        case .video: return Color(red: 142 / 255, green: 68 / 255, blue: 239 / 255)
        case .audio: return Color(red: 1, green: 45 / 255, blue: 85 / 255)
        case .pdf: return Color(red: 229 / 255, green: 72 / 255, blue: 77 / 255)
        case .document: return label == "KEY" ? Color(white: 0.56) : Color(red: 0.2, green: 0.45, blue: 0.95)
        case .archive, .other: return Color(white: 0.56)
        }
    }

    /// "photo", "video", "document"…, for History's description line.
    var noun: String {
        switch category {
        case .image: return "photo"
        case .video: return "video"
        case .audio: return "audio file"
        case .pdf, .document: return "document"
        case .archive: return "archive"
        case .link: return "link"
        case .text: return "text"
        case .other: return "file"
        }
    }
}

extension IncomingTransferRequest {
    var kinds: [DocKind] {
        files.map { DocKind(fileName: $0.name) } + texts.map { $0.kind == .url ? DocKind.link : DocKind.text }
    }

    /// "3 files and a link · 188 MB".
    var offerSummary: String {
        var parts: [String] = []
        if !files.isEmpty { parts.append(files.count == 1 ? "1 file" : "\(files.count) files") }
        let links = texts.filter { $0.kind == .url }.count
        let notes = texts.count - links
        if links > 0 { parts.append(links == 1 ? "a link" : "\(links) links") }
        if notes > 0 { parts.append(notes == 1 ? "text" : "\(notes) texts") }
        var line = parts.isEmpty ? "Transfer" : parts.joined(separator: " and ")
        if totalBytes > 0 { line += " · " + Format.bytes(totalBytes) }
        return line
    }
}

extension RecentTransfer {
    /// Kinds for the icon; entries saved before kinds were stored are worked out from their names.
    var displayKinds: [DocKind] {
        if let kinds, !kinds.isEmpty { return kinds }
        if !itemNames.isEmpty { return itemNames.map { DocKind(fileName: $0) } }
        return text.map { [DocKind(text: $0)] } ?? [DocKind(category: .other, label: "FILE")]
    }
}

/// Reads a PIN digit by digit for VoiceOver.
func spelled(_ pin: String) -> String { pin.map(String.init).joined(separator: " ") }

// MARK: - Transfers

/// One active transfer: icons, progress, speed, time left and Cancel.
/// Sends show a bar; receives show a ring with the percentage.
struct TransferCard: View {
    @EnvironmentObject private var model: AppModel
    let transfer: ActiveTransfer

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            if transfer.direction == .incoming {
                ProgressRing(transfer: transfer)
            } else {
                DocIconStack(kinds: kinds, size: 32)
                    .frame(minWidth: 70, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                detail
                if transfer.direction == .outgoing, transfer.phase == .transferring {
                    TransferProgressBar(fraction: transfer.fraction)
                        .padding(.top, 4)
                        .accessibilityLabel("Progress")
                        .accessibilityValue("\(Int(transfer.fraction * 100)) percent")
                }
                if transfer.direction == .incoming {
                    DocIconStack(kinds: kinds, size: 24).padding(.top, 4)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(16)
        .card()
        .accessibilityElement(children: .contain)
    }

    private var kinds: [DocKind] {
        transfer.kinds.isEmpty ? [DocKind(category: .other, label: "FILE")] : transfer.kinds
    }

    private var title: String {
        "\(transfer.summary) \(transfer.direction == .incoming ? "from" : "to") \(transfer.deviceName)"
    }

    @ViewBuilder private var detail: some View {
        switch transfer.phase {
        case .connecting:
            Text("Connecting…").font(.system(size: 12)).foregroundStyle(.secondary)
        case .waitingForAcceptance(let pin):
            HStack(spacing: 8) {
                Text("Waiting for \(transfer.deviceName) to accept · PIN \(pin)")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel("Waiting for \(transfer.deviceName) to accept. PIN \(spelled(pin))")
                Button("PIN doesn't match") { model.cancelForPinMismatch(transfer) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityHint("Cancels because the other device shows a different PIN")
            }
        case .transferring:
            Text(progressText)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        case .completed:
            Label(transfer.direction == .incoming ? "Saved to \(model.settings.downloadFolder.lastPathComponent)" : "Sent",
                  systemImage: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.successText)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.warningText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var progressText: String {
        var parts = ["\(Format.bytes(transfer.bytes)) of \(Format.bytes(transfer.totalBytes))"]
        if transfer.meter.bytesPerSecond > 0 { parts.append(Format.speed(transfer.meter.bytesPerSecond)) }
        if let eta = transfer.eta { parts.append("\(Format.duration(eta)) left") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var trailing: some View {
        if transfer.isFinished {
            HStack(spacing: 8) {
                if transfer.phase == .completed, !transfer.savedFiles.isEmpty {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(transfer.savedFiles) }
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                }
                Button { model.dismiss(transfer) } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(PillButtonStyle(kind: .gray))
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
            }
        } else if transfer.cancelling {
            Text("Cancelling…").font(.system(size: 12.5)).foregroundStyle(.secondary)
        } else {
            Button("Cancel") { model.cancel(transfer) }
                .buttonStyle(.plain)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityLabel("Cancel transfer")
        }
    }
}

/// A receive's progress as a ring with the percentage inside.
private struct ProgressRing: View {
    let transfer: ActiveTransfer

    var body: some View {
        ZStack {
            Circle().stroke(Theme.accentSoft, lineWidth: 5)
            if transfer.phase == .transferring || transfer.phase == .completed {
                Circle()
                    .trim(from: 0, to: max(0.02, transfer.phase == .completed ? 1 : transfer.fraction))
                    .stroke(transfer.phase == .completed ? Theme.success : Color.accentColor,
                            style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.25), value: transfer.fraction)
            }
            switch transfer.phase {
            case .transferring:
                Text("\(Int(transfer.fraction * 100))%")
                    .font(.system(size: 13, weight: .bold).monospacedDigit())
            case .completed:
                Image(systemName: "checkmark").font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.success)
            case .failed:
                Image(systemName: "exclamationmark").font(.system(size: 18, weight: .bold)).foregroundStyle(.orange)
            case .connecting, .waitingForAcceptance:
                Image(systemName: "arrow.down").font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.accentColor)
            }
        }
        .frame(width: 52, height: 52)
        .padding(.horizontal, 4)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int(transfer.fraction * 100)) percent")
    }
}

/// A slim progress bar drawn in SwiftUI (matches the menu bar ring and renders in snapshots).
struct TransferProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.accentSoft)
                Capsule().fill(Color.accentColor)
                    .frame(width: max(6, geometry.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 6)
        .animation(.linear(duration: 0.2), value: fraction)
        .accessibilityElement()
    }
}

// MARK: - Receive page

struct ReceivePage: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let incoming = model.transfers(.incoming)
        PageScroll {
            PageTitle(title: "Receive", subtitle: "Android phones send to this Mac with Quick Share.")
            if model.hasStatusBanner { StatusBanners() }
            VisibilityHero()

            if !model.pendingRequests.isEmpty {
                SectionHeader(title: "Waiting for You")
                ForEach(model.pendingRequests) { RequestCard(request: $0) }
            }

            if !incoming.isEmpty {
                SectionHeader(title: "Receiving")
                ForEach(incoming) { TransferCard(transfer: $0) }
            }

            SaveLocationCard()
                .padding(.top, 4)

            if model.pendingRequests.isEmpty, incoming.isEmpty {
                SectionHeader(title: "How to Send from a Phone")
                VStack(alignment: .leading, spacing: 10) {
                    GuideStep(number: 1, text: "On the phone, share a photo, video or file and choose **Quick Share**.")
                    GuideStep(number: 2, text: "Tap **\(model.identity.name)**. Both devices must be on the same Wi-Fi network.")
                    GuideStep(number: 3, text: "Check that both show the same PIN, then click **Accept** here or in the notification.")
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
            }
        }
    }
}

/// This Mac's name, who can see it, and the control to change it, on the blue card.
private struct VisibilityHero: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        HeroCard {
            // The layout depends on the window's width only, never on the text, so the card keeps
            // the same height whichever visibility is chosen.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 22) {
                    identity
                        .frame(minWidth: 260, idealWidth: 260, maxWidth: .infinity, alignment: .leading)
                    controls
                }
                VStack(alignment: .leading, spacing: 16) {
                    identity
                        .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity, alignment: .leading)
                    controls
                }
            }
        }
    }

    private var identity: some View {
        HStack(spacing: 22) {
            HeroIcon(symbol: settings.visibility == .hidden ? "eye.slash" : "laptopcomputer")
            VStack(alignment: .leading, spacing: 4) {
                Text(model.identity.name)
                    .font(.system(size: 22, weight: .bold))
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 13.5))
                    .opacity(0.88)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            GlassSegmented(selection: $settings.visibility, options: [
                (.everyone, "Everyone"), (.temporary, "10 Minutes"), (.hidden, "No One"),
            ])
            .accessibilityLabel("Allow me to be discovered by")
            Button { model.announceAgain() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 12, weight: .semibold))
                    Text("Announce")
                }
            }
            .buttonStyle(PillButtonStyle(kind: .glass))
            .disabled(settings.visibility == .hidden)
            .help("Tell nearby phones about this Mac now (useful if a phone just reconnected to Wi-Fi)")
        }
        .fixedSize()
    }

    private var detail: String {
        if model.localNetworkDenied { return "Phones can't see this Mac until local network access is on." }
        if !model.hasNetwork { return "Not connected to a network." }
        if case .failed = model.receiverStatus { return "Can't be discovered right now. Retrying…" }
        switch settings.visibility {
        case .everyone: return "Visible to everyone on this Wi-Fi network"
        case .temporary:
            let remaining = (settings.temporaryVisibilityUntil ?? model.now).timeIntervalSince(model.now)
            return "Visible to everyone for \(Format.countdown(remaining))"
        case .hidden: return "Hidden from nearby devices"
        }
    }
}

/// A segmented control drawn for the blue card.
struct GlassSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let selected = option.0 == selection
                Button { selection = option.0 } label: {
                    Text(option.1)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(selected ? Theme.brandBottom : Color.white)
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color.white)
                                    .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.18)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}

/// A request waiting for an answer: who, what, the PIN, Accept and Decline.
private struct RequestCard: View {
    @EnvironmentObject private var model: AppModel
    let request: IncomingTransferRequest
    @State private var trust = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) {
                    who
                    Spacer(minLength: 12)
                    pin
                    buttons
                }
                VStack(alignment: .leading, spacing: 16) {
                    who
                    HStack(spacing: 18) {
                        pin
                        Spacer(minLength: 12)
                        buttons
                    }
                }
            }
            .padding(18)
            Rectangle().fill(Theme.cardBorder).frame(height: 1)
            HStack(spacing: 12) {
                Toggle("Always accept from \(request.device.name)", isOn: $trust)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                    .help("Future transfers from a device with this name and type are accepted without asking. Names are not verified.")
                    .accessibilityHint("Adds this device to your trusted devices")
                Spacer(minLength: 8)
                Button("PIN doesn't match") { model.declineForPinMismatch(request) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityHint("Declines because the other device shows a different PIN")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
        .card(highlighted: true)
        .accessibilityElement(children: .contain)
    }

    private var who: some View {
        HStack(spacing: 16) {
            DeviceGlyph(type: request.device.type, size: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(request.device.name) wants to share")
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(request.offerSummary)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                DocIconStack(kinds: request.kinds, size: 28)
                    .padding(.top, 4)
                    .help(request.files.map(\.name).joined(separator: "\n"))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var pin: some View {
        VStack(spacing: 8) {
            Text("CHECK THE PIN")
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            PinDigits(pin: request.pin)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("PIN \(spelled(request.pin)). Check that the other device shows the same PIN.")
    }

    private var buttons: some View {
        VStack(spacing: 8) {
            Button { model.accept(request, trust: trust) } label: { Text("Accept").frame(minWidth: 60) }
                .buttonStyle(PillButtonStyle(kind: .primary, large: true, rounded: true))
                .accessibilityHint("Saves to \(model.settings.downloadFolder.lastPathComponent)")
            Button { model.decline(request) } label: { Text("Decline").frame(minWidth: 60) }
                .buttonStyle(PillButtonStyle(kind: .gray, large: true, rounded: true))
                .accessibilityHint("Rejects this transfer")
        }
        .fixedSize()
    }
}

/// The PIN as large digits on soft blue tiles.
struct PinDigits: View {
    let pin: String

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(pin.enumerated()), id: \.offset) { _, digit in
                Text(String(digit))
                    .font(.system(size: 26, weight: .bold).monospacedDigit())
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 38, height: 48)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.accentSoft))
            }
        }
        .fixedSize()
    }
}

/// Where received files go.
private struct SaveLocationCard: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(symbol: "arrow.down.doc.fill", tint: SettingsIcon.cyan, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Files are saved to \(settings.downloadFolder.lastPathComponent)")
                    .font(.system(size: 13.5, weight: .medium))
                    .lineLimit(1)
                    .help(settings.downloadFolder.path)
                Text("Received files are never opened automatically.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Show in Finder") { model.openDownloadFolder() }
                .buttonStyle(PillButtonStyle(kind: .secondary))
            Button("Change…") { FolderChooser.choose(settings) }
                .buttonStyle(PillButtonStyle(kind: .secondary))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .card()
    }
}

// MARK: - History page

struct HistoryPage: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection: UUID?

    var body: some View {
        let items = model.filteredRecents
        PageScroll(spacing: 10) {
            PageTitle(title: "History", subtitle: "Everything you sent and received. Double-click to open, drag a file out to Finder, or right-click for more.")
                .padding(.bottom, 6)
            if model.hasStatusBanner { StatusBanners() }
            if !model.pendingRequests.isEmpty { RequestStrip() }
            if model.recents.isEmpty {
                EmptyStateView(symbol: "clock", title: "No transfers yet",
                               message: "Files and links you send or receive appear here.")
            } else if items.isEmpty {
                EmptyStateView(symbol: "magnifyingglass", title: "No matches",
                               message: model.historyQuery.isEmpty ? "Nothing here for this filter."
                                   : "Nothing in your history matches “\(model.historyQuery)”.")
            } else {
                ForEach(Self.days(items), id: \.day) { group in
                    Text(Self.heading(group.day))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.top, 6)
                        .accessibilityAddTraits(.isHeader)
                    VStack(spacing: 0) {
                        ForEach(Array(group.items.enumerated()), id: \.element.id) { index, recent in
                            HistoryRow(recent: recent, selected: selection == recent.id) {
                                selection = recent.id
                            }
                            if index < group.items.count - 1 {
                                Rectangle().fill(Theme.cardBorder).frame(height: 1).padding(.leading, 62)
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .card()
                }
                HStack(spacing: 8) {
                    Button("Open Downloads Folder") { model.openDownloadFolder() }
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                    Spacer()
                    Button("Clear History") {
                        selection = nil
                        model.clearRecents()
                    }
                    .buttonStyle(PillButtonStyle(kind: .gray))
                }
                .padding(.top, 8)
            }
        }
        .background {
            // Keyboard: Return opens the selected entry (⌘F, in the app's menu, searches).
            Button("Open Selected") {
                // Return in the toolbar's search field belongs to the field.
                if NSApp.keyWindow?.firstResponder is NSText { return }
                if let id = selection, let recent = model.recents.first(where: { $0.id == id }) { model.open(recent) }
            }
            .keyboardShortcut(.return, modifiers: [])
            .disabled(selection == nil)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
    }

    private struct Day {
        let day: Date
        let items: [RecentTransfer]
    }

    private static func days(_ items: [RecentTransfer]) -> [Day] {
        let calendar = Calendar.current
        var order: [Date] = []
        var groups: [Date: [RecentTransfer]] = [:]
        for item in items.sorted(by: { $0.date > $1.date }) {
            let day = calendar.startOfDay(for: item.date)
            if groups[day] == nil { order.append(day) }
            groups[day, default: []].append(item)
        }
        return order.map { Day(day: $0, items: groups[$0] ?? []) }
    }

    private static func heading(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }
}

/// One History entry: icon, name, what happened, device, size and time.
private struct HistoryRow: View {
    @EnvironmentObject private var model: AppModel
    let recent: RecentTransfer
    let selected: Bool
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                main
                Spacer(minLength: 12)
                device.frame(width: 150, alignment: .leading)
                size.frame(width: 70, alignment: .trailing)
                time.frame(width: 72, alignment: .trailing)
            }
            HStack(spacing: 14) {
                main
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    time
                    size
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(selected ? Theme.rowSelection : (hovering ? Theme.fill.opacity(0.5) : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { model.open(recent) }
        .onTapGesture { select() }
        .onDrag { dragItem }
        .contextMenu {
            Button("Open") { model.open(recent) }
            if recent.direction == .incoming, !recent.fileURLs.isEmpty {
                Button("Show in Finder") { model.showInFinder(recent) }
            }
            if let text = recent.text {
                Button(Format.webURL(text) != nil ? "Copy Link" : "Copy Text") { model.copyText(text) }
            } else if !recent.itemNames.isEmpty {
                Button("Copy Name") { model.copyText(recent.itemNames.joined(separator: "\n")) }
            }
            Divider()
            Button("Remove from History") { model.removeRecent(recent) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(recent.title). \(description). \(recent.deviceName). \(recent.date.formatted(date: .abbreviated, time: .shortened))")
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : [.isButton])
        .accessibilityAction { model.open(recent) }
    }

    private var main: some View {
        HStack(spacing: 14) {
            DocIcon(kind: recent.displayKinds.first ?? DocKind(category: .other, label: "FILE"), size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(recent.succeeded ? Color.primary : Theme.failureText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(description)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .layoutPriority(1)
    }

    private var device: some View {
        HStack(spacing: 6) {
            Image(systemName: Format.deviceSymbol(recent.deviceType ?? .phone))
                .font(.system(size: 12))
                .accessibilityHidden(true)
            Text(recent.deviceName).lineLimit(1)
        }
        .font(.system(size: 12.5))
        .foregroundStyle(.secondary)
    }

    private var size: some View {
        Text(recent.totalBytes.map { Format.bytes($0) } ?? "—")
            .font(.system(size: 12.5).monospacedDigit())
            .foregroundStyle(.secondary)
    }

    private var time: some View {
        Text(recent.date.formatted(date: .omitted, time: .shortened))
            .font(.system(size: 12.5).monospacedDigit())
            .foregroundStyle(.secondary)
    }

    /// A link shows its address without the scheme.
    private var title: String {
        if recent.itemNames.isEmpty, let text = recent.text, let url = Format.webURL(text) {
            return (url.host ?? text) + url.path
        }
        return recent.title
    }

    /// "Received · 4.8 MB photo", "Sent · 3 items", "Not sent · The other device declined…".
    private var description: String {
        let incoming = recent.direction == .incoming
        guard recent.succeeded else {
            return (incoming ? "Not received" : "Not sent") + (recent.message.map { " · \($0)" } ?? "")
        }
        let verb = incoming ? "Received" : "Sent"
        let kinds = recent.displayKinds
        if kinds.count > 1 { return "\(verb) · \(kinds.count) items" }
        let noun = kinds.first?.noun ?? "file"
        if let bytes = recent.totalBytes, bytes > 0 { return "\(verb) · \(Format.bytes(bytes)) \(noun)" }
        return "\(verb) \(noun)"
    }

    /// Received files can be dragged out to Finder or another app.
    private var dragItem: NSItemProvider {
        guard recent.direction == .incoming,
              let url = recent.fileURLs.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let provider = NSItemProvider(contentsOf: url) else {
            return NSItemProvider()
        }
        return provider
    }
}
