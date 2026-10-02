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
    private var generation = 0
    private var registered = false
    private var reannounceTimer: DispatchSourceTimer?
    /// EndpointInfo's 16 metadata bytes, random but stable for this receiver so the TXT record only
    /// changes when the user changes something.
    private let endpointMetadata = secureRandomBytes(16)
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
        stopLocked()

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

        generation += 1
        let generation = self.generation
        registered = false
        if configuration.advertise {
            newListener.service = makeServiceLocked()
        }

        let diagnostics = self.diagnostics
        let statusHandler = self.statusHandler
        newListener.stateUpdateHandler = { [weak self, weak newListener] state in
            switch state {
            case .ready:
                let port = newListener?.port?.rawValue ?? 0
                diagnostics.info("receiver", "listening on port \(port)")
                statusHandler(.advertising(port: port))
                self?.scheduleRegistrationWatchdog(generation: generation, attempt: 1)
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
        newListener.serviceRegistrationUpdateHandler = { [weak self] change in
            switch change {
            case .add:
                diagnostics.debug("receiver", "Bonjour service registered")
                self?.setRegistered(true, generation: generation)
            case .remove:
                diagnostics.debug("receiver", "Bonjour service removed")
                self?.setRegistered(false, generation: generation)
            @unknown default: break
            }
        }
        newListener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        newListener.start(queue: queue)
        listener = newListener
        scheduleReannounceTimerLocked(generation: generation)
    }

    public func stop() {
        lock.lock()
        stopLocked()
        lock.unlock()
    }

    private func stopLocked() {
        generation += 1
        reannounceTimer?.cancel()
        reannounceTimer = nil
        listener?.cancel()
        listener = nil
        registered = false
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return listener != nil
    }

    /// Applies a new name, options or interface. A running listener is restarted only when the interface
    /// changes; otherwise the Bonjour advertisement is updated in place (same port, no gap for peers).
    public func update(_ configuration: Configuration) {
        lock.lock()
        let running = listener != nil
        let interfaceChanged = self.configuration.interface != configuration.interface
        let intervalChanged = self.configuration.identity.options.reannounceInterval != configuration.identity.options.reannounceInterval
        var updated = configuration
        updated.advertise = self.configuration.advertise
        updated.port = self.configuration.port
        updated.qrCodeData = self.configuration.qrCodeData
        let changed = updated.identity != self.configuration.identity || interfaceChanged
        self.configuration = updated
        if running, intervalChanged { scheduleReannounceTimerLocked(generation: generation) }
        lock.unlock()
        guard running, changed else { return }
        if interfaceChanged { start() } else { reannounce(reason: "settings changed") }
    }

    /// Re-registers the Bonjour service on the running listener: a goodbye, then a fresh announcement.
    /// Phones whose mDNS queries went out before they joined this network only notice the Mac
    /// through such an announcement (seen with a Redmi that drops Wi-Fi when Quick Share opens).
    public func reannounce(reason: String = "manual") {
        lock.lock()
        guard let listener, configuration.advertise else {
            lock.unlock()
            return
        }
        let service = makeServiceLocked(log: false)
        let generation = self.generation
        lock.unlock()
        diagnostics.debug("receiver", "re-announcing Bonjour service (\(reason))")
        queue.async { [weak self] in
            listener.service = nil
            self?.queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, self.currentGeneration == generation else { return }
                listener.service = service
            }
        }
    }

    private var currentGeneration: Int {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    private func makeServiceLocked(log: Bool = true) -> NWListener.Service {
        let options = configuration.identity.options
        let name = ServiceName.make(endpointID: endpointID, extraBytes: options.serviceNameExtraBytes)
        let info = EndpointInfo(name: configuration.identity.name, deviceType: options.advertisedDeviceType,
                                version: options.endpointInfoVersion, metadata: endpointMetadata,
                                qrCodeData: configuration.qrCodeData)
        let txt = NWTXTRecord(["n": Base64URL.encode(info.serialize())])
        if log {
            diagnostics.info("receiver", "advertising \(ServiceName.serviceType) endpoint=\(endpointID) "
                + "infoVersion=\(options.endpointInfoVersion) type=\(options.advertisedDeviceType) "
                + "nameBytes=\(options.serviceNameExtraBytes ? 10 : 8) reannounce=\(Int(options.reannounceInterval))s")
        }
        return NWListener.Service(name: name, type: ServiceName.serviceType, domain: nil, txtRecord: txt)
    }

    private func setRegistered(_ value: Bool, generation: Int) {
        lock.lock()
        if generation == self.generation { registered = value }
        lock.unlock()
    }

    /// If Bonjour has not confirmed the registration a few seconds after the listener is ready
    /// (e.g. while the Local Network permission prompt is open), register again.
    private func scheduleRegistrationWatchdog(generation: Int, attempt: Int) {
        guard configuration.advertise, attempt <= 6 else { return }
        queue.asyncAfter(deadline: .now() + Double(5 * attempt)) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let pending = self.generation == generation && !self.registered && self.listener != nil
            self.lock.unlock()
            guard pending else { return }
            self.diagnostics.info("receiver", "Bonjour registration not confirmed (attempt \(attempt)); registering again")
            self.reannounce(reason: "registration watchdog")
            self.scheduleRegistrationWatchdog(generation: generation, attempt: attempt + 1)
        }
    }

    private func scheduleReannounceTimerLocked(generation: Int) {
        reannounceTimer?.cancel()
        reannounceTimer = nil
        let interval = configuration.identity.options.reannounceInterval
        guard configuration.advertise, interval > 0 else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self, self.currentGeneration == generation else { return }
            self.reannounce(reason: "periodic")
        }
        timer.resume()
        reannounceTimer = timer
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
