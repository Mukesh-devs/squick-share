import Foundation
import QuickShareCore
import ServiceManagement

enum Visibility: String, CaseIterable, Identifiable, Codable {
    case everyone, hidden, temporary
    var id: String { rawValue }

    var label: String {
        switch self {
        case .everyone: "Everyone"
        case .hidden: "Hidden"
        case .temporary: "Visible for 10 minutes"
        }
    }
}

/// A device the user chose to trust for auto-accept. Quick Share without Google accounts has no
/// stable device identity, so trust is by advertised name and type only.
struct TrustedDevice: Codable, Hashable, Identifiable {
    var name: String
    var type: DeviceType
    var added: Date
    var id: String { "\(type.rawValue)|\(name)" }
}

/// User settings, persisted in UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    static let temporaryVisibilityDuration: TimeInterval = 10 * 60
    private let defaults = UserDefaults.standard

    @Published var deviceName: String { didSet { defaults.set(deviceName, forKey: "deviceName") } }
    @Published var visibility: Visibility { didSet { defaults.set(visibility.rawValue, forKey: "visibility") } }
    @Published var temporaryVisibilityUntil: Date?
    @Published var autoAcceptTrusted: Bool { didSet { defaults.set(autoAcceptTrusted, forKey: "autoAcceptTrusted") } }
    @Published var trustedDevices: [TrustedDevice] { didSet { save(trustedDevices, "trustedDevices") } }
    @Published var notificationsEnabled: Bool { didSet { defaults.set(notificationsEnabled, forKey: "notificationsEnabled") } }
    @Published var interface: InterfaceRestriction { didSet { defaults.set(interface.rawValue, forKey: "interface") } }
    @Published var verboseLogging: Bool { didSet { defaults.set(verboseLogging, forKey: "verboseLogging") } }
    @Published var protocolOptions: ProtocolOptions { didSet { save(protocolOptions, "protocolOptions") } }
    @Published private(set) var downloadFolder: URL
    @Published private(set) var launchAtLogin = false

    private var scopedFolder: URL?

    init() {
        let defaultName = Host.current().localizedName ?? "Mac"
        deviceName = defaults.string(forKey: "deviceName").flatMap { Self.validateName($0) == nil ? $0 : nil } ?? defaultName
        let storedVisibility = Visibility(rawValue: defaults.string(forKey: "visibility") ?? "") ?? .everyone
        visibility = storedVisibility == .temporary ? .hidden : storedVisibility   // a timer never survives a relaunch
        autoAcceptTrusted = defaults.bool(forKey: "autoAcceptTrusted")
        notificationsEnabled = defaults.object(forKey: "notificationsEnabled") as? Bool ?? true
        interface = InterfaceRestriction(rawValue: defaults.string(forKey: "interface") ?? "") ?? .any
        verboseLogging = defaults.bool(forKey: "verboseLogging")
        trustedDevices = Self.load([TrustedDevice].self, "trustedDevices") ?? []
        protocolOptions = Self.load(ProtocolOptions.self, "protocolOptions") ?? ProtocolOptions()
        downloadFolder = Self.realDownloadsFolder
        restoreDownloadFolder()
        refreshLaunchAtLogin()
    }

    // MARK: Device name

    /// Returns an error message, or nil if `name` is acceptable.
    static func validateName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Enter a name." }
        if trimmed.count > 50 { return "Use 50 characters or fewer." }
        if trimmed.utf8.count > 100 { return "This name is too long." }
        if trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return "The name can't contain control characters."
        }
        return nil
    }

    // MARK: Download folder

    /// The user's real ~/Downloads (inside the sandbox, the Downloads URL API points into the container).
    static var realDownloadsFolder: URL {
        let home = getpwuid(getuid()).flatMap { $0.pointee.pw_dir.map { String(cString: $0) } } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("Downloads", isDirectory: true)
    }

    var isDefaultDownloadFolder: Bool { downloadFolder.standardizedFileURL == Self.realDownloadsFolder.standardizedFileURL }

    func setDownloadFolder(_ url: URL) {
        do {
            let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            defaults.set(bookmark, forKey: "downloadFolderBookmark")
            scopedFolder?.stopAccessingSecurityScopedResource()
            scopedFolder = url.startAccessingSecurityScopedResource() ? url : nil
            downloadFolder = url
        } catch {
            downloadFolder = url
        }
    }

    func resetDownloadFolder() {
        defaults.removeObject(forKey: "downloadFolderBookmark")
        scopedFolder?.stopAccessingSecurityScopedResource()
        scopedFolder = nil
        downloadFolder = Self.realDownloadsFolder
    }

    private func restoreDownloadFolder() {
        guard let data = defaults.data(forKey: "downloadFolderBookmark") else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
        else { return }
        if url.startAccessingSecurityScopedResource() { scopedFolder = url }
        downloadFolder = url
        if stale { setDownloadFolder(url) }
    }

    // MARK: Trusted devices

    func isTrusted(_ device: RemoteDevice) -> Bool {
        trustedDevices.contains { $0.name == device.name && $0.type == device.type }
    }

    func trust(_ device: RemoteDevice) {
        guard !isTrusted(device) else { return }
        trustedDevices.append(TrustedDevice(name: device.name, type: device.type, added: Date()))
    }

    // MARK: Launch at login

    func refreshLaunchAtLogin() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Returns an error message on failure.
    func setLaunchAtLogin(_ enabled: Bool) -> String? {
        defer { refreshLaunchAtLogin() }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            if enabled, SMAppService.mainApp.status == .requiresApproval {
                return "Allow squick-share in System Settings → General → Login Items."
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: Persistence helpers

    private func save<T: Encodable>(_ value: T, _ key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private static func load<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
