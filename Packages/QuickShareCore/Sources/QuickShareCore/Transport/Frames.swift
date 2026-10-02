import Foundation
import SwiftProtobuf

typealias OfflineFrame = Location_Nearby_Connections_OfflineFrame
typealias PayloadTransferFrame = Location_Nearby_Connections_PayloadTransferFrame
typealias SharingFrame = Nearby_Sharing_Service_Proto_Frame
typealias SharingV1Frame = Nearby_Sharing_Service_Proto_V1Frame

/// Builders for Nearby Connections frames (PROTOCOL_NOTES §4, §6, §8).
enum OfflineFrames {
    static func connectionRequest(endpointID: String, name: String, endpointInfo: Data) -> OfflineFrame {
        var frame = OfflineFrame()
        frame.version = .v1
        frame.v1.type = .connectionRequest
        frame.v1.connectionRequest.endpointID = endpointID
        frame.v1.connectionRequest.endpointName = name
        frame.v1.connectionRequest.endpointInfo = endpointInfo
        frame.v1.connectionRequest.mediums = [.wifiLan]
        return frame
    }

    static func connectionResponse(options: ProtocolOptions) -> OfflineFrame {
        var frame = OfflineFrame()
        frame.version = .v1
        frame.v1.type = .connectionResponse
        frame.v1.connectionResponse.response = .accept
        if options.sendLegacyStatusField { frame.v1.connectionResponse.status = 0 }
        if options.sendOSInfo { frame.v1.connectionResponse.osInfo.type = .apple }
        return frame
    }

    static func keepAlive(ack: Bool) -> OfflineFrame {
        var frame = OfflineFrame()
        frame.version = .v1
        frame.v1.type = .keepAlive
        frame.v1.keepAlive.ack = ack
        return frame
    }

    static func disconnection() -> OfflineFrame {
        var frame = OfflineFrame()
        frame.version = .v1
        frame.v1.type = .disconnection
        frame.v1.disconnection = Location_Nearby_Connections_DisconnectionFrame()
        return frame
    }

    static func upgradeFailure(medium: Location_Nearby_Connections_BandwidthUpgradeNegotiationFrame.UpgradePathInfo.Medium) -> OfflineFrame {
        var frame = OfflineFrame()
        frame.version = .v1
        frame.v1.type = .bandwidthUpgradeNegotiation
        frame.v1.bandwidthUpgradeNegotiation.eventType = .upgradeFailure
        frame.v1.bandwidthUpgradeNegotiation.upgradePathInfo.medium = medium
        return frame
    }

    static func payload(id: Int64, type: PayloadTransferFrame.PayloadHeader.PayloadType, totalSize: Int64,
                        offset: Int64, body: Data, last: Bool) -> OfflineFrame {
        var frame = OfflineFrame()
        frame.version = .v1
        frame.v1.type = .payloadTransfer
        frame.v1.payloadTransfer.packetType = .data
        frame.v1.payloadTransfer.payloadHeader.id = id
        frame.v1.payloadTransfer.payloadHeader.type = type
        frame.v1.payloadTransfer.payloadHeader.totalSize = totalSize
        frame.v1.payloadTransfer.payloadHeader.isSensitive = false
        frame.v1.payloadTransfer.payloadChunk.offset = offset
        frame.v1.payloadTransfer.payloadChunk.flags = last ? 1 : 0
        frame.v1.payloadTransfer.payloadChunk.body = body
        return frame
    }

    static func payloadCanceled(id: Int64) -> OfflineFrame {
        var frame = OfflineFrame()
        frame.version = .v1
        frame.v1.type = .payloadTransfer
        frame.v1.payloadTransfer.packetType = .control
        frame.v1.payloadTransfer.payloadHeader.id = id
        frame.v1.payloadTransfer.controlMessage.event = .payloadCanceled
        return frame
    }
}

/// Builders for Quick Share sharing frames (PROTOCOL_NOTES §7).
enum SharingFrames {
    private static func wrap(_ build: (inout SharingV1Frame) -> Void) -> SharingFrame {
        var frame = SharingFrame()
        frame.version = .v1
        build(&frame.v1)
        return frame
    }

    static func pairedKeyEncryption(qrCodeHandshakeData: Data? = nil) -> SharingFrame {
        wrap {
            $0.type = .pairedKeyEncryption
            $0.pairedKeyEncryption.signedData = secureRandomBytes(72)   // kNearbyShareNumBytesRandomSignature
            $0.pairedKeyEncryption.secretIDHash = secureRandomBytes(6)  // kNearbyShareNumBytesAuthenticationTokenHash
            if let qrCodeHandshakeData { $0.pairedKeyEncryption.qrCodeHandshakeData = qrCodeHandshakeData }
        }
    }

    static func pairedKeyResult() -> SharingFrame {
        wrap {
            $0.type = .pairedKeyResult
            $0.pairedKeyResult.status = .unable
            $0.pairedKeyResult.osType = .macos
        }
    }

    static func response(_ status: Nearby_Sharing_Service_Proto_ConnectionResponseFrame.Status) -> SharingFrame {
        wrap {
            $0.type = .response
            $0.connectionResponse.status = status
        }
    }

    static func cancel() -> SharingFrame {
        wrap { $0.type = .cancel }
    }

    static func introduction(files: [Nearby_Sharing_Service_Proto_FileMetadata],
                             texts: [Nearby_Sharing_Service_Proto_TextMetadata]) -> SharingFrame {
        wrap {
            $0.type = .introduction
            $0.introduction.fileMetadata = files
            $0.introduction.textMetadata = texts
        }
    }
}

extension OfflineFrame {
    /// A short, content-free description for diagnostics.
    var logDescription: String {
        guard hasV1 else { return "OfflineFrame(no v1)" }
        switch v1.type {
        case .payloadTransfer:
            let p = v1.payloadTransfer
            return "PAYLOAD_TRANSFER(\(p.packetType) \(p.payloadHeader.type) total=\(p.payloadHeader.totalSize) "
                + "offset=\(p.payloadChunk.offset) len=\(p.payloadChunk.body.count) flags=\(p.payloadChunk.flags)"
                + (p.hasControlMessage ? " control=\(p.controlMessage.event)" : "") + ")"
        case .keepAlive:
            return "KEEP_ALIVE(ack=\(v1.keepAlive.ack))"
        case .bandwidthUpgradeNegotiation:
            let b = v1.bandwidthUpgradeNegotiation
            return "BANDWIDTH_UPGRADE_NEGOTIATION(\(b.eventType) medium=\(b.upgradePathInfo.medium))"
        case .connectionResponse:
            return "CONNECTION_RESPONSE(\(v1.connectionResponse.response) os=\(v1.connectionResponse.osInfo.type))"
        default:
            return "\(v1.type)"
        }
    }
}

extension SharingFrame {
    var logDescription: String {
        guard hasV1 else { return "SharingFrame(no v1)" }
        switch v1.type {
        case .introduction:
            return "INTRODUCTION(files=\(v1.introduction.fileMetadata.count) texts=\(v1.introduction.textMetadata.count) "
                + "wifi=\(v1.introduction.wifiCredentialsMetadata.count) apps=\(v1.introduction.appMetadata.count) "
                + "streams=\(v1.introduction.streamMetadata.count))"
        case .response:
            return "RESPONSE(\(v1.connectionResponse.status))"
        case .pairedKeyResult:
            return "PAIRED_KEY_RESULT(\(v1.pairedKeyResult.status) os=\(v1.pairedKeyResult.osType))"
        default:
            return "\(v1.type)"
        }
    }
}
