import Foundation
import XCTest
@testable import QuickShareCore

/// Regression tests for resource use and failure handling.
final class RobustnessTests: XCTestCase {
    var directories: [URL] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }

    func tempDir(_ name: String = #function) throws -> URL {
        let url = try makeTempDirectory(name)
        directories.append(url)
        return url
    }

    /// A writer opens nothing until data arrives, and discarding removes its temporary file.
    func testFileWriterOpensLazilyAndCleansUp() async throws {
        let folder = try tempDir()
        let writer = IncomingFileWriter(payloadID: 1, expectedSize: 10, folder: folder, name: "a.txt")
        XCTAssertFalse(writer.isOpen)
        XCTAssertTrue(allEntries(in: folder).isEmpty, "no file before the first chunk")

        try await writer.append(Data(repeating: 1, count: 4), at: 0)
        XCTAssertTrue(writer.isOpen)
        XCTAssertTrue(FileManager.default.fileExists(atPath: writer.tempURL.path))

        await writer.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: writer.tempURL.path))
        await writer.discard()   // a second call is harmless
    }

    /// An empty file still produces an (empty) file at its final name.
    func testFileWriterFinishesEmptyFile() async throws {
        let folder = try tempDir()
        let writer = IncomingFileWriter(payloadID: 2, expectedSize: 0, folder: folder, name: "empty.txt")
        let url = try await writer.finish()
        XCTAssertEqual(url.lastPathComponent, "empty.txt")
        XCTAssertEqual(try Data(contentsOf: url).count, 0)
        XCTAssertFalse(allEntries(in: folder).contains { $0.contains(".part") })
    }

    /// Receiving more files than the default file-descriptor limit (256) must work: files are
    /// opened one at a time instead of all at once when the transfer is accepted.
    func testManyFilesStayWithinFileDescriptorLimit() async throws {
        var limit = rlimit()
        getrlimit(RLIMIT_NOFILE, &limit)
        let original = limit
        if limit.rlim_cur > 256 {
            limit.rlim_cur = 256
            setrlimit(RLIMIT_NOFILE, &limit)
        }
        defer {
            var restore = original
            setrlimit(RLIMIT_NOFILE, &restore)
        }

        let source = try tempDir("many-src"), destination = try tempDir("many-dst")
        let count = 400
        var items: [SendItem] = []
        for index in 0..<count {
            let url = source.appendingPathComponent("file-\(index).txt")
            try Data("file \(index)\n".utf8).write(to: url)
            items.append(.file(url, parentFolder: nil))
        }

        let receiver = EventCollector(), sender = EventCollector()
        let (session, clientEnd, _) = startInbound(collector: receiver)
        _ = QuickShareSender(identity: LocalIdentity(name: "Sender Mac"), diagnostics: .silent).start(
            items, device: RemoteDevice(endpointID: "TEST", name: "Test Mac", type: .laptop), qrSession: nil,
            eventHandler: sender.handler, makeStream: { clientEnd })
        await receiver.wait("incoming request") { if case .incomingRequest = $0 { true } else { false } }
        await session.respond(accept: true, destination: destination)
        await receiver.wait("receiver completed", timeout: 60) { if case .completed = $0 { true } else { false } }
        await sender.wait("sender completed", timeout: 60) { if case .completed = $0 { true } else { false } }
        XCTAssertNil(receiver.failure)
        XCTAssertEqual(allEntries(in: destination).filter { $0.hasSuffix(".txt") }.count, count)
        XCTAssertFalse(allEntries(in: destination).contains { $0.contains(".part") })
    }

    func testBeaconFilterAcceptsOnlyQuickShare() {
        // Quick Share fast initiation: model ID FC 12 8E, then metadata.
        XCTAssertTrue(QuickShareBeaconListener.isQuickShareBeacon(Data([0xFC, 0x12, 0x8E, 0x01, 0x42, 0x00])))
        // Fast Pair earbuds use the same service UUID with their own model ID.
        XCTAssertFalse(QuickShareBeaconListener.isQuickShareBeacon(Data([0x2C, 0x01, 0x8E])))
        XCTAssertFalse(QuickShareBeaconListener.isQuickShareBeacon(Data([0xFC, 0x12])))
        XCTAssertFalse(QuickShareBeaconListener.isQuickShareBeacon(nil))
    }
}
