import Foundation
import Network
import XCTest
@testable import QuickShareCore

/// Our sender talking to our receiver in one process: over an in-memory pipe and over real TCP.
final class LoopbackTests: XCTestCase {
    var directories: [URL] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }

    func tempDir() throws -> URL {
        let url = try makeTempDirectory()
        directories.append(url)
        return url
    }

    /// Runs a sender against an InboundSession over a memory pipe.
    func runMemoryTransfer(_ items: [SendItem], options: ProtocolOptions = ProtocolOptions(),
                           receiver: EventCollector, sender: EventCollector) -> (InboundSession, OutgoingTransfer) {
        let (inbound, clientEnd, _) = startInbound(collector: receiver, options: options)
        let identity = LocalIdentity(name: "Sender Mac", options: options)
        let transfer = QuickShareSender(identity: identity, diagnostics: .silent).start(
            items, device: RemoteDevice(endpointID: "TEST", name: "Test Mac", type: .laptop), qrSession: nil,
            eventHandler: sender.handler, makeStream: { clientEnd })
        return (inbound, transfer)
    }

    func testFilesTextAndFoldersOverMemoryPipe() async throws {
        let source = try tempDir(), destination = try tempDir()
        let big = source.appendingPathComponent("video.mp4")
        let bigHash = try writeRandomFile(big, size: 3 * 1024 * 1024 + 123)   // several chunks, not chunk-aligned
        let small = source.appendingPathComponent("photo.jpg")
        let smallHash = try writeRandomFile(small, size: 1000)
        let nested = source.appendingPathComponent("nested.txt")
        let nestedHash = try writeRandomFile(nested, size: 4096)

        let receiver = EventCollector(), sender = EventCollector()
        let (inbound, _) = runMemoryTransfer(
            [.file(big, parentFolder: nil), .file(small, parentFolder: nil),
             .file(nested, parentFolder: "Album/2024"), .text("https://example.com/page")],
            receiver: receiver, sender: sender)

        let pinEvent = await sender.wait("sender PIN") { if case .awaitingAcceptance = $0 { true } else { false } }
        await receiver.wait("incoming request") { if case .incomingRequest = $0 { true } else { false } }
        let request = try XCTUnwrap(receiver.request)
        guard case .awaitingAcceptance(_, _, let senderPin) = pinEvent else { return XCTFail() }
        XCTAssertEqual(request.pin, senderPin, "both sides must show the same PIN")
        XCTAssertEqual(request.device.name, "Sender Mac")
        XCTAssertEqual(request.files.map(\.name).sorted(), ["nested.txt", "photo.jpg", "video.mp4"])
        XCTAssertEqual(request.files.first { $0.name == "nested.txt" }?.parentFolder, "Album/2024")
        XCTAssertEqual(request.files.first { $0.name == "photo.jpg" }?.mimeType, "image/jpeg")
        XCTAssertEqual(request.texts.first?.kind, .url)

        await inbound.respond(accept: true, destination: destination)
        await receiver.wait("receiver completed") { if case .completed = $0 { true } else { false } }
        await sender.wait("sender completed") { if case .completed = $0 { true } else { false } }

        XCTAssertEqual(try sha256(of: destination.appendingPathComponent("video.mp4")), bigHash)
        XCTAssertEqual(try sha256(of: destination.appendingPathComponent("photo.jpg")), smallHash)
        XCTAssertEqual(try sha256(of: destination.appendingPathComponent("Album/2024/nested.txt")), nestedHash)
        XCTAssertTrue(receiver.all.contains { if case .receivedText(_, "https://example.com/page", .url) = $0 { true } else { false } })
        XCTAssertFalse(allEntries(in: destination).contains { $0.contains(".part") }, "no temp files left")
        XCTAssertNil(receiver.failure)
        XCTAssertNil(sender.failure)
    }

    func testDuplicateNamesAreNumbered() async throws {
        let source = try tempDir(), destination = try tempDir()
        try Data("existing".utf8).write(to: destination.appendingPathComponent("photo.jpg"))
        let a = source.appendingPathComponent("photo.jpg")
        try writeRandomFile(a, size: 100)
        let sub = source.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let b = sub.appendingPathComponent("photo.jpg")
        try writeRandomFile(b, size: 200)

        let receiver = EventCollector(), sender = EventCollector()
        let (inbound, _) = runMemoryTransfer([.file(a, parentFolder: nil), .file(b, parentFolder: nil)], receiver: receiver, sender: sender)
        await receiver.wait("request") { if case .incomingRequest = $0 { true } else { false } }
        await inbound.respond(accept: true, destination: destination)
        await receiver.wait("completed") { if case .completed = $0 { true } else { false } }
        XCTAssertEqual(allEntries(in: destination), ["photo (1).jpg", "photo (2).jpg", "photo.jpg"])
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("photo.jpg"), encoding: .utf8), "existing")
    }

    func testDeclineIsReportedToSender() async throws {
        let source = try tempDir(), destination = try tempDir()
        let file = source.appendingPathComponent("a.bin")
        try writeRandomFile(file, size: 10)
        let receiver = EventCollector(), sender = EventCollector()
        let (inbound, _) = runMemoryTransfer([.file(file, parentFolder: nil)], receiver: receiver, sender: sender)
        await receiver.wait("request") { if case .incomingRequest = $0 { true } else { false } }
        await inbound.respond(accept: false, destination: nil)
        await sender.wait("sender declined") { if case .failed(_, .declined) = $0 { true } else { false } }
        await receiver.wait("receiver declined") { if case .failed(_, .declined) = $0 { true } else { false } }
        XCTAssertEqual(allEntries(in: destination), [])
    }

    func testAcceptPromptTimesOut() async throws {
        let source = try tempDir()
        let file = source.appendingPathComponent("a.bin")
        try writeRandomFile(file, size: 10)
        let receiver = EventCollector(), sender = EventCollector()
        let (_, clientEnd, _) = startInbound(collector: receiver, decisionTimeout: 0.5)
        QuickShareSender(identity: LocalIdentity(name: "S"), diagnostics: .silent).start(
            [.file(file, parentFolder: nil)], device: RemoteDevice(endpointID: "T", name: "T", type: .laptop),
            qrSession: nil, eventHandler: sender.handler, makeStream: { clientEnd })
        await receiver.wait("receiver timed out") { if case .failed(_, .timedOut) = $0 { true } else { false } }
        await sender.wait("sender sees timeout") { if case .failed(_, .timedOut) = $0 { true } else { false } }
    }

    func testSenderCancelMidTransferCleansUpReceiver() async throws {
        let source = try tempDir(), destination = try tempDir()
        let file = source.appendingPathComponent("large.bin")
        try writeRandomFile(file, size: 40 * 1024 * 1024)
        let receiver = EventCollector(), sender = EventCollector()
        let (inbound, transfer) = runMemoryTransfer([.file(file, parentFolder: "Folder")], receiver: receiver, sender: sender)
        await receiver.wait("request") { if case .incomingRequest = $0 { true } else { false } }
        await inbound.respond(accept: true, destination: destination)
        await receiver.wait("some progress") { if case .progress(_, let bytes, _) = $0 { bytes > 0 } else { false } }
        transfer.cancel()
        await sender.wait("sender cancelled") { if case .failed(_, .cancelledByUser) = $0 { true } else { false } }
        await receiver.wait("receiver failed") { if case .failed = $0 { true } else { false } }
        XCTAssertEqual(receiver.failure, .cancelledByPeer)
        XCTAssertEqual(allEntries(in: destination), [], "temp file and created folder must be removed")
    }

    func testReceiverCancelIsReportedToSender() async throws {
        let source = try tempDir(), destination = try tempDir()
        let file = source.appendingPathComponent("large.bin")
        try writeRandomFile(file, size: 40 * 1024 * 1024)
        let receiver = EventCollector(), sender = EventCollector()
        let (inbound, _) = runMemoryTransfer([.file(file, parentFolder: nil)], receiver: receiver, sender: sender)
        await receiver.wait("request") { if case .incomingRequest = $0 { true } else { false } }
        await inbound.respond(accept: true, destination: destination)
        await receiver.wait("some progress") { if case .progress(_, let bytes, _) = $0 { bytes > 0 } else { false } }
        await inbound.cancel()
        await sender.wait("sender sees cancel") { if case .failed = $0 { true } else { false } }
        XCTAssertTrue([.cancelledByPeer, .connectionLost].contains(sender.failure))
        XCTAssertEqual(receiver.failure, .cancelledByUser)
        XCTAssertEqual(allEntries(in: destination), [])
    }

    func testNotEnoughSpaceIsReported() async throws {
        let source = try tempDir(), destination = try tempDir()
        let file = source.appendingPathComponent("a.bin")
        try writeRandomFile(file, size: 10)
        let receiver = EventCollector(), sender = EventCollector()
        let (serverEnd, clientEnd) = MemoryByteStream.pair()
        // Reserve more than any disk has, so the space check must fail.
        var config = InboundSession.Configuration(identity: LocalIdentity(name: "Mac"))
        config.reservedSpace = Int64.max / 2
        let inbound = InboundSession(stream: serverEnd, configuration: config, diagnostics: .silent, emit: receiver.handler)
        Task { await inbound.run() }
        QuickShareSender(identity: LocalIdentity(name: "S"), diagnostics: .silent).start(
            [.file(file, parentFolder: nil)], device: RemoteDevice(endpointID: "T", name: "T", type: .laptop),
            qrSession: nil, eventHandler: sender.handler, makeStream: { clientEnd })
        await receiver.wait("request") { if case .incomingRequest = $0 { true } else { false } }
        await inbound.respond(accept: true, destination: destination)
        await sender.wait("sender sees no space") { if case .failed(_, .notEnoughSpace) = $0 { true } else { false } }
        XCTAssertEqual(receiver.failure, .notEnoughSpace)
    }

    func testProtocolOptionVariantsInteroperate() async throws {
        var options = ProtocolOptions()
        options.endpointInfoVersion = 1
        options.sendOSInfo = false
        options.sendLegacyStatusField = false
        options.senderSendsConnectionResponseFirst = false
        options.sendTrailingEmptyChunk = false
        options.chunkSize = 64 * 1024
        let source = try tempDir(), destination = try tempDir()
        let file = source.appendingPathComponent("a.bin")
        let hash = try writeRandomFile(file, size: 64 * 1024 * 3)   // exactly chunk-aligned
        let receiver = EventCollector(), sender = EventCollector()
        let (inbound, _) = runMemoryTransfer([.file(file, parentFolder: nil)], options: options, receiver: receiver, sender: sender)
        await receiver.wait("request") { if case .incomingRequest = $0 { true } else { false } }
        await inbound.respond(accept: true, destination: destination)
        await receiver.wait("completed") { if case .completed = $0 { true } else { false } }
        XCTAssertEqual(try sha256(of: destination.appendingPathComponent("a.bin")), hash)
    }

    /// Real TCP over loopback through NWListener/NWConnection, with a throughput measurement.
    func testTCPLoopbackTransferAndThroughput() async throws {
        let source = try tempDir(), destination = try tempDir()
        let size = 128 * 1024 * 1024
        let file = source.appendingPathComponent("big.bin")
        let hash = try writeRandomFile(file, size: size)

        let receiverEvents = EventCollector(), senderEvents = EventCollector()
        let readyFlag = OnceFlag()
        let ready = expectation(description: "listening")
        var config = QuickShareReceiver.Configuration(identity: LocalIdentity(name: "Receiver"))
        config.advertise = false
        let receiver = QuickShareReceiver(configuration: config, diagnostics: .silent, eventHandler: receiverEvents.handler) { status in
            if case .advertising = status, readyFlag.claim() { ready.fulfill() }
        }
        receiver.start()
        defer { receiver.stop() }
        await fulfillment(of: [ready], timeout: 10)
        let port = try XCTUnwrap(receiver.port)

        QuickShareSender(identity: LocalIdentity(name: "Sender"), diagnostics: .silent)
            .send([.file(file, parentFolder: nil)], host: "127.0.0.1", port: port, eventHandler: senderEvents.handler)
        let request = await receiverEvents.wait("request") { if case .incomingRequest = $0 { true } else { false } }
        let baseline = memoryFootprint()
        let sampler = PeakMemorySampler()
        sampler.start()
        let start = Date()
        receiver.respond(to: try XCTUnwrap(request?.transferID), accept: true, destination: destination)
        await receiverEvents.wait("completed", timeout: 120) { if case .completed = $0 { true } else { false } }
        let seconds = Date().timeIntervalSince(start)
        sampler.stop()
        let growth = sampler.peak - baseline
        print(String(format: "TCP loopback: %d MiB in %.2f s = %.0f MB/s, peak memory growth %.1f MiB",
                     size >> 20, seconds, Double(size) / seconds / 1_000_000, Double(growth) / 1_048_576))
        // Sender and receiver both run in this process; streaming keeps growth to a few chunks, not the file size.
        XCTAssertLessThan(growth, 48 * 1024 * 1024, "memory must stay flat while streaming a 128 MiB file")
        XCTAssertEqual(try sha256(of: destination.appendingPathComponent("big.bin")), hash)
        await senderEvents.wait("sender completed") { if case .completed = $0 { true } else { false } }
    }

    /// Cancelling while the TCP connect is still pending must end the transfer at once,
    /// not when the connect times out (seen with a phone that had left its Receive screen).
    func testCancelDuringConnectIsImmediate() async throws {
        let source = try tempDir()
        let file = source.appendingPathComponent("a.bin")
        try writeRandomFile(file, size: 10)
        let sender = EventCollector()
        let transfer = QuickShareSender(identity: LocalIdentity(name: "S"), diagnostics: .silent).start(
            [.file(file, parentFolder: nil)], device: RemoteDevice(endpointID: "T", name: "T", type: .phone),
            qrSession: nil, eventHandler: sender.handler) {
            try await Task.sleep(nanoseconds: 30_000_000_000)   // a connect that never completes
            throw TransferError.unreachable
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        let start = Date()
        transfer.cancel()
        await sender.wait("cancelled", timeout: 5) { if case .failed(_, .cancelledByUser) = $0 { true } else { false } }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }
}
