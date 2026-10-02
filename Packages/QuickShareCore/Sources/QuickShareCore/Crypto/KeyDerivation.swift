import CryptoKit
import Foundation

/// HKDF and the fixed labels used by UKEY2 and D2D SecureMessage.
/// See docs/PROTOCOL_NOTES.md §4.5 for the source of every label.
enum KeyDerivation {
    /// Google's C++ UKEY2 passes this salt with a trailing NUL. HMAC zero-pads keys shorter than its
    /// 64-byte block, so both forms derive the same AUTH_STRING (PROTOCOL_NOTES §4.5).
    static let ukey2AuthSalt = Data("UKEY2 v1 auth".utf8)
    static let ukey2NextSalt = Data("UKEY2 v1 next".utf8)
    /// SHA256("D2D")
    static let d2dSalt = Data(SHA256.hash(data: Data("D2D".utf8)))
    /// SHA256("SecureMessage")
    static let secureMessageSalt = Data(SHA256.hash(data: Data("SecureMessage".utf8)))

    static func hkdf(ikm: Data, salt: Data, info: Data, length: Int = 32) -> Data {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: salt,
            info: info,
            outputByteCount: length
        )
        return key.withUnsafeBytes { Data($0) }
    }

    /// DHS = SHA256(ECDH x-coordinate). The coordinate is always the full 32 bytes,
    /// including leading zero bytes, matching Java's `KeyAgreement.generateSecret()`.
    static func dhs(sharedSecret: SharedSecret) -> Data {
        let raw = sharedSecret.withUnsafeBytes { Data($0) }
        precondition(raw.count == 32, "P-256 shared secret must be 32 bytes")
        return Data(SHA256.hash(data: raw))
    }

    /// The 4-digit PIN shown on both devices (PROTOCOL_NOTES §4.6).
    static func pin(authString: Data) -> String {
        var hash = 0
        var multiplier = 1
        for byte in authString {
            hash = (hash + Int(Int8(bitPattern: byte)) * multiplier) % 9973
            multiplier = (multiplier * 31) % 9973
        }
        return String(format: "%04d", abs(hash))
    }
}

/// The output of a completed UKEY2 handshake.
struct Ukey2Result: Sendable {
    /// AUTH_STRING (32 bytes). Input to the PIN and to the QR-code handshake signature.
    let authString: Data
    /// NEXT_SECRET (32 bytes).
    let nextSecret: Data

    init(dhs: Data, clientInit: Data, serverInit: Data) {
        let info = clientInit + serverInit
        authString = KeyDerivation.hkdf(ikm: dhs, salt: KeyDerivation.ukey2AuthSalt, info: info)
        nextSecret = KeyDerivation.hkdf(ikm: dhs, salt: KeyDerivation.ukey2NextSalt, info: info)
    }

    var pin: String { KeyDerivation.pin(authString: authString) }
}

enum HandshakeRole: Sendable {
    case client
    case server
}

/// The four symmetric keys of the D2D secure channel, from one side's point of view.
struct SecureChannelKeys: Sendable {
    let encryptKey: SymmetricKey
    let sendHmacKey: SymmetricKey
    let decryptKey: SymmetricKey
    let receiveHmacKey: SymmetricKey

    init(nextSecret: Data, role: HandshakeRole) {
        let clientD2D = KeyDerivation.hkdf(ikm: nextSecret, salt: KeyDerivation.d2dSalt, info: Data("client".utf8))
        let serverD2D = KeyDerivation.hkdf(ikm: nextSecret, salt: KeyDerivation.d2dSalt, info: Data("server".utf8))
        let ours = role == .client ? clientD2D : serverD2D
        let theirs = role == .client ? serverD2D : clientD2D
        encryptKey = Self.enc(ours)
        sendHmacKey = Self.sig(ours)
        decryptKey = Self.enc(theirs)
        receiveHmacKey = Self.sig(theirs)
    }

    private static func enc(_ d2dKey: Data) -> SymmetricKey {
        SymmetricKey(data: KeyDerivation.hkdf(ikm: d2dKey, salt: KeyDerivation.secureMessageSalt, info: Data("ENC:2".utf8)))
    }

    private static func sig(_ d2dKey: Data) -> SymmetricKey {
        SymmetricKey(data: KeyDerivation.hkdf(ikm: d2dKey, salt: KeyDerivation.secureMessageSalt, info: Data("SIG:1".utf8)))
    }
}
