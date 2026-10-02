import CommonCrypto
import CryptoKit
import Foundation
import SwiftProtobuf

enum SecureChannelError: Error, Equatable, CustomStringConvertible {
    case malformed(String)
    case badSignature
    case unsupportedScheme
    case decryptionFailed
    case sequenceMismatch(expected: Int32, got: Int32)
    case sequenceExhausted

    var description: String {
        switch self {
        case .malformed(let what): "secure message: malformed \(what)"
        case .badSignature: "secure message: bad HMAC"
        case .unsupportedScheme: "secure message: unsupported encryption or signature scheme"
        case .decryptionFailed: "secure message: decryption failed"
        case .sequenceMismatch(let expected, let got): "secure message: sequence \(got), expected \(expected)"
        case .sequenceExhausted: "secure message: sequence number exhausted"
        }
    }
}

/// D2D SecureMessage channel (PROTOCOL_NOTES §5): AES-256-CBC + HMAC-SHA256 with strict sequence numbers.
struct SecureChannel {
    private let keys: SecureChannelKeys
    private var sendSequence: Int32 = 0
    private var receiveSequence: Int32 = 0

    init(keys: SecureChannelKeys) {
        self.keys = keys
    }

    /// Wraps `plaintext` (a serialized OfflineFrame) into a serialized SecureMessage.
    /// `iv` is only for deterministic tests.
    mutating func seal(_ plaintext: Data, iv fixedIV: Data? = nil) throws -> Data {
        guard sendSequence < Int32.max else { throw SecureChannelError.sequenceExhausted }
        sendSequence += 1

        var d2d = Securegcm_DeviceToDeviceMessage()
        d2d.sequenceNumber = sendSequence
        d2d.message = plaintext

        let iv = fixedIV ?? secureRandomBytes(kCCBlockSizeAES128)
        let body = try AESCBC.crypt(encrypt: true, key: keys.encryptKey, iv: iv, input: try d2d.serializedBytes())

        var metadata = Securegcm_GcmMetadata()
        metadata.type = .deviceToDeviceMessage
        metadata.version = 1

        var header = Securemessage_Header()
        header.signatureScheme = .hmacSha256
        header.encryptionScheme = .aes256Cbc
        header.iv = iv
        header.publicMetadata = try metadata.serializedBytes()

        var headerAndBody = Securemessage_HeaderAndBody()
        headerAndBody.header = header
        headerAndBody.body = body
        let headerAndBodyBytes: Data = try headerAndBody.serializedBytes()

        var message = Securemessage_SecureMessage()
        message.headerAndBody = headerAndBodyBytes
        message.signature = Data(HMAC<SHA256>.authenticationCode(for: headerAndBodyBytes, using: keys.sendHmacKey))
        return try message.serializedBytes()
    }

    /// Verifies and decrypts a serialized SecureMessage, returning the inner payload (a serialized OfflineFrame).
    mutating func open(_ raw: Data) throws -> Data {
        guard let message = try? Securemessage_SecureMessage(serializedBytes: raw),
              message.hasHeaderAndBody, message.hasSignature
        else { throw SecureChannelError.malformed("SecureMessage") }

        // Authenticate before parsing or decrypting anything else (constant-time compare).
        guard HMAC<SHA256>.isValidAuthenticationCode(
            message.signature, authenticating: message.headerAndBody, using: keys.receiveHmacKey
        ) else { throw SecureChannelError.badSignature }

        guard let headerAndBody = try? Securemessage_HeaderAndBody(serializedBytes: message.headerAndBody) else {
            throw SecureChannelError.malformed("HeaderAndBody")
        }
        let header = headerAndBody.header
        guard header.encryptionScheme == .aes256Cbc, header.signatureScheme == .hmacSha256 else {
            throw SecureChannelError.unsupportedScheme
        }
        guard header.iv.count == kCCBlockSizeAES128 else { throw SecureChannelError.malformed("IV") }
        if header.hasPublicMetadata {
            guard let metadata = try? Securegcm_GcmMetadata(serializedBytes: header.publicMetadata),
                  metadata.type == .deviceToDeviceMessage, metadata.version <= 1
            else { throw SecureChannelError.malformed("GcmMetadata") }
        }

        let plaintext = try AESCBC.crypt(encrypt: false, key: keys.decryptKey, iv: header.iv, input: headerAndBody.body)
        guard let d2d = try? Securegcm_DeviceToDeviceMessage(serializedBytes: plaintext),
              d2d.hasSequenceNumber, d2d.hasMessage
        else { throw SecureChannelError.malformed("DeviceToDeviceMessage") }

        guard receiveSequence < Int32.max else { throw SecureChannelError.sequenceExhausted }
        let expected = receiveSequence + 1
        guard d2d.sequenceNumber == expected else {
            throw SecureChannelError.sequenceMismatch(expected: expected, got: d2d.sequenceNumber)
        }
        receiveSequence = expected
        return d2d.message
    }
}

/// AES-256-CBC with PKCS#7 padding. CryptoKit has no CBC mode, so this uses CommonCrypto (a system framework).
enum AESCBC {
    static func crypt(encrypt: Bool, key: SymmetricKey, iv: Data, input: Data) throws -> Data {
        guard key.bitCount == 256, iv.count == kCCBlockSizeAES128 else {
            throw encrypt ? SecureChannelError.unsupportedScheme : SecureChannelError.decryptionFailed
        }
        if !encrypt, input.isEmpty || input.count % kCCBlockSizeAES128 != 0 {
            throw SecureChannelError.decryptionFailed
        }
        var output = Data(count: input.count + kCCBlockSizeAES128)
        var moved = 0
        let status = output.withUnsafeMutableBytes { out in
            input.withUnsafeBytes { inp in
                iv.withUnsafeBytes { ivp in
                    key.withUnsafeBytes { kp in
                        CCCrypt(
                            CCOperation(encrypt ? kCCEncrypt : kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            kp.baseAddress, kp.count,
                            ivp.baseAddress,
                            inp.baseAddress, inp.count,
                            out.baseAddress, out.count,
                            &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw encrypt ? SecureChannelError.unsupportedScheme : SecureChannelError.decryptionFailed
        }
        output.count = moved
        return output
    }
}
