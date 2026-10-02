import CryptoKit
import Foundation
import XCTest
@testable import QuickShareCore

final class FramingTests: XCTestCase {
    func testLengthPrefixIsBigEndian() {
        XCTAssertEqual(Framing.encode(Data([0xAA])), Data([0, 0, 0, 1, 0xAA]))
        XCTAssertEqual(Framing.encode(Data(count: 0x010203)).prefix(4), Data([0, 0x01, 0x02, 0x03]))
        XCTAssertEqual(Framing.decodeLength(Data([0x12, 0x34, 0x56, 0x78])), 0x12345678)
    }

    func testFramesRoundTripThroughStream() async throws {
        let (a, b) = MemoryByteStream.pair()
        let payloads = [Data(), Data("one".utf8), secureRandomBytes(70_000)]
        for payload in payloads { try await a.writeFrame(payload) }
        for payload in payloads {
            let frame = try await b.readFrame()
            XCTAssertEqual(frame, payload)
        }
    }

    func testSplitDeliveryIsReassembled() async throws {
        let (_, b) = MemoryByteStream.pair()
        let wire = Framing.encode(Data("split across deliveries".utf8))
        Task {
            for byte in wire {
                b.receive(Data([byte]))
                try? await Task.sleep(nanoseconds: 100_000)
            }
        }
        let frame = try await b.readFrame()
        XCTAssertEqual(String(decoding: frame, as: UTF8.self), "split across deliveries")
    }

    func testOversizedFrameIsRejectedBeforeAllocation() async {
        let (_, b) = MemoryByteStream.pair()
        b.receive(Data([0x7F, 0xFF, 0xFF, 0xFF]))
        do {
            _ = try await b.readFrame()
            XCTFail("expected frameTooLarge")
        } catch {
            XCTAssertEqual(error as? TransportError, .frameTooLarge(0x7FFF_FFFF))
        }
    }

    func testTruncatedFrameFailsWhenClosed() async {
        let (a, b) = MemoryByteStream.pair()
        b.receive(Data([0, 0, 0, 10, 1, 2, 3]))
        a.close()
        do {
            _ = try await b.readFrame()
            XCTFail("expected closed")
        } catch {
            XCTAssertEqual(error as? TransportError, .closed)
        }
    }

    func testTimeoutClosesBlockedRead() async {
        let (_, b) = MemoryByteStream.pair()
        let start = Date()
        do {
            _ = try await withTimeout(0.2, stage: "test", onTimeout: { b.close() }) { try await b.readFrame() }
            XCTFail("expected timeout")
        } catch {
            XCTAssertEqual(error as? TransportError, .timedOut("test"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testBytesPayloadAssembler() throws {
        var assembler = BytesPayloadAssembler()
        let body = Data("hello world".utf8)
        let first = OfflineFrames.payload(id: 7, type: .bytes, totalSize: 11, offset: 0, body: body.prefix(5), last: false)
        let second = OfflineFrames.payload(id: 7, type: .bytes, totalSize: 11, offset: 5, body: body.suffix(6), last: false)
        let last = OfflineFrames.payload(id: 7, type: .bytes, totalSize: 11, offset: 11, body: Data(), last: true)
        XCTAssertNil(try assembler.add(first.v1.payloadTransfer))
        XCTAssertNil(try assembler.add(second.v1.payloadTransfer))
        let result = try assembler.add(last.v1.payloadTransfer)
        XCTAssertEqual(result?.id, 7)
        XCTAssertEqual(result?.data, body)

        var strict = BytesPayloadAssembler()
        let tooBig = OfflineFrames.payload(id: 1, type: .bytes, totalSize: Int64(Limits.maxBytesPayload + 1), offset: 0, body: Data(), last: false)
        XCTAssertThrowsError(try strict.add(tooBig.v1.payloadTransfer))
        let gap = OfflineFrames.payload(id: 2, type: .bytes, totalSize: 10, offset: 3, body: Data([1]), last: false)
        XCTAssertThrowsError(try strict.add(gap.v1.payloadTransfer))
        let short = OfflineFrames.payload(id: 3, type: .bytes, totalSize: 10, offset: 0, body: Data([1]), last: true)
        XCTAssertThrowsError(try strict.add(short.v1.payloadTransfer))
    }
}

final class EndpointInfoTests: XCTestCase {
    func testRoundTrip() throws {
        let info = EndpointInfo(name: "Mukesh's MacBook", deviceType: .laptop, version: 1)
        let bytes = info.serialize()
        XCTAssertEqual(bytes[0], (1 << 5) | (3 << 1))
        XCTAssertEqual(bytes[17], UInt8("Mukesh's MacBook".utf8.count))
        let parsed = try EndpointInfo(parsing: bytes)
        XCTAssertEqual(parsed.name, "Mukesh's MacBook")
        XCTAssertEqual(parsed.deviceType, .laptop)
        XCTAssertEqual(parsed.version, 1)
        XCTAssertFalse(parsed.isHidden)
    }

    func testDeviceTypeUsesThreeBits() throws {
        for type in DeviceType.allCases {
            let parsed = try EndpointInfo(parsing: EndpointInfo(name: "x", deviceType: type).serialize())
            XCTAssertEqual(parsed.deviceType, type)
        }
    }

    func testHiddenAndTLVs() throws {
        let token = secureRandomBytes(16)
        let info = EndpointInfo(name: nil, deviceType: .phone, qrCodeData: token, vendorID: 1)
        let bytes = info.serialize()
        XCTAssertEqual(bytes[0] & 0x10, 0x10)
        let parsed = try EndpointInfo(parsing: bytes)
        XCTAssertNil(parsed.name)
        XCTAssertEqual(parsed.qrCodeData, token)
        XCTAssertEqual(parsed.vendorID, 1)
    }

    func testUnknownAndTruncatedTLVsAreTolerated() throws {
        var bytes = EndpointInfo(name: "Pixel", deviceType: .phone).serialize()
        bytes.append(contentsOf: [9, 2, 0xAA, 0xBB])   // unknown TLV
        bytes.append(contentsOf: [1, 50, 0x01])         // truncated QR TLV
        let parsed = try EndpointInfo(parsing: bytes)
        XCTAssertEqual(parsed.name, "Pixel")
        XCTAssertNil(parsed.qrCodeData)
    }

    func testMalformedInputThrows() {
        XCTAssertThrowsError(try EndpointInfo(parsing: Data(count: 5)))
        var bytes = Data(count: 17)
        bytes.append(200)   // name length past the end
        XCTAssertThrowsError(try EndpointInfo(parsing: bytes))
    }

    func testLongNamesAreTruncatedToFitLimit() {
        let info = EndpointInfo(name: String(repeating: "é", count: 200), deviceType: .laptop)
        XCTAssertLessThanOrEqual(info.serialize().count, EndpointInfo.maxLength)
    }

    func testServiceName() {
        let name = ServiceName.make(endpointID: "AB12", extraBytes: true)
        let raw = Base64URL.decode(name)!
        XCTAssertEqual([UInt8](raw), [0x23, 0x41, 0x42, 0x31, 0x32, 0xFC, 0x9F, 0x5E, 0, 0])
        XCTAssertFalse(name.contains("="))
        XCTAssertEqual(ServiceName.parseEndpointID(name), "AB12")
        XCTAssertEqual(ServiceName.parseEndpointID(ServiceName.make(endpointID: "ZZ99", extraBytes: false)), "ZZ99")
        XCTAssertNil(ServiceName.parseEndpointID("not base64 !!"))
        XCTAssertNil(ServiceName.parseEndpointID(Base64URL.encode(Data([0x23, 1, 2, 3, 4, 0, 0, 0]))))
    }

    func testBase64URL() {
        for size in 0..<20 {
            let data = secureRandomBytes(size)
            XCTAssertEqual(Base64URL.decode(Base64URL.encode(data)), data)
        }
        XCTAssertEqual(Base64URL.decode("-_8"), Data([0xFB, 0xFF]))
        XCTAssertEqual(Base64URL.decode("-_8="), Data([0xFB, 0xFF]))
    }
}

final class QRCodeTests: XCTestCase {
    func testURLAndKeyFormat() throws {
        for _ in 0..<20 { XCTAssertEqual(QRCodeSession().keyData[2], 0x02) }
        let session = QRCodeSession()
        XCTAssertTrue(session.url.absoluteString.hasPrefix("https://quickshare.google/qrcode#key="))
        XCTAssertEqual(session.keyData.count, 35)
        XCTAssertEqual(Array(session.keyData.prefix(2)), [0, 0])
        XCTAssertEqual(session.keyData[2], 0x02, "QR keys always use an even-Y point (prefix 0x02)")
        let encoded = String(session.url.absoluteString.split(separator: "=", maxSplits: 1)[1])
        XCTAssertEqual(Base64URL.decode(encoded), session.keyData)
        XCTAssertEqual(session.advertisingToken.count, 16)
    }

    func testVisibleDeviceMatchesByToken() {
        let session = QRCodeSession()
        let info = EndpointInfo(name: "Redmi Note", deviceType: .phone, qrCodeData: session.advertisingToken)
        XCTAssertEqual(session.match(info), .some("Redmi Note"))
        XCTAssertTrue(QRCodeSession().match(info) == nil)
        XCTAssertTrue(session.match(EndpointInfo(name: "Other", deviceType: .phone)) == nil)
    }

    func testHiddenDeviceNameIsDecrypted() throws {
        let session = QRCodeSession()
        let sealed = try AES.GCM.seal(Data("Hidden Phone".utf8), using: session.nameKey, authenticating: session.advertisingToken)
        let tlv = sealed.nonce.withUnsafeBytes { Data($0) } + sealed.ciphertext + sealed.tag
        let info = EndpointInfo(name: nil, deviceType: .phone, qrCodeData: tlv)
        XCTAssertEqual(session.match(info), .some("Hidden Phone"))
    }

    func testHandshakeSignatureVerifies() throws {
        let session = QRCodeSession()
        let auth = secureRandomBytes(32)
        let signature = try session.handshakeSignature(authString: auth)
        XCTAssertEqual(signature.count, 64)
        let parsed = try P256.Signing.ECDSASignature(rawRepresentation: signature)
        XCTAssertTrue(session.signingKey.publicKey.isValidSignature(parsed, for: auth))
    }
}
