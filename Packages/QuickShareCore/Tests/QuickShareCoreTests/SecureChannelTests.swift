import CryptoKit
import Foundation
import XCTest
@testable import QuickShareCore

final class SecureChannelTests: XCTestCase {
    let nextSecret = Data(hex: "c063e03fac785297951d48c2eb7501dea4672edc4183a8d8e3670c21d47c25df")

    func pair() -> (client: SecureChannel, server: SecureChannel) {
        (SecureChannel(keys: SecureChannelKeys(nextSecret: nextSecret, role: .client)),
         SecureChannel(keys: SecureChannelKeys(nextSecret: nextSecret, role: .server)))
    }

    func testAESCBCMatchesIndependentVector() throws {
        let key = SymmetricKey(data: Data(hex: "6a03c40e8afcf73763dd2d1c8a39a87e038b3d158c67099582fe68227e464abb"))
        let plaintext = Data("squick-share test vector: AES-256-CBC with PKCS#7 padding".utf8)
        let iv = Data(hex: "000102030405060708090a0b0c0d0e0f")
        let ciphertext = try AESCBC.crypt(encrypt: true, key: key, iv: iv, input: plaintext)
        XCTAssertEqual(ciphertext.hex, "c979620a0a28e79c583ce5dd47437f5508b1ace11f3c62e1d6847099db9707141ed9b8b9e2c6059ff246437e66914fb8cecdb45dcecb18ed28aac48c486622de")
        XCTAssertEqual(try AESCBC.crypt(encrypt: false, key: key, iv: iv, input: ciphertext), plaintext)
        let macKey = SymmetricKey(data: Data(hex: "6ec05ad156fbd3c4b0bfcfda5d10804b0faaa5f5a95f7a3fd63f4a495555efa8"))
        XCTAssertEqual(Data(HMAC<SHA256>.authenticationCode(for: ciphertext, using: macKey)).hex,
                       "ab20ae3953bcce2760394185c5853b3397ed8fabb43c015d44da99e9c8c06838")
    }

    func testRoundTripBothDirections() throws {
        var (client, server) = pair()
        for size in [0, 1, 15, 16, 17, 1000, 512 * 1024] {
            let message = secureRandomBytes(size)
            XCTAssertEqual(try server.open(try client.seal(message)), message)
            XCTAssertEqual(try client.open(try server.seal(message)), message)
        }
    }

    func testSealedMessageStructure() throws {
        var (client, _) = pair()
        let sealed = try client.seal(Data("hello".utf8), iv: Data(count: 16))
        let message = try Securemessage_SecureMessage(serializedBytes: sealed)
        let headerAndBody = try Securemessage_HeaderAndBody(serializedBytes: message.headerAndBody)
        XCTAssertEqual(headerAndBody.header.encryptionScheme, .aes256Cbc)
        XCTAssertEqual(headerAndBody.header.signatureScheme, .hmacSha256)
        XCTAssertEqual(headerAndBody.header.iv, Data(count: 16))
        let metadata = try Securegcm_GcmMetadata(serializedBytes: headerAndBody.header.publicMetadata)
        XCTAssertEqual(metadata.type, .deviceToDeviceMessage)
        XCTAssertEqual(metadata.version, 1)
        XCTAssertEqual(message.signature.count, 32)
    }

    func testFirstSequenceNumberIsOne() throws {
        var (client, _) = pair()
        let sealed = try client.seal(Data("x".utf8))
        let keys = SecureChannelKeys(nextSecret: nextSecret, role: .server)
        let message = try Securemessage_SecureMessage(serializedBytes: sealed)
        let headerAndBody = try Securemessage_HeaderAndBody(serializedBytes: message.headerAndBody)
        let plain = try AESCBC.crypt(encrypt: false, key: keys.decryptKey, iv: headerAndBody.header.iv, input: headerAndBody.body)
        XCTAssertEqual(try Securegcm_DeviceToDeviceMessage(serializedBytes: plain).sequenceNumber, 1)
    }

    func testTamperedMessageIsRejected() throws {
        var (client, server) = pair()
        var sealed = try client.seal(Data("payload".utf8))
        sealed[sealed.count / 2] ^= 0x01
        XCTAssertThrowsError(try server.open(sealed))
    }

    func testBadSignatureIsRejectedBeforeDecrypting() throws {
        var (client, server) = pair()
        let sealed = try client.seal(Data("payload".utf8))
        var message = try Securemessage_SecureMessage(serializedBytes: sealed)
        message.signature[0] ^= 0xFF
        XCTAssertThrowsError(try server.open(try message.serializedBytes())) {
            XCTAssertEqual($0 as? SecureChannelError, .badSignature)
        }
    }

    func testReplayAndReorderAreRejected() throws {
        var (client, server) = pair()
        let first = try client.seal(Data("1".utf8))
        let second = try client.seal(Data("2".utf8))
        XCTAssertThrowsError(try server.open(second)) {
            XCTAssertEqual($0 as? SecureChannelError, .sequenceMismatch(expected: 1, got: 2))
        }
        // A failed open must not advance the counter.
        XCTAssertEqual(try server.open(first), Data("1".utf8))
        XCTAssertThrowsError(try server.open(first)) {
            XCTAssertEqual($0 as? SecureChannelError, .sequenceMismatch(expected: 2, got: 1))
        }
        XCTAssertEqual(try server.open(second), Data("2".utf8))
    }

    func testWrongDirectionKeysAreRejected() throws {
        var (client, _) = pair()
        var otherClient = SecureChannel(keys: SecureChannelKeys(nextSecret: nextSecret, role: .client))
        XCTAssertThrowsError(try otherClient.open(try client.seal(Data("x".utf8)))) {
            XCTAssertEqual($0 as? SecureChannelError, .badSignature)
        }
    }

    func testGarbageIsRejected() {
        var (_, server) = pair()
        for size in [0, 1, 10, 100, 1000] {
            XCTAssertThrowsError(try server.open(secureRandomBytes(size)))
        }
    }
}
