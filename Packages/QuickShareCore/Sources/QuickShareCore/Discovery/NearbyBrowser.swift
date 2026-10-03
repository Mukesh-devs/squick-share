import Foundation
import Network

/// A Quick Share receiver found over mDNS.
public struct DiscoveredDevice: Sendable, Identifiable, Hashable {
    /// The Bonjour instance name (stable while the device advertises).
    public let id: String
    public let endpointID: String
    /// nil when the device advertises as hidden (only reachable through a QR code).
    public let name: String?
    public let type: DeviceType
    let endpoint: SendableEndpoint
    let endpointInfo: EndpointInfo

    public static func == (a: DiscoveredDevice, b: DiscoveredDevice) -> Bool {
        a.id == b.id && a.name == b.name && a.type == b.type
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// If this device answered `session`'s QR code, its display name (decrypted if hidden).
    public func qrMatch(_ session: QRCodeSession) -> String? {
        guard let match = session.match(endpointInfo) else { return nil }
        return match ?? name ?? "Phone"
    }

    var remoteDevice: RemoteDevice {
        RemoteDevice(endpointID: endpointID, name: name ?? "Hidden device", type: type)
    }
}

struct SendableEndpoint: @unchecked Sendable {
    let value: NWEndpoint
}

public enum BrowserStatus: Sendable, Equatable {
    case browsing
    case localNetworkDenied
    case failed(String)
    case stopped
}

/// Browses for Quick Share receivers (`_FC9F5ED42C8A._tcp`) with their TXT records.
public final class NearbyBrowser: @unchecked Sendable {
    private let lock = NSLock()
    private var browser: NWBrowser?
    private var generation = 0
    private var running = false
    private var requeryTimer: DispatchSourceTimer?
    /// Devices by Bonjour instance name, with when they were last reported.
    private var seen: [String: (device: DiscoveredDevice, lastSeen: Date)] = [:]
    /// Instance names in the current browser's latest result set.
    private var currentIDs: Set<String> = []
    private var lastLoggedSummary = ""
    private let queue = DispatchQueue(label: "squickshare.browser")
    private let diagnostics: Diagnostics
    private let interface: InterfaceRestriction
    private let requeryInterval: TimeInterval
    private let updateHandler: @Sendable ([DiscoveredDevice]) -> Void
    private let statusHandler: @Sendable (BrowserStatus) -> Void
    /// Our own receiver's endpoint ID, so we don't list ourselves.
    private let ownEndpointIDs: @Sendable () -> Set<String>
    /// How long a device stays listed after the browser that saw it was replaced.
    private static let retention: TimeInterval = 12

    /// - Parameter requeryInterval: restart the mDNS query this often (0 = never). mDNS queriers back off
    ///   exponentially, so a phone that joins the network after browsing started can otherwise go
    ///   unnoticed for a long time. Results are merged across restarts so the list doesn't flicker.
    public init(diagnostics: Diagnostics, interface: InterfaceRestriction = .any, requeryInterval: TimeInterval = 5,
                excluding ownEndpointIDs: @escaping @Sendable () -> Set<String> = { [] },
                updateHandler: @escaping @Sendable ([DiscoveredDevice]) -> Void,
                statusHandler: @escaping @Sendable (BrowserStatus) -> Void = { _ in }) {
        self.diagnostics = diagnostics
        self.interface = interface
        self.requeryInterval = requeryInterval
        self.ownEndpointIDs = ownEndpointIDs
        self.updateHandler = updateHandler
        self.statusHandler = statusHandler
    }

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { return }
        running = true
        startBrowserLocked(initial: true)
        if requeryInterval > 0 {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + requeryInterval, repeating: requeryInterval, leeway: .milliseconds(500))
            timer.setEventHandler { [weak self] in self?.requery() }
            timer.resume()
            requeryTimer = timer
        }
    }

    public func stop() {
        lock.lock()
        running = false
        generation += 1
        requeryTimer?.cancel()
        requeryTimer = nil
        let current = browser
        browser = nil
        seen.removeAll()
        currentIDs.removeAll()
        lock.unlock()
        current?.cancel()
    }

    private func requery() {
        lock.lock()
        guard running else { return lock.unlock() }
        let old = browser
        startBrowserLocked(initial: false)
        lock.unlock()
        old?.cancel()
        publishMerged()   // drops devices that have not been seen recently
    }

    private func startBrowserLocked(initial: Bool) {
        generation += 1
        let generation = self.generation
        currentIDs = []
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        switch interface {
        case .any: break
        case .wifi: parameters.requiredInterfaceType = .wifi
        case .wiredEthernet: parameters.requiredInterfaceType = .wiredEthernet
        }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: ServiceName.serviceType, domain: nil), using: parameters)
        let diagnostics = self.diagnostics
        let statusHandler = self.statusHandler
        browser.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if initial {
                    diagnostics.info("browser", "browsing for \(ServiceName.serviceType)")
                    statusHandler(.browsing)
                }
            case .waiting(let error), .failed(let error):
                if case .dns(let code) = error, code == -65570 {
                    diagnostics.error("browser", "local network permission denied")
                    statusHandler(.localNetworkDenied)
                } else {
                    diagnostics.error("browser", "browser error: \(error)")
                    statusHandler(.failed(error.localizedDescription))
                }
            case .cancelled:
                if initial { break }
            default:
                break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.publish(results, generation: generation)
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    private func publish(_ results: Set<NWBrowser.Result>, generation: Int) {
        let own = ownEndpointIDs()
        var devices: [DiscoveredDevice] = []
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint else { continue }
            guard let endpointID = ServiceName.parseEndpointID(name) else {
                diagnostics.debug("browser", "ignoring non-Quick Share instance")
                continue
            }
            guard !own.contains(endpointID) else { continue }
            guard case .bonjour(let txt) = result.metadata, let encoded = txt["n"],
                  let raw = Base64URL.decode(encoded), let info = try? EndpointInfo(parsing: raw)
            else {
                diagnostics.debug("browser", "endpoint \(endpointID): missing or invalid TXT record")
                continue
            }
            devices.append(DiscoveredDevice(
                id: name, endpointID: endpointID, name: info.name.map { FileNameSanitizer.displayString($0) },
                type: info.deviceType, endpoint: SendableEndpoint(value: result.endpoint), endpointInfo: info
            ))
        }
        lock.lock()
        guard running else { return lock.unlock() }
        let now = Date()
        for device in devices { seen[device.id] = (device, now) }
        if generation == self.generation { currentIDs = Set(devices.map(\.id)) }
        lock.unlock()
        publishMerged()
    }

    private func publishMerged() {
        lock.lock()
        let now = Date()
        seen = seen.filter { currentIDs.contains($0.key) || now.timeIntervalSince($0.value.lastSeen) < Self.retention }
        var devices = seen.values.map(\.device)
        devices.sort { ($0.name ?? "~") < ($1.name ?? "~") }
        let summary = "found \(devices.count) device(s): "
            + devices.map { "\($0.endpointID)/\($0.type)\($0.name == nil ? "/hidden" : "")\($0.endpointInfo.qrCodeData != nil ? "/qr" : "")" }.joined(separator: ", ")
        let changed = summary != lastLoggedSummary
        lastLoggedSummary = summary
        lock.unlock()
        if changed { diagnostics.debug("browser", summary) }
        updateHandler(devices)
    }
}

#if DEBUG
extension DiscoveredDevice {
    /// A fake device for UI previews and screenshots (debug builds only).
    public static func preview(name: String, type: DeviceType) -> DiscoveredDevice {
        let endpointID = ServiceName.randomEndpointID()
        return DiscoveredDevice(
            id: "preview-\(endpointID)", endpointID: endpointID, name: name, type: type,
            endpoint: SendableEndpoint(value: .hostPort(host: "127.0.0.1", port: 9)),
            endpointInfo: EndpointInfo(name: name, deviceType: type))
    }
}
#endif
