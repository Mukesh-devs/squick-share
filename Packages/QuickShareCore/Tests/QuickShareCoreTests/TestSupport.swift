import CryptoKit
import Foundation
import XCTest
@testable import QuickShareCore

extension Data {
    init(hex: String) {
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            data.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self = data
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

/// Collects transfer events and lets tests wait for them.
final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [TransferEvent] = []

    var handler: @Sendable (TransferEvent) -> Void {
        { [weak self] event in
            guard let self else { return }
            self.lock.lock()
            self.events.append(event)
            self.lock.unlock()
        }
    }

    var all: [TransferEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    /// Waits until `predicate` matches an event, failing the test after `timeout`.
    @discardableResult
    func wait(_ description: String, timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line,
              _ predicate: (TransferEvent) -> Bool) async -> TransferEvent? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let match = all.first(where: predicate) { return match }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for \(description); got \(all.map { "\($0)" })", file: file, line: line)
        return nil
    }

    var request: IncomingTransferRequest? {
        for case .incomingRequest(let request) in all { return request }
        return nil
    }

    var failure: TransferError? {
        for case .failed(_, let error) in all { return error }
        return nil
    }

    var isFinished: Bool {
        all.contains { if case .completed = $0 { true } else if case .failed = $0 { true } else { false } }
    }
}

func makeTempDirectory(_ name: String = #function) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("squickshare-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.resolvingSymlinksInPath()
}

/// Writes `size` pseudo-random bytes and returns the file's SHA-256.
@discardableResult
func writeRandomFile(_ url: URL, size: Int) throws -> String {
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    var hasher = SHA256()
    var generator = SystemRandomNumberGenerator()
    var remaining = size
    while remaining > 0 {
        let count = min(remaining, 1 << 20)
        var words = [UInt64](repeating: 0, count: (count + 7) / 8)
        for index in words.indices { words[index] = generator.next() }
        let chunk = words.withUnsafeBytes { Data($0.prefix(count)) }
        hasher.update(data: chunk)
        try handle.write(contentsOf: chunk)
        remaining -= count
    }
    try handle.close()
    return Data(hasher.finalize()).hex
}

func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
    return Data(hasher.finalize()).hex
}

/// Files in `directory` (recursively) that are not hidden temp files.
func visibleFiles(in directory: URL) -> [URL] {
    let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
    var result: [URL] = []
    while let url = enumerator?.nextObject() as? URL {
        if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { result.append(url) }
    }
    return result
}

func allEntries(in directory: URL) -> [String] {
    (FileManager.default.subpaths(atPath: directory.path) ?? []).sorted()
}

/// A client that completes the real handshake and then sends hand-crafted encrypted frames.
struct RawClient {
    let stream: ByteStream
    let transport: SecureTransport

    static func connect(_ stream: ByteStream) async throws -> RawClient {
        let ukey = try await Handshake.runClient(stream: stream, endpointID: "TEST", identity: LocalIdentity(name: "Raw"),
                                                 diagnostics: .silent, tag: "raw")
        let transport = SecureTransport(stream: stream, keys: SecureChannelKeys(nextSecret: ukey.nextSecret, role: .client),
                                        diagnostics: .silent, tag: "raw")
        return RawClient(stream: stream, transport: transport)
    }

    /// Reads frames until a sharing frame of `type` arrives.
    func expectSharing(_ type: SharingV1Frame.FrameType) async throws -> SharingFrame {
        var assembler = BytesPayloadAssembler()
        while true {
            let frame = try await transport.receive()
            guard frame.v1.type == .payloadTransfer else { continue }
            if let (_, data) = try assembler.add(frame.v1.payloadTransfer) {
                let sharing = try SharingFrame(serializedBytes: data)
                if sharing.v1.type == type { return sharing }
            }
        }
    }

    /// Runs the paired-key exchange, leaving the receiver waiting for an Introduction.
    func pair() async throws {
        _ = try await expectSharing(.pairedKeyEncryption)
        try await transport.send(SharingFrames.pairedKeyEncryption())
        _ = try await expectSharing(.pairedKeyResult)
        try await transport.send(SharingFrames.pairedKeyResult())
    }
}

/// Runs an InboundSession on one end of an in-memory pipe and returns the other end.
func startInbound(collector: EventCollector, decisionTimeout: TimeInterval = 60,
                  options: ProtocolOptions = ProtocolOptions()) -> (session: InboundSession, clientEnd: MemoryByteStream, task: Task<Void, Never>) {
    let (serverEnd, clientEnd) = MemoryByteStream.pair()
    let config = InboundSession.Configuration(identity: LocalIdentity(name: "Test Mac", options: options), decisionTimeout: decisionTimeout)
    let session = InboundSession(stream: serverEnd, configuration: config, diagnostics: .silent, emit: collector.handler)
    let task = Task { await session.run() }
    return (session, clientEnd, task)
}

/// The process's physical memory footprint in bytes (what Activity Monitor shows as "Memory").
func memoryFootprint() -> Int64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return result == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
}

/// Samples the peak memory footprint until cancelled.
final class PeakMemorySampler: @unchecked Sendable {
    private let lock = NSLock()
    private var peakValue: Int64 = 0
    private var task: Task<Void, Never>?

    var peak: Int64 { lock.lock(); defer { lock.unlock() }; return peakValue }

    func start() {
        task = Task.detached { [weak self] in
            while !Task.isCancelled {
                self?.record(memoryFootprint())
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
    }

    func stop() { task?.cancel() }

    private func record(_ value: Int64) {
        lock.lock()
        peakValue = max(peakValue, value)
        lock.unlock()
    }
}
