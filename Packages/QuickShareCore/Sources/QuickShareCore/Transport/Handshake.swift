import Foundation
import SwiftProtobuf

/// The plaintext phase of a connection: ConnectionRequest, UKEY2 and ConnectionResponse (PROTOCOL_NOTES §4.1).
enum Handshake {
    /// Server (receiver) side. Returns the peer and the UKEY2 result.
    static func runServer(stream: ByteStream, identity: LocalIdentity, diagnostics: Diagnostics, tag: String)
        async throws -> (RemoteDevice, Ukey2Result)
    {
        let request = try await readOffline(stream, stage: "ConnectionRequest", tag: tag, diagnostics: diagnostics)
        guard request.v1.type == .connectionRequest else {
            throw TransferError.protocolViolation("expected CONNECTION_REQUEST, got \(request.v1.type)")
        }
        let device = remoteDevice(from: request.v1.connectionRequest)
        diagnostics.info(tag, "connection request from endpoint \(device.endpointID) type=\(device.type) "
            + "mediums=\(request.v1.connectionRequest.mediums) infoLen=\(request.v1.connectionRequest.endpointInfo.count) "
            + "keepAlive=\(request.v1.connectionRequest.keepAliveIntervalMillis)/\(request.v1.connectionRequest.keepAliveTimeoutMillis)ms")

        var server = Ukey2Server()
        let clientInit = try await readRaw(stream, stage: "UKEY2 ClientInit", tag: tag, diagnostics: diagnostics)
        let serverInit: Data
        do {
            serverInit = try server.handleClientInit(clientInit)
        } catch let error as Ukey2Error {
            if let alert = Ukey2Server.alert(for: error) { try? await stream.writeFrame(alert) }
            throw TransferError.protocolViolation(error.description)
        }
        diagnostics.debug(tag, "→ UKEY2 ServerInit [\(serverInit.count + 4) B]")
        try await stream.writeFrame(serverInit)

        let clientFinish = try await readRaw(stream, stage: "UKEY2 ClientFinish", tag: tag, diagnostics: diagnostics)
        let result: Ukey2Result
        do {
            result = try server.handleClientFinish(clientFinish)
        } catch let error as Ukey2Error {
            throw TransferError.protocolViolation(error.description)
        }
        diagnostics.info(tag, "UKEY2 complete")

        try await writeOffline(stream, OfflineFrames.connectionResponse(options: identity.options), tag: tag, diagnostics: diagnostics)
        let response = try await readOffline(stream, stage: "ConnectionResponse", tag: tag, diagnostics: diagnostics)
        try checkConnectionResponse(response)
        return (device, result)
    }

    /// Client (sender) side. Returns the UKEY2 result.
    static func runClient(stream: ByteStream, endpointID: String, identity: LocalIdentity,
                          diagnostics: Diagnostics, tag: String) async throws -> Ukey2Result
    {
        let info = EndpointInfo(name: identity.name, deviceType: identity.options.advertisedDeviceType,
                                version: identity.options.endpointInfoVersion)
        try await writeOffline(stream, OfflineFrames.connectionRequest(endpointID: endpointID, name: identity.name,
                                                                      endpointInfo: info.serialize()),
                               tag: tag, diagnostics: diagnostics)
        let client = try Ukey2Client()
        diagnostics.debug(tag, "→ UKEY2 ClientInit [\(client.clientInit.count + 4) B]")
        try await stream.writeFrame(client.clientInit)

        let serverInit = try await readRaw(stream, stage: "UKEY2 ServerInit", tag: tag, diagnostics: diagnostics)
        let result: Ukey2Result
        do {
            result = try client.handleServerInit(serverInit)
        } catch let error as Ukey2Error {
            throw TransferError.protocolViolation(error.description)
        }
        diagnostics.debug(tag, "→ UKEY2 ClientFinish [\(client.clientFinish.count + 4) B]")
        try await stream.writeFrame(client.clientFinish)
        diagnostics.info(tag, "UKEY2 complete")

        let ours = OfflineFrames.connectionResponse(options: identity.options)
        if identity.options.senderSendsConnectionResponseFirst {
            try await writeOffline(stream, ours, tag: tag, diagnostics: diagnostics)
            try checkConnectionResponse(try await readOffline(stream, stage: "ConnectionResponse", tag: tag, diagnostics: diagnostics))
        } else {
            try checkConnectionResponse(try await readOffline(stream, stage: "ConnectionResponse", tag: tag, diagnostics: diagnostics))
            try await writeOffline(stream, ours, tag: tag, diagnostics: diagnostics)
        }
        return result
    }

    static func remoteDevice(from request: Location_Nearby_Connections_ConnectionRequestFrame) -> RemoteDevice {
        let info = try? EndpointInfo(parsing: request.endpointInfo)
        let rawName = info?.name ?? (request.endpointName.isEmpty ? "Unknown device" : request.endpointName)
        let endpointID = FileNameSanitizer.displayString(request.endpointID, maxLength: 8)
        return RemoteDevice(endpointID: endpointID, name: FileNameSanitizer.displayString(rawName), type: info?.deviceType ?? .unknown)
    }

    private static func checkConnectionResponse(_ frame: OfflineFrame) throws {
        guard frame.v1.type == .connectionResponse else {
            throw TransferError.protocolViolation("expected CONNECTION_RESPONSE, got \(frame.v1.type)")
        }
        let response = frame.v1.connectionResponse
        let accepted = response.response == .accept || (!response.hasResponse && response.status == 0)
        guard accepted else { throw TransferError.declined }
    }

    private static func readRaw(_ stream: ByteStream, stage: String, tag: String, diagnostics: Diagnostics) async throws -> Data {
        let data = try await withTimeout(Limits.handshakeTimeout, stage: stage, onTimeout: { stream.close() }) {
            try await stream.readFrame()
        }
        diagnostics.debug(tag, "← \(stage) [\(data.count + 4) B]")
        return data
    }

    private static func readOffline(_ stream: ByteStream, stage: String, tag: String, diagnostics: Diagnostics) async throws -> OfflineFrame {
        let data = try await withTimeout(Limits.handshakeTimeout, stage: stage, onTimeout: { stream.close() }) {
            try await stream.readFrame()
        }
        guard let frame = try? OfflineFrame(serializedBytes: data), frame.hasV1 else {
            throw TransferError.protocolViolation("undecodable \(stage)")
        }
        diagnostics.debug(tag, "← \(frame.logDescription) [\(data.count + 4) B]")
        return frame
    }

    private static func writeOffline(_ stream: ByteStream, _ frame: OfflineFrame, tag: String, diagnostics: Diagnostics) async throws {
        let data: Data = try frame.serializedBytes()
        diagnostics.debug(tag, "→ \(frame.logDescription) [\(data.count + 4) B]")
        try await stream.writeFrame(data)
    }
}

/// Maps any error from the stack to the user-facing `TransferError`.
func transferError(from error: Error) -> TransferError {
    switch error {
    case let error as TransferError: return error
    case let error as TransportError:
        switch error {
        case .closed, .network: return .connectionLost
        case .timedOut: return .timedOut
        case .frameTooLarge: return .protocolViolation(error.description)
        case .localNetworkDenied: return .localNetworkDenied
        }
    case let error as Ukey2Error: return .protocolViolation(error.description)
    case let error as SecureChannelError: return .protocolViolation(error.description)
    case let error as DestinationError: return .fileAccess("\(error)")
    case is CancellationError: return .cancelledByUser
    default: return .protocolViolation(String(describing: type(of: error)))
    }
}
