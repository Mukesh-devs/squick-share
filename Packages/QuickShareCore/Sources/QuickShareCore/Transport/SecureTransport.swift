import Foundation
import SwiftProtobuf

/// The encrypted phase of a connection. Serializes sends so sequence numbers match wire order,
/// and reassembles BYTES payloads that carry sharing frames.
actor SecureTransport {
    let stream: ByteStream
    private var channel: SecureChannel
    private let diagnostics: Diagnostics
    private let tag: String
    private(set) var lastInbound = Date()
    private var sentFileChunks = 0
    private var receivedFileChunks = 0

    init(stream: ByteStream, keys: SecureChannelKeys, diagnostics: Diagnostics, tag: String) {
        self.stream = stream
        channel = SecureChannel(keys: keys)
        self.diagnostics = diagnostics
        self.tag = tag
    }

    /// Encrypts and queues `frame`, then waits until the transport accepted it (back-pressure).
    func send(_ frame: OfflineFrame) async throws {
        let plaintext: Data = try frame.serializedBytes()
        let sealed = try channel.seal(plaintext)
        let wire = Framing.encode(sealed)
        if Self.shouldLog(frame, count: &sentFileChunks) {
            diagnostics.debug(tag, "→ \(frame.logDescription) [\(wire.count) B]")
        }
        // Encrypt + enqueue happen with no suspension in between, so concurrent senders
        // (keep-alives, file chunks) can never reorder sequence numbers on the wire.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stream.enqueue(wire) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    /// Sends a sharing frame as a BYTES payload: one data chunk, then an empty LAST_CHUNK (PROTOCOL_NOTES §6).
    func send(_ sharing: SharingFrame) async throws {
        let body: Data = try sharing.serializedBytes()
        let id = secureRandomInt64()
        diagnostics.debug(tag, "→ sharing \(sharing.logDescription)")
        try await send(OfflineFrames.payload(id: id, type: .bytes, totalSize: Int64(body.count), offset: 0, body: body, last: false))
        try await send(OfflineFrames.payload(id: id, type: .bytes, totalSize: Int64(body.count), offset: Int64(body.count), body: Data(), last: true))
    }

    /// Reads, authenticates and decrypts the next frame.
    func receive() async throws -> OfflineFrame {
        let raw = try await stream.readFrame()
        let plaintext = try channel.open(raw)
        lastInbound = Date()
        let frame: OfflineFrame
        do {
            frame = try OfflineFrame(serializedBytes: plaintext)
        } catch {
            throw TransferError.protocolViolation("undecodable OfflineFrame")
        }
        if Self.shouldLog(frame, count: &receivedFileChunks) {
            diagnostics.debug(tag, "← \(frame.logDescription) [\(raw.count + 4) B]")
        }
        return frame
    }

    func close() {
        stream.close()
    }

    /// File data chunks are sampled (first 3, every 200th, and last chunks) to keep logs readable.
    private static func shouldLog(_ frame: OfflineFrame, count: inout Int) -> Bool {
        guard frame.v1.type == .payloadTransfer, frame.v1.payloadTransfer.payloadHeader.type == .file,
              frame.v1.payloadTransfer.packetType == .data else { return true }
        count += 1
        return count <= 3 || count % 200 == 0 || frame.v1.payloadTransfer.payloadChunk.flags & 1 != 0
    }
}

/// Reassembles BYTES payloads (sharing frames, text) by payload ID.
struct BytesPayloadAssembler {
    private var pending: [Int64: (total: Int64, data: Data)] = [:]

    /// Feeds one BYTES packet. Returns the complete payload when its LAST_CHUNK arrives.
    mutating func add(_ transfer: PayloadTransferFrame) throws -> (id: Int64, data: Data)? {
        let header = transfer.payloadHeader
        let chunk = transfer.payloadChunk
        let total = header.totalSize
        guard total >= 0, total <= Limits.maxBytesPayload else {
            throw TransferError.protocolViolation("BYTES payload of \(total) bytes exceeds limit")
        }
        var entry = pending[header.id] ?? (total, Data())
        if pending[header.id] == nil {
            guard pending.count < Limits.maxPendingBytesPayloads else {
                throw TransferError.protocolViolation("too many concurrent BYTES payloads")
            }
        }
        guard entry.total == total else { throw TransferError.protocolViolation("BYTES payload size changed") }
        if !chunk.body.isEmpty {
            guard chunk.offset == Int64(entry.data.count) else {
                throw TransferError.protocolViolation("BYTES chunk offset \(chunk.offset), expected \(entry.data.count)")
            }
            guard Int64(entry.data.count + chunk.body.count) <= total else {
                throw TransferError.protocolViolation("BYTES payload larger than announced")
            }
            entry.data.append(chunk.body)
        }
        if chunk.flags & 1 != 0 {
            pending[header.id] = nil
            guard Int64(entry.data.count) == total else {
                throw TransferError.protocolViolation("BYTES payload ended at \(entry.data.count) of \(total)")
            }
            return (header.id, entry.data)
        }
        pending[header.id] = entry
        return nil
    }
}
