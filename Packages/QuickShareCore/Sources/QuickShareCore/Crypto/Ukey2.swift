import CryptoKit
import Foundation
import SwiftProtobuf

/// UKEY2 handshake (PROTOCOL_NOTES §4.4), cipher P256_SHA512 only.
enum Ukey2 {
    static let version: Int32 = 1
    static let randomLength = 32
    static let nextProtocol = "AES_256_CBC-HMAC_SHA256"
}

enum Ukey2Error: Error, Equatable, CustomStringConvertible {
    case badMessage
    case badMessageType
    case badVersion
    case badRandom
    case badHandshakeCipher
    case badNextProtocol
    case badPublicKey
    case commitmentMismatch
    case peerAlert(String)

    var description: String {
        switch self {
        case .badMessage: "UKEY2: malformed message"
        case .badMessageType: "UKEY2: unexpected message type"
        case .badVersion: "UKEY2: unsupported version"
        case .badRandom: "UKEY2: random field must be 32 bytes"
        case .badHandshakeCipher: "UKEY2: no supported handshake cipher"
        case .badNextProtocol: "UKEY2: unsupported next protocol"
        case .badPublicKey: "UKEY2: invalid public key"
        case .commitmentMismatch: "UKEY2: ClientFinished does not match commitment"
        case .peerAlert(let type): "UKEY2: peer sent alert \(type)"
        }
    }

    /// The alert a server sends for this error, if any (the spec sends none for ClientFinished errors).
    var alertType: Securegcm_Ukey2Alert.AlertType? {
        switch self {
        case .badMessage: .badMessage
        case .badMessageType: .badMessageType
        case .badVersion: .badVersion
        case .badRandom: .badRandom
        case .badHandshakeCipher: .badHandshakeCipher
        case .badNextProtocol: .badNextProtocol
        case .badPublicKey: .badPublicKey
        case .commitmentMismatch, .peerAlert: nil
        }
    }
}

/// Encodes P-256 public keys as `GenericPublicKey`. Coordinates use Java's
/// `BigInteger.toByteArray()` form: minimal signed big-endian two's complement.
enum P256KeyCoding {
    static func encode(_ key: P256.KeyAgreement.PublicKey) -> Securemessage_GenericPublicKey {
        let x963 = key.x963Representation   // 0x04 || X(32) || Y(32)
        var ec = Securemessage_EcP256PublicKey()
        ec.x = javaBigIntegerBytes(x963[1..<33])
        ec.y = javaBigIntegerBytes(x963[33..<65])
        var generic = Securemessage_GenericPublicKey()
        generic.type = .ecP256
        generic.ecP256PublicKey = ec
        return generic
    }

    static func decode(_ generic: Securemessage_GenericPublicKey) throws -> P256.KeyAgreement.PublicKey {
        guard generic.type == .ecP256, generic.hasEcP256PublicKey else { throw Ukey2Error.badPublicKey }
        let x = try coordinate(generic.ecP256PublicKey.x)
        let y = try coordinate(generic.ecP256PublicKey.y)
        do {
            return try P256.KeyAgreement.PublicKey(x963Representation: Data([0x04]) + x + y)
        } catch {
            throw Ukey2Error.badPublicKey
        }
    }

    static func javaBigIntegerBytes<C: Collection>(_ unsignedBigEndian: C) -> Data where C.Element == UInt8 {
        var bytes = Data(unsignedBigEndian.drop(while: { $0 == 0 }))
        if bytes.isEmpty { return Data([0]) }
        if bytes.first! & 0x80 != 0 { bytes.insert(0, at: 0) }
        return bytes
    }

    /// Accepts the encodings Google's validator accepts (1–33 bytes, 33 only with a leading 0x00,
    /// and non-negative), returning exactly 32 bytes.
    static func coordinate(_ raw: Data) throws -> Data {
        guard !raw.isEmpty, raw.count <= 33 else { throw Ukey2Error.badPublicKey }
        if raw.count == 33, raw.first != 0 { throw Ukey2Error.badPublicKey }
        if raw.first! & 0x80 != 0 { throw Ukey2Error.badPublicKey }  // negative in two's complement
        let magnitude = raw.drop(while: { $0 == 0 })
        guard magnitude.count <= 32 else { throw Ukey2Error.badPublicKey }
        return Data(repeating: 0, count: 32 - magnitude.count) + magnitude
    }
}

private func ukey2Message(_ type: Securegcm_Ukey2Message.TypeEnum, _ data: Data) throws -> Data {
    var message = Securegcm_Ukey2Message()
    message.messageType = type
    message.messageData = data
    return try message.serializedBytes()
}

private func parseUkey2(_ raw: Data, expecting type: Securegcm_Ukey2Message.TypeEnum) throws -> Data {
    let message: Securegcm_Ukey2Message
    do {
        message = try Securegcm_Ukey2Message(serializedBytes: raw)
    } catch {
        throw Ukey2Error.badMessage
    }
    if message.messageType == .alert, type != .alert {
        let alert = try? Securegcm_Ukey2Alert(serializedBytes: message.messageData)
        throw Ukey2Error.peerAlert(alert.map { "\($0.type)" } ?? "unknown")
    }
    guard message.messageType == type else { throw Ukey2Error.badMessageType }
    return message.messageData
}

/// The server (receiver) side of UKEY2.
struct Ukey2Server {
    private let privateKey: P256.KeyAgreement.PrivateKey
    private var clientInitRaw: Data?
    private var serverInitRaw: Data?
    private var commitment: Data?

    init(privateKey: P256.KeyAgreement.PrivateKey = .init()) {
        self.privateKey = privateKey
    }

    /// Validates `ClientInit` (M1) and returns the serialized `ServerInit` (M2).
    mutating func handleClientInit(_ raw: Data) throws -> Data {
        let data = try parseUkey2(raw, expecting: .clientInit)
        guard let clientInit = try? Securegcm_Ukey2ClientInit(serializedBytes: data) else { throw Ukey2Error.badMessage }
        guard clientInit.version == Ukey2.version else { throw Ukey2Error.badVersion }
        guard clientInit.random.count == Ukey2.randomLength else { throw Ukey2Error.badRandom }
        guard let chosen = clientInit.cipherCommitments.first(where: { $0.handshakeCipher == .p256Sha512 }),
              !chosen.commitment.isEmpty
        else { throw Ukey2Error.badHandshakeCipher }
        guard clientInit.nextProtocol == Ukey2.nextProtocol else { throw Ukey2Error.badNextProtocol }

        var serverInit = Securegcm_Ukey2ServerInit()
        serverInit.version = Ukey2.version
        serverInit.random = secureRandomBytes(Ukey2.randomLength)
        serverInit.handshakeCipher = .p256Sha512
        serverInit.publicKey = try P256KeyCoding.encode(privateKey.publicKey).serializedBytes()

        let m2 = try ukey2Message(.serverInit, try serverInit.serializedBytes())
        clientInitRaw = raw
        serverInitRaw = m2
        commitment = chosen.commitment
        return m2
    }

    /// Validates `ClientFinished` (M3) against the commitment and completes the key exchange.
    func handleClientFinish(_ raw: Data) throws -> Ukey2Result {
        guard let clientInitRaw, let serverInitRaw, let commitment else { throw Ukey2Error.badMessageType }
        guard Data(SHA512.hash(data: raw)) == commitment else { throw Ukey2Error.commitmentMismatch }
        let data = try parseUkey2(raw, expecting: .clientFinish)
        guard let finished = try? Securegcm_Ukey2ClientFinished(serializedBytes: data),
              let generic = try? Securemessage_GenericPublicKey(serializedBytes: finished.publicKey)
        else { throw Ukey2Error.badMessage }
        let peerKey = try P256KeyCoding.decode(generic)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peerKey)
        return Ukey2Result(dhs: KeyDerivation.dhs(sharedSecret: shared), clientInit: clientInitRaw, serverInit: serverInitRaw)
    }

    /// A serialized alert for `error`, or nil when the spec says to close silently.
    static func alert(for error: Ukey2Error) -> Data? {
        guard let type = error.alertType else { return nil }
        var alert = Securegcm_Ukey2Alert()
        alert.type = type
        alert.errorMessage = error.description
        return try? ukey2Message(.alert, try alert.serializedBytes())
    }
}

/// The client (sender) side of UKEY2.
struct Ukey2Client {
    private let privateKey: P256.KeyAgreement.PrivateKey
    /// M1, to send first.
    let clientInit: Data
    /// M3, to send after a valid ServerInit. Committed to inside M1.
    let clientFinish: Data

    init(privateKey: P256.KeyAgreement.PrivateKey = .init()) throws {
        self.privateKey = privateKey
        var finished = Securegcm_Ukey2ClientFinished()
        finished.publicKey = try P256KeyCoding.encode(privateKey.publicKey).serializedBytes()
        clientFinish = try ukey2Message(.clientFinish, try finished.serializedBytes())

        var commitment = Securegcm_Ukey2ClientInit.CipherCommitment()
        commitment.handshakeCipher = .p256Sha512
        commitment.commitment = Data(SHA512.hash(data: clientFinish))
        var clientInit = Securegcm_Ukey2ClientInit()
        clientInit.version = Ukey2.version
        clientInit.random = secureRandomBytes(Ukey2.randomLength)
        clientInit.cipherCommitments = [commitment]
        clientInit.nextProtocol = Ukey2.nextProtocol
        self.clientInit = try ukey2Message(.clientInit, try clientInit.serializedBytes())
    }

    /// Validates `ServerInit` (M2) and completes the key exchange. Send `clientFinish` next.
    func handleServerInit(_ raw: Data) throws -> Ukey2Result {
        let data = try parseUkey2(raw, expecting: .serverInit)
        guard let serverInit = try? Securegcm_Ukey2ServerInit(serializedBytes: data) else { throw Ukey2Error.badMessage }
        guard serverInit.version == Ukey2.version else { throw Ukey2Error.badVersion }
        guard serverInit.random.count == Ukey2.randomLength else { throw Ukey2Error.badRandom }
        guard serverInit.handshakeCipher == .p256Sha512 else { throw Ukey2Error.badHandshakeCipher }
        guard let generic = try? Securemessage_GenericPublicKey(serializedBytes: serverInit.publicKey) else {
            throw Ukey2Error.badPublicKey
        }
        let peerKey = try P256KeyCoding.decode(generic)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peerKey)
        return Ukey2Result(dhs: KeyDerivation.dhs(sharedSecret: shared), clientInit: clientInit, serverInit: raw)
    }
}

func secureRandomBytes(_ count: Int) -> Data {
    var generator = SystemRandomNumberGenerator()
    return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
}

func secureRandomInt64() -> Int64 {
    var generator = SystemRandomNumberGenerator()
    return Int64.random(in: .min ... .max, using: &generator)
}
