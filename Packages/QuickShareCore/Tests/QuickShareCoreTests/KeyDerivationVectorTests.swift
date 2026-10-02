import CryptoKit
import Foundation
import XCTest
@testable import QuickShareCore

/// Vectors produced by the independent Python implementation in scripts/gen-test-vectors.py.
final class KeyDerivationVectorTests: XCTestCase {
    let clientScalar = Data(hex: "1f2e3d4c5b6a79880102030405060708090a0b0c0d0e0f101112131415161718")
    let serverScalar = Data(hex: "0102030405060708090a0b0c0d0e0f10111213141516171819202122232425ff")
    let m1 = Data(hex: "08021a20000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
    let m2 = Data(hex: "08031a20202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f")

    func testFixedHandshakeDerivation() throws {
        let client = try P256.KeyAgreement.PrivateKey(rawRepresentation: clientScalar)
        let server = try P256.KeyAgreement.PrivateKey(rawRepresentation: serverScalar)
        let shared = try client.sharedSecretFromKeyAgreement(with: server.publicKey)
        XCTAssertEqual(shared.withUnsafeBytes { Data($0) }.hex, "1ec67e0447ad7d2ff956f23640a837e29478d57c5db828494866b56b695007e2")

        let dhs = KeyDerivation.dhs(sharedSecret: shared)
        XCTAssertEqual(dhs.hex, "8846106ee294f36adbb313dff655ad9eec72007fb045f674e50f674d924559ff")

        let result = Ukey2Result(dhs: dhs, clientInit: m1, serverInit: m2)
        XCTAssertEqual(result.authString.hex, "3a4ad39df071da1367436bf7db9182ad8e94320db0326c056ac8077c2d89d097")
        XCTAssertEqual(result.nextSecret.hex, "c063e03fac785297951d48c2eb7501dea4672edc4183a8d8e3670c21d47c25df")
        XCTAssertEqual(result.pin, "4930")

        let server2client = SecureChannelKeys(nextSecret: result.nextSecret, role: .server)
        let client2server = SecureChannelKeys(nextSecret: result.nextSecret, role: .client)
        func hex(_ key: SymmetricKey) -> String { key.withUnsafeBytes { Data($0) }.hex }
        XCTAssertEqual(hex(client2server.encryptKey), "8dc0cbace0468bcaf63dd0712ba5446d3e900bdd84673ea72b870f0c4da4da4b")
        XCTAssertEqual(hex(client2server.sendHmacKey), "60d2d1ed70d7d03d11bd516da72ec6172015c9243e22dc2223d98f700048e57d")
        XCTAssertEqual(hex(server2client.encryptKey), "6a03c40e8afcf73763dd2d1c8a39a87e038b3d158c67099582fe68227e464abb")
        XCTAssertEqual(hex(server2client.sendHmacKey), "6ec05ad156fbd3c4b0bfcfda5d10804b0faaa5f5a95f7a3fd63f4a495555efa8")
        // Each side decrypts with the other's encryption key.
        XCTAssertEqual(hex(client2server.decryptKey), hex(server2client.encryptKey))
        XCTAssertEqual(hex(server2client.receiveHmacKey), hex(client2server.sendHmacKey))
    }

    /// Required: a shared secret that starts with 0x00 must be hashed as the full 32 bytes.
    func testSharedSecretWithLeadingZeroByte() throws {
        let client = try P256.KeyAgreement.PrivateKey(rawRepresentation: clientScalar)
        let server = try P256.KeyAgreement.PrivateKey(
            rawRepresentation: Data(hex: "0102030405060708090a0b0c0d0e0f1011121314151617181920212223242619"))
        let shared = try client.sharedSecretFromKeyAgreement(with: server.publicKey)
        let raw = shared.withUnsafeBytes { Data($0) }
        XCTAssertEqual(raw.count, 32)
        XCTAssertEqual(raw.first, 0x00)
        XCTAssertEqual(raw.hex, "00aa9fe649a3a835993a60cce59eb5e598fea811612134e3d16fde0ebde63d66")

        let dhs = KeyDerivation.dhs(sharedSecret: shared)
        XCTAssertEqual(dhs.hex, "e93cd7ca06dffddb153834918f02c8863bdaa808059bcbf3c17b479c433f8a81")
        XCTAssertNotEqual(dhs.hex, "72cd3c9ce29085528d195b8e3a85ce33370abc637aa86e6a8cbea449ada19096",
                          "must not strip the leading zero (the NearDrop bug)")

        let result = Ukey2Result(dhs: dhs, clientInit: m1, serverInit: m2)
        XCTAssertEqual(result.authString.hex, "542283a46e7dcd2a7ff76d6e9226ccea5359f16cd37f8f9cb9ce758fb80a4e5d")
        XCTAssertEqual(result.pin, "2644")
    }

    /// Full UKEY2 client/server exchange using the leading-zero key pair: both sides must agree.
    func testUkey2HandshakeWithLeadingZeroSecret() throws {
        let clientKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: clientScalar)
        let serverKey = try P256.KeyAgreement.PrivateKey(
            rawRepresentation: Data(hex: "0102030405060708090a0b0c0d0e0f1011121314151617181920212223242619"))
        let client = try Ukey2Client(privateKey: clientKey)
        var server = Ukey2Server(privateKey: serverKey)
        let serverInit = try server.handleClientInit(client.clientInit)
        let clientResult = try client.handleServerInit(serverInit)
        let serverResult = try server.handleClientFinish(client.clientFinish)
        XCTAssertEqual(clientResult.authString, serverResult.authString)
        XCTAssertEqual(clientResult.nextSecret, serverResult.nextSecret)
        XCTAssertEqual(clientResult.pin, serverResult.pin)
    }

    func testRandomHandshakesAgree() throws {
        for _ in 0..<50 {
            let client = try Ukey2Client()
            var server = Ukey2Server()
            let m2 = try server.handleClientInit(client.clientInit)
            let a = try client.handleServerInit(m2)
            let b = try server.handleClientFinish(client.clientFinish)
            XCTAssertEqual(a.nextSecret, b.nextSecret)
            XCTAssertEqual(a.pin, b.pin)
        }
    }

    func testTamperedClientFinishFailsCommitment() throws {
        let client = try Ukey2Client()
        var server = Ukey2Server()
        _ = try server.handleClientInit(client.clientInit)
        let other = try Ukey2Client()
        XCTAssertThrowsError(try server.handleClientFinish(other.clientFinish)) {
            XCTAssertEqual($0 as? Ukey2Error, .commitmentMismatch)
        }
    }

    func testServerRejectsBadClientInit() throws {
        var server = Ukey2Server()
        XCTAssertThrowsError(try server.handleClientInit(Data([0xFF, 0x01]))) { XCTAssertEqual($0 as? Ukey2Error, .badMessage) }

        var initMessage = Securegcm_Ukey2ClientInit()
        initMessage.version = 1
        initMessage.random = Data(count: 31)
        initMessage.nextProtocol = Ukey2.nextProtocol
        var wrapper = Securegcm_Ukey2Message()
        wrapper.messageType = .clientInit
        wrapper.messageData = try initMessage.serializedBytes()
        XCTAssertThrowsError(try server.handleClientInit(try wrapper.serializedBytes())) { XCTAssertEqual($0 as? Ukey2Error, .badRandom) }

        initMessage.random = Data(count: 32)
        wrapper.messageData = try initMessage.serializedBytes()
        XCTAssertThrowsError(try server.handleClientInit(try wrapper.serializedBytes())) {
            XCTAssertEqual($0 as? Ukey2Error, .badHandshakeCipher)
        }
        XCTAssertNotNil(Ukey2Server.alert(for: .badRandom))
        XCTAssertNil(Ukey2Server.alert(for: .commitmentMismatch))
    }

    /// Google's C++ UKEY2 uses "UKEY2 v1 auth\0". HMAC zero-pads short keys, so the PIN is identical.
    func testNulTerminatedAuthSaltIsEquivalent() {
        let dhs = Data(hex: "8846106ee294f36adbb313dff655ad9eec72007fb045f674e50f674d924559ff")
        let plain = KeyDerivation.hkdf(ikm: dhs, salt: Data("UKEY2 v1 auth".utf8), info: m1 + m2)
        let withNul = KeyDerivation.hkdf(ikm: dhs, salt: Data("UKEY2 v1 auth".utf8) + Data([0]), info: m1 + m2)
        XCTAssertEqual(plain, withNul)
    }

    func testPinEdgeCases() {
        XCTAssertEqual(KeyDerivation.pin(authString: Data(repeating: 0xFF, count: 32)), "6509")
        XCTAssertEqual(KeyDerivation.pin(authString: Data(repeating: 0x00, count: 32)), "0000")
        XCTAssertEqual(KeyDerivation.pin(authString: Data(repeating: 0x80, count: 32)), "5393")
        for _ in 0..<200 {
            let pin = KeyDerivation.pin(authString: secureRandomBytes(32))
            XCTAssertEqual(pin.count, 4)
            XCTAssertTrue(pin.allSatisfy(\.isNumber))
        }
    }

    func testPublicKeyCoordinateEncoding() throws {
        // Find keys whose X has the high bit set (needs a 0x00 prefix) and clear (no prefix).
        var sawHighBit = false, sawLowBit = false
        for _ in 0..<64 where !(sawHighBit && sawLowBit) {
            let key = P256.KeyAgreement.PrivateKey().publicKey
            let encoded = P256KeyCoding.encode(key)
            let x = encoded.ecP256PublicKey.x
            let rawX = key.x963Representation[1..<33]
            if rawX.first! & 0x80 != 0 {
                sawHighBit = true
                XCTAssertEqual(x.count, 33)
                XCTAssertEqual(x.first, 0)
            } else if rawX.first! != 0 {
                sawLowBit = true
                XCTAssertEqual(x.count, 32)
            }
            XCTAssertEqual(try P256KeyCoding.decode(encoded).x963Representation, key.x963Representation)
        }
        XCTAssertTrue(sawHighBit && sawLowBit)

        // Short encodings (leading zeros stripped) are accepted; invalid ones are not.
        XCTAssertEqual(try P256KeyCoding.coordinate(Data([0x01, 0x02])), Data(count: 30) + Data([0x01, 0x02]))
        XCTAssertThrowsError(try P256KeyCoding.coordinate(Data()))
        XCTAssertThrowsError(try P256KeyCoding.coordinate(Data([0x01]) + Data(count: 32)))   // 33 bytes, no 0x00
        XCTAssertThrowsError(try P256KeyCoding.coordinate(Data([0x80]) + Data(count: 31)))   // negative
    }
}
