import Foundation

/// Device type advertised in EndpointInfo (`ShareTargetType`, PROTOCOL_NOTES §2.4).
public enum DeviceType: Int, Sendable, Codable, CaseIterable, Hashable {
    case unknown = 0
    case phone = 1
    case tablet = 2
    case laptop = 3
    case car = 4
    case foldable = 5
    case xr = 6
}

/// The peer of a transfer.
public struct RemoteDevice: Sendable, Hashable, Codable {
    public let endpointID: String
    public let name: String
    public let type: DeviceType

    public init(endpointID: String, name: String, type: DeviceType) {
        self.endpointID = endpointID
        self.name = name
        self.type = type
    }
}

public enum TextKind: Sendable, Hashable, Codable {
    case text, url, address, phoneNumber
}

/// A file offered by a sender. `name` and `parentFolder` are already sanitized.
public struct FileOffer: Sendable, Hashable {
    public let name: String
    public let size: Int64
    public let mimeType: String
    public let parentFolder: String?
}

public struct TextOffer: Sendable, Hashable {
    public let title: String
    public let kind: TextKind
    public let size: Int64
}

/// An incoming transfer waiting for the user to accept or decline.
public struct IncomingTransferRequest: Sendable, Identifiable {
    public let id: UUID
    public let device: RemoteDevice
    public let pin: String
    public let files: [FileOffer]
    public let texts: [TextOffer]

    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
}

/// Something to send.
public enum SendItem: Sendable, Hashable {
    /// A regular file. `parentFolder` is the relative folder path to preserve, e.g. "Photos/2024".
    case file(URL, parentFolder: String?)
    case text(String)
}

public enum TransferError: Error, Sendable, Equatable {
    case declined
    case cancelledByPeer
    case cancelledByUser
    case timedOut
    case connectionLost
    case notEnoughSpace
    case diskFull
    case fileTooLarge
    case unsupportedContent
    case unreachable
    case localNetworkDenied
    case fileAccess(String)
    case protocolViolation(String)

    public var userMessage: String {
        switch self {
        case .declined: "The other device declined the transfer."
        case .cancelledByPeer: "The other device cancelled the transfer."
        case .cancelledByUser: "Transfer cancelled."
        case .timedOut: "The other device stopped responding."
        case .connectionLost: "Connection lost. Both devices must be on the same Wi-Fi network."
        case .notEnoughSpace: "There isn't enough disk space for this transfer."
        case .diskFull: "The disk is full."
        case .fileTooLarge: "A file is too large to transfer."
        case .unsupportedContent: "This kind of content isn't supported."
        case .unreachable: "Couldn't reach the device. Both devices must be on the same Wi-Fi network."
        case .localNetworkDenied: "Local network permission is off."
        case .fileAccess(let detail): "Couldn't read or write a file: \(detail)"
        case .protocolViolation: "The other device sent something unexpected, so the transfer was stopped."
        }
    }
}

/// Events for one transfer, in either direction.
public enum TransferEvent: Sendable {
    /// Incoming only: a sender asks to send. Answer with `QuickShareReceiver.respond`.
    case incomingRequest(IncomingTransferRequest)
    /// Outgoing only: connected, PIN known, waiting for the other device to accept.
    case awaitingAcceptance(transferID: UUID, device: RemoteDevice, pin: String)
    /// Byte progress across all files of the transfer.
    case progress(transferID: UUID, bytes: Int64, totalBytes: Int64)
    /// Incoming only: one file was written to its final location.
    case receivedFile(transferID: UUID, url: URL)
    /// Incoming only: a text item arrived.
    case receivedText(transferID: UUID, text: String, kind: TextKind)
    case completed(transferID: UUID)
    case failed(transferID: UUID, error: TransferError)

    public var transferID: UUID {
        switch self {
        case .incomingRequest(let request): request.id
        case .awaitingAcceptance(let id, _, _), .progress(let id, _, _), .receivedFile(let id, _),
             .receivedText(let id, _, _), .completed(let id), .failed(let id, _): id
        }
    }
}

/// Protocol knobs for uncertain behavior (PROTOCOL_NOTES §12 VERIFY items).
/// The app exposes them under Settings → Diagnostics so they can change without a rebuild.
public struct ProtocolOptions: Sendable, Codable, Equatable {
    /// EndpointInfo version bits (V2). Google parses 0 and 1.
    public var endpointInfoVersion: UInt8 = 0
    /// Device type we advertise.
    public var advertisedDeviceType: DeviceType = .laptop
    /// Append the UWB-length and WebRTC bytes to the mDNS instance name (10 bytes instead of 8).
    public var serviceNameExtraBytes: Bool = true
    /// Include `os_info` (APPLE) in our ConnectionResponse.
    public var sendOSInfo: Bool = true
    /// Include the deprecated `status = 0` field in our ConnectionResponse.
    public var sendLegacyStatusField: Bool = true
    /// As a sender, send our ConnectionResponse right after ClientFinished instead of waiting for the server's (V3).
    public var senderSendsConnectionResponseFirst: Bool = true
    /// As a sender, end each file with an empty LAST_CHUNK frame (Google's behavior) instead of flagging the last data chunk.
    public var sendTrailingEmptyChunk: Bool = true
    /// Reply to bandwidth-upgrade offers with UPGRADE_FAILURE (otherwise ignore them silently) (V9).
    public var rejectBandwidthUpgrade: Bool = true
    /// Interval between our KEEP_ALIVE frames.
    public var keepAliveInterval: TimeInterval = 5
    /// Close the connection after this long without any inbound frame.
    public var idleTimeout: TimeInterval = 45
    /// File chunk size for sending.
    public var chunkSize: Int = 512 * 1024

    public init() {}
}

/// Identity we present to peers.
public struct LocalIdentity: Sendable, Equatable {
    public var name: String
    public var options: ProtocolOptions

    public init(name: String, options: ProtocolOptions = ProtocolOptions()) {
        self.name = name
        self.options = options
    }
}
