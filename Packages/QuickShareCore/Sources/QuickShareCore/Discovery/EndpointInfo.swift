import Foundation

/// EndpointInfo: the TXT `n` record value and `ConnectionRequestFrame.endpoint_info` (PROTOCOL_NOTES §2.4).
struct EndpointInfo: Equatable, Sendable {
    static let maxLength = 131           // kMaxEndpointInfoLength
    static let fixedPrefixLength = 17    // flags(1) + salt(2) + encrypted metadata key(14)
    static let maxNameBytes = maxLength - fixedPrefixLength - 1

    enum TLVType: UInt8 {
        case qrCode = 1
        case vendorID = 2
        case capabilities = 3
    }

    var version: UInt8
    var deviceType: DeviceType
    /// nil when the device is hidden (visibility bit set).
    var name: String?
    /// 16 bytes. Random for us; only meaningful with Google-account certificates.
    var metadata: Data
    var qrCodeData: Data?
    var vendorID: UInt8?

    init(name: String?, deviceType: DeviceType, version: UInt8 = 0,
         metadata: Data = secureRandomBytes(16), qrCodeData: Data? = nil, vendorID: UInt8? = nil) {
        self.version = version
        self.deviceType = deviceType
        self.name = name.map { Self.truncateUTF8($0, maxBytes: Self.maxNameBytes) }
        self.metadata = metadata
        self.qrCodeData = qrCodeData
        self.vendorID = vendorID
    }

    var isHidden: Bool { name == nil }

    func serialize() -> Data {
        var out = Data()
        let flags = ((version & 0b111) << 5) | ((isHidden ? 1 : 0) << 4) | ((UInt8(deviceType.rawValue) & 0b111) << 1)
        out.append(flags)
        out.append(metadata.prefix(16))
        if metadata.count < 16 { out.append(Data(count: 16 - metadata.count)) }
        if let name {
            let bytes = Data(name.utf8)
            out.append(UInt8(bytes.count))
            out.append(bytes)
        }
        if let qrCodeData, qrCodeData.count <= 255 {
            out.append(TLVType.qrCode.rawValue)
            out.append(UInt8(qrCodeData.count))
            out.append(qrCodeData)
        }
        if let vendorID {
            out.append(contentsOf: [TLVType.vendorID.rawValue, 1, vendorID])
        }
        return out
    }

    enum ParseError: Error { case tooShort, tooLong, badName }

    init(parsing data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= Self.fixedPrefixLength else { throw ParseError.tooShort }
        guard bytes.count <= 255 + Self.fixedPrefixLength + 1 + 2 * 257 else { throw ParseError.tooLong }
        let flags = bytes[0]
        version = (flags >> 5) & 0b111
        let hidden = (flags >> 4) & 1 == 1
        deviceType = DeviceType(rawValue: Int((flags >> 1) & 0b111)) ?? .unknown
        metadata = Data(bytes[1..<17])
        var index = Self.fixedPrefixLength
        if hidden {
            name = nil
        } else {
            guard index < bytes.count else { throw ParseError.badName }
            let length = Int(bytes[index])
            index += 1
            guard index + length <= bytes.count else { throw ParseError.badName }
            name = String(decoding: bytes[index..<index + length], as: UTF8.self)
            index += length
        }
        qrCodeData = nil
        vendorID = nil
        // TLVs. Unknown types are skipped; a truncated tail is ignored.
        while index + 2 <= bytes.count {
            let type = bytes[index]
            let length = Int(bytes[index + 1])
            index += 2
            guard index + length <= bytes.count else { break }
            let value = Data(bytes[index..<index + length])
            index += length
            switch TLVType(rawValue: type) {
            case .qrCode: qrCodeData = value
            case .vendorID: vendorID = value.first
            default: break
            }
        }
    }

    static func truncateUTF8(_ string: String, maxBytes: Int) -> String {
        if string.utf8.count <= maxBytes { return string }
        var result = ""
        for character in string {
            if result.utf8.count + String(character).utf8.count > maxBytes { break }
            result.append(character)
        }
        return result
    }
}

/// The mDNS service type and instance name (PROTOCOL_NOTES §2.1–2.2).
enum ServiceName {
    static let serviceType = "_FC9F5ED42C8A._tcp"
    static let serviceIDHash: [UInt8] = [0xFC, 0x9F, 0x5E]
    /// version 1 << 5 | PCP 3 (P2P point-to-point)
    static let pcpByte: UInt8 = 0x23

    static func make(endpointID: String, extraBytes: Bool) -> String {
        var bytes = Data([pcpByte])
        bytes.append(Data(endpointID.utf8.prefix(4)))
        bytes.append(contentsOf: serviceIDHash)
        if extraBytes { bytes.append(contentsOf: [0, 0]) }
        return Base64URL.encode(bytes)
    }

    /// Returns the endpoint ID if `name` is a Quick Share instance name.
    static func parseEndpointID(_ name: String) -> String? {
        guard let bytes = Base64URL.decode(name).map([UInt8].init), bytes.count >= 8 else { return nil }
        guard (bytes[0] >> 5) == 1, Array(bytes[5..<8]) == serviceIDHash else { return nil }
        return String(decoding: bytes[1..<5], as: UTF8.self)
    }

    static func randomEndpointID() -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        var generator = SystemRandomNumberGenerator()
        return String((0..<4).map { _ in alphabet.randomElement(using: &generator)! })
    }
}

enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ string: String) -> Data? {
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 = base64.replacingOccurrences(of: "=", with: "")
        let remainder = base64.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: base64)
    }
}
