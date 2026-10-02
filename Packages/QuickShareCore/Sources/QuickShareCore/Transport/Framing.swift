import Foundation

/// Hard limits enforced against peers (PROTOCOL_NOTES §10).
public enum Limits {
    /// Largest length-prefixed frame we accept.
    public static let maxFrameLength = 5 * 1024 * 1024
    /// Largest BYTES payload (sharing frames and text).
    public static let maxBytesPayload = 1024 * 1024
    /// Largest number of concurrent, unfinished BYTES payloads.
    static let maxPendingBytesPayloads = 16
    /// Maximum files in one Introduction.
    public static let maxFiles = 10_000
    /// Maximum text items in one Introduction.
    public static let maxTexts = 100
    /// Maximum folder nesting for received files.
    public static let maxFolderDepth = 32

    static let handshakeTimeout: TimeInterval = 15
    static let pairedKeyTimeout: TimeInterval = 15
    static let introductionTimeout: TimeInterval = 15
    static let connectTimeout: TimeInterval = 15
}

/// 4-byte big-endian length prefix framing (PROTOCOL_NOTES §3).
enum Framing {
    static func encode(_ payload: Data) -> Data {
        var out = Data(capacity: payload.count + 4)
        let length = UInt32(payload.count)
        out.append(UInt8(truncatingIfNeeded: length >> 24))
        out.append(UInt8(truncatingIfNeeded: length >> 16))
        out.append(UInt8(truncatingIfNeeded: length >> 8))
        out.append(UInt8(truncatingIfNeeded: length))
        out.append(payload)
        return out
    }

    static func decodeLength(_ header: Data) -> Int {
        precondition(header.count == 4)
        return header.reduce(0) { ($0 << 8) | Int($1) }
    }
}

extension ByteStream {
    /// Reads one length-prefixed frame, rejecting oversized frames before allocating.
    func readFrame(maxLength: Int = Limits.maxFrameLength) async throws -> Data {
        let length = Framing.decodeLength(try await read(exactly: 4))
        guard length <= maxLength else { throw TransportError.frameTooLarge(length) }
        return try await read(exactly: length)
    }

    func writeFrame(_ payload: Data) async throws {
        try await write(Framing.encode(payload))
    }
}

/// Runs `operation`, failing with `TransportError.timedOut(stage)` after `seconds`.
/// On timeout `onTimeout` runs first (typically closing the stream so a blocked read returns).
func withTimeout<T: Sendable>(
    _ seconds: TimeInterval,
    stage: String,
    onTimeout: @escaping @Sendable () -> Void = {},
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
            onTimeout()
            throw TransportError.timedOut(stage)
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
