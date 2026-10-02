import Foundation
import XCTest
@testable import QuickShareCore

/// Feeds malformed and out-of-order input to the receiver. It must close the connection
/// without crashing, never write outside the destination, and leave no files behind.
final class FuzzTests: XCTestCase {
    /// Waits until the inbound session has finished (its stream closed).
    func waitUntilDone(_ session: InboundSession, timeout: TimeInterval = 10) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await session.state == .done { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("session did not close")
    }

    func testRandomBytesBeforeHandshake() async {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let collector = EventCollector()
            let (session, clientEnd, _) = startInbound(collector: collector)
            let length = Int.random(in: 0...64, using: &generator)
            clientEnd.enqueue(secureRandomBytes(length)) { _ in }
            clientEnd.close()
            await waitUntilDone(session)
            XCTAssertNil(collector.request)
        }
    }

    func testRandomFramesBeforeHandshake() async throws {
        for _ in 0..<200 {
            let collector = EventCollector()
            let (session, clientEnd, _) = startInbound(collector: collector)
            // The receiver may close after the first frame, so later writes can fail.
            try? await clientEnd.writeFrame(secureRandomBytes(Int.random(in: 0...300)))
            try? await clientEnd.writeFrame(secureRandomBytes(Int.random(in: 0...300)))
            clientEnd.close()
            await waitUntilDone(session)
        }
    }

    func testMutatedHandshakeMessages() async throws {
        // A valid ConnectionRequest followed by a ClientInit with random byte flips.
        for _ in 0..<150 {
            let collector = EventCollector()
            let (session, clientEnd, _) = startInbound(collector: collector)
            let info = EndpointInfo(name: "Fuzzer", deviceType: .phone).serialize()
            try? await clientEnd.writeFrame(try OfflineFrames.connectionRequest(endpointID: "FUZZ", name: "F", endpointInfo: info).serializedBytes())
            var clientInit = try Ukey2Client().clientInit
            for _ in 0..<Int.random(in: 1...4) {
                clientInit[Int.random(in: 0..<clientInit.count)] ^= UInt8.random(in: 1...255)
            }
            try? await clientEnd.writeFrame(clientInit)
            try? await clientEnd.writeFrame(secureRandomBytes(80))
            clientEnd.close()
            await waitUntilDone(session)
            XCTAssertNil(collector.request)
        }
    }

    func testOversizedLengthPrefixClosesConnection() async {
        let collector = EventCollector()
        let (session, clientEnd, _) = startInbound(collector: collector)
        clientEnd.enqueue(Data([0xFF, 0xFF, 0xFF, 0xFF])) { _ in }
        await waitUntilDone(session)
    }

    func testRandomEncryptedFramesAfterHandshake() async throws {
        for _ in 0..<50 {
            let collector = EventCollector()
            let (session, clientEnd, _) = startInbound(collector: collector)
            let client = try await RawClient.connect(clientEnd)
            // Garbage that is not a valid SecureMessage.
            try await clientEnd.writeFrame(secureRandomBytes(Int.random(in: 1...500)))
            await waitUntilDone(session)
            _ = client
        }
    }

    func testFilePayloadBeforeAcceptanceIsRejected() async throws {
        let destination = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }
        let collector = EventCollector()
        let (session, clientEnd, _) = startInbound(collector: collector)
        let client = try await RawClient.connect(clientEnd)
        try await client.pair()

        var meta = Nearby_Sharing_Service_Proto_FileMetadata()
        meta.name = "a.bin"
        meta.size = 4
        meta.payloadID = 42
        try await client.transport.send(SharingFrames.introduction(files: [meta], texts: []))
        await collector.wait("request") { if case .incomingRequest = $0 { true } else { false } }
        // Payload before the user accepted.
        try await client.transport.send(OfflineFrames.payload(id: 42, type: .file, totalSize: 4, offset: 0, body: Data([1, 2, 3, 4]), last: true))
        await waitUntilDone(session)
        XCTAssertEqual(collector.failure.map { if case .protocolViolation = $0 { true } else { false } }, true)
        XCTAssertEqual(allEntries(in: destination), [])
    }

    func testIntroductionBeforePairedKeyExchangeIsRejected() async throws {
        let collector = EventCollector()
        let (session, clientEnd, _) = startInbound(collector: collector)
        let client = try await RawClient.connect(clientEnd)
        var meta = Nearby_Sharing_Service_Proto_FileMetadata()
        meta.name = "a.bin"
        meta.size = 1
        meta.payloadID = 1
        try await client.transport.send(SharingFrames.introduction(files: [meta], texts: []))
        await waitUntilDone(session)
        XCTAssertNil(collector.request)
    }

    func testMaliciousNamesStayInsideDestination() async throws {
        let parent = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let collector = EventCollector()
        let (session, clientEnd, _) = startInbound(collector: collector)
        let client = try await RawClient.connect(clientEnd)
        try await client.pair()

        let names: [(String, String?)] = [("../../escape.txt", nil), ("ok.txt", "../../../outside"), ("/etc/passwd", "/abs"),
                                          (".hidden", "..\\..\\win"), ("..", nil)]
        var metas: [Nearby_Sharing_Service_Proto_FileMetadata] = []
        for (index, (name, folder)) in names.enumerated() {
            var meta = Nearby_Sharing_Service_Proto_FileMetadata()
            meta.name = name
            meta.size = 3
            meta.payloadID = Int64(index + 1)
            if let folder { meta.parentFolder = folder }
            metas.append(meta)
        }
        try await client.transport.send(SharingFrames.introduction(files: metas, texts: []))
        await collector.wait("request") { if case .incomingRequest = $0 { true } else { false } }
        await session.respond(accept: true, destination: destination)
        _ = try await client.expectSharing(.response)
        for meta in metas {
            try await client.transport.send(OfflineFrames.payload(id: meta.payloadID, type: .file, totalSize: 3, offset: 0, body: Data("abc".utf8), last: false))
            try await client.transport.send(OfflineFrames.payload(id: meta.payloadID, type: .file, totalSize: 3, offset: 3, body: Data(), last: true))
        }
        await collector.wait("completed") { if case .completed = $0 { true } else { false } }
        XCTAssertEqual(allEntries(in: parent).filter { !$0.hasPrefix("dest") }, [], "nothing written outside the destination")
        XCTAssertEqual(visibleFiles(in: destination).count, names.count)
        XCTAssertFalse(allEntries(in: destination).contains { $0.split(separator: "/").contains { $0.hasPrefix(".") } })
    }

    func testOversizedAndOverlappingFilePayloadsAreRejected() async throws {
        let destination = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }
        let collector = EventCollector()
        let (session, clientEnd, _) = startInbound(collector: collector)
        let client = try await RawClient.connect(clientEnd)
        try await client.pair()
        var meta = Nearby_Sharing_Service_Proto_FileMetadata()
        meta.name = "a.bin"
        meta.size = 4
        meta.payloadID = 9
        try await client.transport.send(SharingFrames.introduction(files: [meta], texts: []))
        await collector.wait("request") { if case .incomingRequest = $0 { true } else { false } }
        await session.respond(accept: true, destination: destination)
        _ = try await client.expectSharing(.response)
        // More bytes than announced.
        try await client.transport.send(OfflineFrames.payload(id: 9, type: .file, totalSize: 4, offset: 0, body: Data(count: 10), last: true))
        await waitUntilDone(session)
        XCTAssertNotNil(collector.failure)
        XCTAssertEqual(allEntries(in: destination), [])
    }
}
