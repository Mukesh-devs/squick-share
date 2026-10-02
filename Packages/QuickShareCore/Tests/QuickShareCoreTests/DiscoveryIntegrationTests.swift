import Foundation
import XCTest
@testable import QuickShareCore

/// Discovery over the real mDNS responder on this machine: advertise, browse and match.
///
/// The transfer itself then runs over 127.0.0.1: macOS Local Network privacy filters inbound LAN
/// connections to the xctest runner, which has no permission prompt. Discovered endpoints resolve to
/// the Mac's LAN address, so they are only used for discovery here. Sending to a resolved service
/// endpoint is covered by the manual CLI and app checks in docs/TESTING.md.
final class DiscoveryIntegrationTests: XCTestCase {
    /// Sends to `receiver` over loopback, as if `device` had been resolved.
    @discardableResult
    func sendOverLoopback(_ items: [SendItem], device: DiscoveredDevice, receiver: QuickShareReceiver,
                          qr: QRCodeSession?, events: EventCollector) throws -> OutgoingTransfer {
        let port = try XCTUnwrap(receiver.port)
        return QuickShareSender(identity: LocalIdentity(name: "Mac"), diagnostics: .silent).start(
            items, device: device.remoteDevice, qrSession: qr, eventHandler: events.handler) {
            try await QuickShareSender.connect(.hostPort(host: "127.0.0.1", port: .init(rawValue: port)!), interface: .any)
        }
    }

    final class LogCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [String] = []
        func add(_ entry: Diagnostics.Entry) { lock.lock(); messages.append(entry.message); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return messages }
    }

    final class DeviceStore: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [DiscoveredDevice] = []
        var devices: [DiscoveredDevice] {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); value = newValue; lock.unlock() }
        }
    }

    func waitForDevice(_ store: DeviceStore, timeout: TimeInterval = 20, _ match: (DiscoveredDevice) -> Bool) async -> DiscoveredDevice? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let device = store.devices.first(where: match) { return device }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    func testAdvertiseBrowseAndSendByName() async throws {
        let name = "Test Phone \(UUID().uuidString.prefix(6))"
        let destination = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }
        let source = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: source) }
        let file = source.appendingPathComponent("photo.jpg")
        let hash = try writeRandomFile(file, size: 2 * 1024 * 1024)

        let receiverEvents = EventCollector()
        var options = ProtocolOptions()
        options.advertisedDeviceType = .phone
        let receiver = QuickShareReceiver(configuration: .init(identity: LocalIdentity(name: name, options: options)),
                                          diagnostics: .silent, eventHandler: receiverEvents.handler)
        receiver.start()
        defer { receiver.stop() }

        let store = DeviceStore()
        let browser = NearbyBrowser(diagnostics: .silent, updateHandler: { store.devices = $0 })
        browser.start()
        defer { browser.stop() }
        let found = await waitForDevice(store) { $0.name == name }
        let device = try XCTUnwrap(found, "receiver not discovered over mDNS")
        XCTAssertEqual(device.type, .phone)
        XCTAssertEqual(device.endpointID, receiver.endpointID)

        let senderEvents = EventCollector()
        try sendOverLoopback([.file(file, parentFolder: nil)], device: device, receiver: receiver, qr: nil, events: senderEvents)
        let request = await receiverEvents.wait("request") { if case .incomingRequest = $0 { true } else { false } }
        if request == nil { print("sender events: \(senderEvents.all)") }
        receiver.respond(to: try XCTUnwrap(request?.transferID), accept: true, destination: destination)
        await receiverEvents.wait("completed") { if case .completed = $0 { true } else { false } }
        await senderEvents.wait("sender completed") { if case .completed = $0 { true } else { false } }
        XCTAssertEqual(try sha256(of: destination.appendingPathComponent("photo.jpg")), hash)
    }

    /// The Mac shows a QR code; a "phone" advertises the matching token; the Mac finds it,
    /// connects automatically and signs the UKEY2 auth string.
    func testQRCodeFlowOverMDNS() async throws {
        let qr = QRCodeSession()
        let logs = LogCollector()
        let diagnostics = Diagnostics(verbose: true) { logs.add($0) }
        let destination = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }

        // Another visible device without the token must not match.
        let decoy = QuickShareReceiver(configuration: .init(identity: LocalIdentity(name: "Decoy \(UUID().uuidString.prefix(4))")),
                                       diagnostics: .silent, eventHandler: { _ in })
        decoy.start()
        defer { decoy.stop() }

        var config = QuickShareReceiver.Configuration(identity: LocalIdentity(name: "QR Phone \(UUID().uuidString.prefix(4))"))
        config.qrCodeData = qr.advertisingToken
        let receiverEvents = EventCollector()
        let receiver = QuickShareReceiver(configuration: config, diagnostics: diagnostics, eventHandler: receiverEvents.handler)
        receiver.start()
        defer { receiver.stop() }

        let store = DeviceStore()
        let browser = NearbyBrowser(diagnostics: .silent, updateHandler: { store.devices = $0 })
        browser.start()
        defer { browser.stop() }
        let found = await waitForDevice(store) { $0.qrMatch(qr) != nil }
        let device = try XCTUnwrap(found, "QR answer not discovered")
        XCTAssertEqual(device.endpointID, receiver.endpointID)
        XCTAssertFalse(store.devices.contains { $0.endpointID == decoy.endpointID && $0.qrMatch(qr) != nil })

        let senderEvents = EventCollector()
        try sendOverLoopback([.text("hello via QR")], device: device, receiver: receiver, qr: qr, events: senderEvents)
        let request = await receiverEvents.wait("request") { if case .incomingRequest = $0 { true } else { false } }
        if request == nil { print("sender events: \(senderEvents.all)") }
        receiver.respond(to: try XCTUnwrap(request?.transferID), accept: true, destination: destination)
        await receiverEvents.wait("text") { if case .receivedText(_, "hello via QR", _) = $0 { true } else { false } }
        XCTAssertTrue(logs.all.contains { $0.contains("qr_code_handshake_data=64 B") }, "sender must sign the auth string for QR peers")
    }
}
