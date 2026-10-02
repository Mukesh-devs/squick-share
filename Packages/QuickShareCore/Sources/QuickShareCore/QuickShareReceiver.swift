import Foundation
import Network

/// Restricts which network interfaces are used for discovery and connections.
public enum InterfaceRestriction: String, Sendable, Codable, CaseIterable {
    case any, wifi, wiredEthernet
}

public enum ReceiverStatus: Sendable, Equatable {
    case stopped
    case advertising(port: UInt16)
    case localNetworkDenied
    case failed(String)
}

/// Advertises this Mac over mDNS and receives transfers (we are the server).
public final class QuickShareReceiver: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var identity: LocalIdentity
        public var interface: InterfaceRestriction = .any
        /// Seconds to wait for the user to accept before replying TIMED_OUT.
        public var decisionTimeout: TimeInterval = 60
        /// When false the listener runs without Bonjour (used by loopback tests).
        var advertise = true
        /// Fixed port for tests; nil picks any free port.
        var port: UInt16?
        /// QR TLV to advertise, as a phone does after scanning a QR code (tests only).
        var qrCodeData: Data?

        public init(identity: LocalIdentity) {
            self.identity = identity
        }
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "squickshare.receiver")
    private var configuration: Configuration
    private var listener: NWListener?
    private var sessions: [UUID: InboundSession] = [:]
    /// Our endpoint ID, so a browser on this Mac can hide our own advertisement.
    public let endpointID = ServiceName.randomEndpointID()
    private let diagnostics: Diagnostics
    private let eventHandler: @Sendable (TransferEvent) -> Void
    private let statusHandler: @Sendable (ReceiverStatus) -> Void

    public init(configuration: Configuration, diagnostics: Diagnostics,
                eventHandler: @escaping @Sendable (TransferEvent) -> Void,
                statusHandler: @escaping @Sendable (ReceiverStatus) -> Void = { _ in }) {
        self.configuration = configuration
        self.diagnostics = diagnostics
        self.eventHandler = eventHandler
        self.statusHandler = statusHandler
    }

    /// Starts listening and advertising. Calling it again restarts with the current configuration.
    public func start() {
        lock.lock()
        defer { lock.unlock() }
        listener?.cancel()
        listener = nil

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        switch configuration.interface {
        case .any: break
        case .wifi: parameters.requiredInterfaceType = .wifi
        case .wiredEthernet: parameters.requiredInterfaceType = .wiredEthernet
        }
        let newListener: NWListener
        do {
            if let port = configuration.port, let nwPort = NWEndpoint.Port(rawValue: port) {
                newListener = try NWListener(using: parameters, on: nwPort)
            } else {
                newListener = try NWListener(using: parameters)
            }
        } catch {
            diagnostics.error("receiver", "cannot create listener: \(error)")
            statusHandler(.failed("Couldn't start listening: \(error.localizedDescription)"))
            return
        }

        if configuration.advertise {
            let options = configuration.identity.options
            let name = ServiceName.make(endpointID: endpointID, extraBytes: options.serviceNameExtraBytes)
            let info = EndpointInfo(name: configuration.identity.name, deviceType: options.advertisedDeviceType,
                                    version: options.endpointInfoVersion, qrCodeData: configuration.qrCodeData)
            let txt = NWTXTRecord(["n": Base64URL.encode(info.serialize())])
            newListener.service = NWListener.Service(name: name, type: ServiceName.serviceType, domain: nil, txtRecord: txt)
            diagnostics.info("receiver", "advertising \(ServiceName.serviceType) endpoint=\(endpointID) "
                + "infoVersion=\(options.endpointInfoVersion) type=\(options.advertisedDeviceType) nameBytes=\(options.serviceNameExtraBytes ? 10 : 8)")
        }

        let diagnostics = self.diagnostics
        let statusHandler = self.statusHandler
        newListener.stateUpdateHandler = { [weak newListener] state in
            switch state {
            case .ready:
                let port = newListener?.port?.rawValue ?? 0
                diagnostics.info("receiver", "listening on port \(port)")
                statusHandler(.advertising(port: port))
            case .waiting(let error), .failed(let error):
                if case .dns(let code) = error, code == -65570 {
                    diagnostics.error("receiver", "local network permission denied")
                    statusHandler(.localNetworkDenied)
                } else {
                    diagnostics.error("receiver", "listener error: \(error)")
                    statusHandler(.failed(error.localizedDescription))
                }
            case .cancelled:
                statusHandler(.stopped)
            default:
                break
            }
        }
        newListener.serviceRegistrationUpdateHandler = { change in
            switch change {
            case .add: diagnostics.debug("receiver", "Bonjour service registered")
            case .remove: diagnostics.debug("receiver", "Bonjour service removed")
            @unknown default: break
            }
        }
        newListener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        newListener.start(queue: queue)
        listener = newListener
    }

    public func stop() {
        lock.lock()
        let current = listener
        listener = nil
        lock.unlock()
        current?.cancel()
    }

    /// Updates name, options or interface. Restarts advertising if it is running.
    public func update(_ configuration: Configuration) {
        lock.lock()
        let running = listener != nil
        var updated = configuration
        updated.advertise = self.configuration.advertise
        updated.port = self.configuration.port
        updated.qrCodeData = self.configuration.qrCodeData
        self.configuration = updated
        lock.unlock()
        if running { start() }
    }

    /// The port the listener is bound to, once ready.
    public var port: UInt16? {
        lock.lock()
        defer { lock.unlock() }
        return listener?.port?.rawValue
    }

    public func respond(to transferID: UUID, accept: Bool, destination: URL?) {
        guard let session = session(transferID) else { return }
        Task { await session.respond(accept: accept, destination: destination) }
    }

    public func cancel(_ transferID: UUID) {
        guard let session = session(transferID) else { return }
        Task { await session.cancel() }
    }

    private func session(_ id: UUID) -> InboundSession? {
        lock.lock()
        defer { lock.unlock() }
        return sessions[id]
    }

    private func accept(_ connection: NWConnection) {
        diagnostics.info("receiver", "incoming connection")
        let stream = NWByteStream(connection: connection)
        connection.start(queue: DispatchQueue(label: "squickshare.inbound"))
        lock.lock()
        let config = InboundSession.Configuration(identity: configuration.identity, decisionTimeout: configuration.decisionTimeout)
        let session = InboundSession(stream: stream, configuration: config, diagnostics: diagnostics,
                                     emit: eventHandler, onFinish: { [weak self] id in self?.remove(id) })
        sessions[session.id] = session
        lock.unlock()
        Task { await session.run() }
    }

    private func remove(_ id: UUID) {
        lock.lock()
        sessions[id] = nil
        lock.unlock()
    }
}
