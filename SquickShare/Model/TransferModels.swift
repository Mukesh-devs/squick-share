import Foundation
import QuickShareCore

enum TransferDirection: String, Codable {
    case incoming, outgoing
}

/// Smooths transfer speed over the last few seconds.
struct SpeedMeter {
    private var samples: [(time: Date, bytes: Int64)] = []
    private(set) var bytesPerSecond: Double = 0

    mutating func add(_ bytes: Int64, at time: Date = Date()) {
        samples.append((time, bytes))
        samples.removeAll { time.timeIntervalSince($0.time) > 3 }
        guard let first = samples.first, samples.count > 1 else { return }
        let elapsed = time.timeIntervalSince(first.time)
        if elapsed > 0.2 { bytesPerSecond = Double(bytes - first.bytes) / elapsed }
    }
}

/// A transfer shown in the popover's "Active" list.
struct ActiveTransfer: Identifiable {
    enum Phase: Equatable {
        case connecting
        case waitingForAcceptance(pin: String)
        case transferring
        case completed
        case failed(String)
    }

    let id: UUID
    let direction: TransferDirection
    var deviceName: String
    var deviceType: DeviceType
    var summary: String
    var phase: Phase
    var bytes: Int64 = 0
    var totalBytes: Int64 = 0
    var meter = SpeedMeter()
    var savedFiles: [URL] = []
    var texts: [String] = []
    /// The user pressed Cancel; waiting for the session to stop.
    var cancelling = false

    var fraction: Double { totalBytes > 0 ? min(1, Double(bytes) / Double(totalBytes)) : 0 }

    var eta: TimeInterval? {
        guard phase == .transferring, meter.bytesPerSecond > 1, totalBytes > bytes else { return nil }
        return Double(totalBytes - bytes) / meter.bytesPerSecond
    }

    var isFinished: Bool {
        switch phase {
        case .completed, .failed: true
        default: false
        }
    }
}

/// A finished transfer kept in the "Recent" list (persisted).
struct RecentTransfer: Identifiable, Codable {
    let id: UUID
    let date: Date
    let direction: TransferDirection
    let deviceName: String
    let itemNames: [String]
    let fileURLs: [URL]
    let text: String?
    let succeeded: Bool
    let message: String?

    var title: String {
        if let first = itemNames.first {
            return itemNames.count == 1 ? first : "\(first) and \(itemNames.count - 1) more"
        }
        return text.map { String($0.prefix(60)) } ?? "Transfer"
    }
}

enum Format {
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        bytes(Int64(bytesPerSecond)) + "/s"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: seconds) ?? ""
    }

    static func countdown(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func summary(files: [String], texts: Int) -> String {
        var parts: [String] = []
        if files.count == 1 { parts.append(files[0]) } else if files.count > 1 { parts.append("\(files.count) files") }
        if texts == 1 { parts.append("text") } else if texts > 1 { parts.append("\(texts) texts") }
        return parts.isEmpty ? "Transfer" : parts.joined(separator: " and ")
    }

    static func deviceSymbol(_ type: DeviceType) -> String {
        switch type {
        case .phone, .foldable: "iphone"
        case .tablet: "ipad"
        case .laptop: "laptopcomputer"
        case .car: "car"
        case .xr: "visionpro"
        case .unknown: "desktopcomputer"
        }
    }

    static func deviceTypeName(_ type: DeviceType) -> String {
        switch type {
        case .phone: "Phone"
        case .foldable: "Foldable phone"
        case .tablet: "Tablet"
        case .laptop: "Laptop"
        case .car: "Car"
        case .xr: "Headset"
        case .unknown: "Device"
        }
    }
}
