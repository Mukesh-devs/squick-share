import CryptoKit
import Foundation

/// QR-code pairing for sending to phones that are not discoverable (PROTOCOL_NOTES §9, VERIFY V15).
///
/// The Mac shows `url` as a QR code. The phone scans it and starts advertising with a QR TLV in its
/// EndpointInfo: the advertising token (visible phone) or its name encrypted with `nameKey` (hidden phone).
/// The sender then signs the UKEY2 auth string so the phone can skip its accept prompt.
public struct QRCodeSession: Sendable {
    public let url: URL
    let signingKey: P256.Signing.PrivateKey
    let keyData: Data
    let advertisingToken: Data
    let nameKey: SymmetricKey

    public init() {
        // The byte after the 2-byte version is the SEC1 prefix (0x02 even Y, 0x03 odd Y). NearDrop, the
        // reference that works with Android, always writes 0x02. Picking a key whose Y is even makes
        // both readings agree, so the phone reconstructs the right key either way (PROTOCOL_NOTES §9).
        var key = P256.Signing.PrivateKey()
        while key.publicKey.compressedRepresentation.first != 0x02 { key = P256.Signing.PrivateKey() }
        self.init(signingKey: key)
    }

    init(signingKey: P256.Signing.PrivateKey) {
        self.signingKey = signingKey
        // 2-byte version (0) + compressed SEC1 point (0x02/0x03 prefix + X).
        keyData = Data([0, 0]) + signingKey.publicKey.compressedRepresentation
        advertisingToken = KeyDerivation.hkdf(ikm: keyData, salt: Data(), info: Data("advertisingContext".utf8), length: 16)
        nameKey = SymmetricKey(data: KeyDerivation.hkdf(ikm: keyData, salt: Data(), info: Data("encryptionKey".utf8), length: 16))
        url = URL(string: "https://quickshare.google/qrcode#key=\(Base64URL.encode(keyData))")!
    }

    /// Whether a discovered EndpointInfo answers this QR code. Returns the device name
    /// (decrypted if the device is hidden), or nil when it does not match.
    func match(_ info: EndpointInfo) -> String?? {
        guard let tlv = info.qrCodeData else { return nil }
        if tlv == advertisingToken { return .some(info.name) }
        // Hidden device: 12-byte nonce || ciphertext || 16-byte tag, AAD = advertising token.
        guard tlv.count > 28,
              let nonce = try? AES.GCM.Nonce(data: tlv.prefix(12)),
              let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: tlv.dropFirst(12).dropLast(16), tag: tlv.suffix(16)),
              let plaintext = try? AES.GCM.open(box, using: nameKey, authenticating: advertisingToken)
        else { return nil }
        return .some(String(decoding: plaintext, as: UTF8.self))
    }

    /// `PairedKeyEncryptionFrame.qr_code_handshake_data`: ECDSA-P256 over the UKEY2 auth string, IEEE P1363 (r||s).
    func handshakeSignature(authString: Data) throws -> Data {
        try signingKey.signature(for: authString).rawRepresentation
    }
}
