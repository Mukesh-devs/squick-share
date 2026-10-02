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
    private let queue = DispatchQueue(label: "squickshare.browser")
    private let diagnostics: Diagnostics
    private let interface: InterfaceRestriction
    private let updateHandler: @Sendable ([DiscoveredDevice]) -> Void
    private let statusHandler: @Sendable (BrowserStatus) -> Void
    /// Our own receiver's endpoint ID, so we don't list ourselves.
    private let ownEndpointIDs: @Sendable () -> Set<String>

    public init(diagnostics: Diagnostics, interface: InterfaceRestriction = .any,
                excluding ownEndpointIDs: @escaping @Sendable () -> Set<String> = { [] },
                updateHandler: @escaping @Sendable ([DiscoveredDevice]) -> Void,
                statusHandler: @escaping @Sendable (BrowserStatus) -> Void = { _ in }) {
        self.diagnostics = diagnostics
        self.interface = interface
        self.ownEndpointIDs = ownEndpointIDs
        self.updateHandler = updateHandler
        self.statusHandler = statusHandler
    }

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard browser == nil else { return }
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
                diagnostics.info("browser", "browsing for \(ServiceName.serviceType)")
                statusHandler(.browsing)
            case .waiting(let error), .failed(let error):
                if case .dns(let code) = error, code == -65570 {
                    diagnostics.error("browser", "local network permission denied")
                    statusHandler(.localNetworkDenied)
                } else {
                    diagnostics.error("browser", "browser error: \(error)")
                    statusHandler(.failed(error.localizedDescription))
                }
            case .cancelled:
                statusHandler(.stopped)
            default:
                break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.publish(results)
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    public func stop() {
        lock.lock()
        let current = browser
        browser = nil
        lock.unlock()
        current?.cancel()
    }

    private func publish(_ results: Set<NWBrowser.Result>) {
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
        devices.sort { ($0.name ?? "~") < ($1.name ?? "~") }
        diagnostics.debug("browser", "found \(devices.count) device(s): "
            + devices.map { "\($0.endpointID)/\($0.type)\($0.name == nil ? "/hidden" : "")\($0.endpointInfo.qrCodeData != nil ? "/qr" : "")" }.joined(separator: ", "))
        updateHandler(devices)
    }
}
