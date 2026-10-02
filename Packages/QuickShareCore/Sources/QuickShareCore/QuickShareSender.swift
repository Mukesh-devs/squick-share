import Foundation
import Network

/// A running outgoing transfer.
public final class OutgoingTransfer: Sendable {
    public let id: UUID
    private let session: OutboundSession

    init(session: OutboundSession) {
        id = session.id
        self.session = session
    }

    public func cancel() {
        let session = self.session
        Task { await session.cancel() }
    }
}

/// Sends files and text to a discovered device (we are the client).
public struct QuickShareSender: Sendable {
    public let identity: LocalIdentity
    public let interface: InterfaceRestriction
    private let diagnostics: Diagnostics

    public init(identity: LocalIdentity, interface: InterfaceRestriction = .any, diagnostics: Diagnostics) {
        self.identity = identity
        self.interface = interface
        self.diagnostics = diagnostics
    }

    /// Starts sending `items` to `device`. Events arrive on `eventHandler` from a background context.
    /// Pass the `qrSession` the device was matched with, if any, so the phone can skip its prompt.
    @discardableResult
    public func send(_ items: [SendItem], to device: DiscoveredDevice, qrSession: QRCodeSession? = nil,
                     eventHandler: @escaping @Sendable (TransferEvent) -> Void) -> OutgoingTransfer {
        let endpoint = device.endpoint
        let interface = self.interface
        var remote = device.remoteDevice
        if let qrSession, let name = device.qrMatch(qrSession) {
            remote = RemoteDevice(endpointID: remote.endpointID, name: name, type: remote.type)
        }
        return start(items, device: remote, qrSession: qrSession, eventHandler: eventHandler) {
            try await Self.connect(endpoint.value, interface: interface)
        }
    }

    /// Sends to a host and port directly (no discovery). Used by tests and the CLI.
    @discardableResult
    public func send(_ items: [SendItem], host: String, port: UInt16, deviceName: String = "Receiver",
                     eventHandler: @escaping @Sendable (TransferEvent) -> Void) -> OutgoingTransfer {
        let endpoint = SendableEndpoint(value: .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!))
        let interface = self.interface
        let device = RemoteDevice(endpointID: "????", name: deviceName, type: .unknown)
        return start(items, device: device, qrSession: nil, eventHandler: eventHandler) {
            try await Self.connect(endpoint.value, interface: interface)
        }
    }

    @discardableResult
    func start(_ items: [SendItem], device: RemoteDevice, qrSession: QRCodeSession?,
               eventHandler: @escaping @Sendable (TransferEvent) -> Void,
               makeStream: @escaping @Sendable () async throws -> ByteStream) -> OutgoingTransfer {
        let session = OutboundSession(makeStream: makeStream, items: items, device: device, identity: identity,
                                      qrSession: qrSession, diagnostics: diagnostics, emit: eventHandler)
        Task { await session.run() }
        return OutgoingTransfer(session: session)
    }

    static func connect(_ endpoint: NWEndpoint, interface: InterfaceRestriction) async throws -> ByteStream {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        switch interface {
        case .any: break
        case .wifi: parameters.requiredInterfaceType = .wifi
        case .wiredEthernet: parameters.requiredInterfaceType = .wiredEthernet
        }
        let stream = NWByteStream(connection: NWConnection(to: endpoint, using: parameters))
        do {
            try await stream.start(timeout: Limits.connectTimeout)
        } catch let error as TransportError {
            if case .localNetworkDenied = error { throw TransferError.localNetworkDenied }
            throw TransferError.unreachable
        }
        return stream
    }
}
