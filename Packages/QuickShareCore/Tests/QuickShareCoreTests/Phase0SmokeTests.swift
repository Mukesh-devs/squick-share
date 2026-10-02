import CryptoKit
import Foundation
import SwiftProtobuf
import XCTest
@testable import QuickShareCore

/// Phase 0: the generated protobuf types compile and round-trip, and the derived
/// constants recorded in docs/PROTOCOL_NOTES.md match their stated derivations.
final class Phase0SmokeTests: XCTestCase {
    func testOfflineFrameRoundTrip() throws {
        var frame = Location_Nearby_Connections_OfflineFrame()
        frame.version = .v1
        frame.v1.type = .connectionRequest
        frame.v1.connectionRequest.endpointID = "ABCD"
        frame.v1.connectionRequest.mediums = [.wifiLan]

        let decoded = try Location_Nearby_Connections_OfflineFrame(serializedBytes: try frame.serializedBytes() as [UInt8])
        XCTAssertEqual(decoded, frame)
    }

    func testSharingFrameRoundTrip() throws {
        var file = Nearby_Sharing_Service_Proto_FileMetadata()
        file.name = "photo.jpg"
        file.size = 1234
        file.payloadID = 42
        var frame = Nearby_Sharing_Service_Proto_Frame()
        frame.version = .v1
        frame.v1.type = .introduction
        frame.v1.introduction.fileMetadata = [file]

        let decoded = try Nearby_Sharing_Service_Proto_Frame(serializedBytes: try frame.serializedBytes() as [UInt8])
        XCTAssertEqual(decoded.v1.introduction.fileMetadata.first?.name, "photo.jpg")
    }

    func testUkey2MessageRoundTrip() throws {
        var initMsg = Securegcm_Ukey2ClientInit()
        initMsg.version = 1
        initMsg.random = Data(repeating: 7, count: 32)
        initMsg.nextProtocol = "AES_256_CBC-HMAC_SHA256"
        var commitment = Securegcm_Ukey2ClientInit.CipherCommitment()
        commitment.handshakeCipher = .p256Sha512
        initMsg.cipherCommitments = [commitment]

        var message = Securegcm_Ukey2Message()
        message.messageType = .clientInit
        message.messageData = try initMsg.serializedBytes()

        let decoded = try Securegcm_Ukey2Message(serializedBytes: try message.serializedBytes() as [UInt8])
        let decodedInit = try Securegcm_Ukey2ClientInit(serializedBytes: decoded.messageData)
        XCTAssertEqual(decodedInit.cipherCommitments.first?.handshakeCipher, .p256Sha512)
    }

    /// PROTOCOL_NOTES §2.1: service type = "_" + upper-hex(SHA256("NearbySharing")[0..<6]) + "._tcp".
    func testServiceTypeDerivation() {
        let hash = Array(SHA256.hash(data: Data("NearbySharing".utf8)))
        let hex = hash.prefix(6).map { String(format: "%02X", $0) }.joined()
        XCTAssertEqual("_\(hex)._tcp", "_FC9F5ED42C8A._tcp")
        XCTAssertEqual(Array(hash.prefix(3)), [0xFC, 0x9F, 0x5E])
    }

    /// PROTOCOL_NOTES §4.3: the D2D and SecureMessage HKDF salts are SHA-256 digests of fixed labels.
    func testSecureChannelSaltDerivations() {
        func hex(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).map { String(format: "%02X", $0) }.joined() }
        XCTAssertEqual(hex("D2D"), "82AA55A0D397F88346CA1CEE8D3909B95F13FA7DEB1D4AB38376B8256DA85510")
        XCTAssertEqual(hex("SecureMessage"), "BF9D2A53C63616D75DB0A7165B91C1EF73E537F2427405FA23610A4BE657642E")
    }
}
