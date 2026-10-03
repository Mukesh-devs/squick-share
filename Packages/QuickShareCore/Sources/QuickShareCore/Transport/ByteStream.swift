import Foundation
import Network

enum TransportError: Error, Equatable, CustomStringConvertible {
    case closed
    case network(String)
    case frameTooLarge(Int)
    case timedOut(String)
    case localNetworkDenied

    var description: String {
        switch self {
        case .closed: "connection closed"
        case .network(let message): "network error: \(message)"
        case .frameTooLarge(let size): "frame of \(size) bytes exceeds limit"
        case .timedOut(let stage): "timed out waiting for \(stage)"
        case .localNetworkDenied: "local network access denied"
        }
    }
}

/// A reliable, ordered byte stream. Implemented over TCP (`NWByteStream`) and in memory for tests.
protocol ByteStream: AnyObject, Sendable {
    /// Reads exactly `count` bytes. Only one read may be outstanding at a time.
    func read(exactly count: Int) async throws -> Data
    /// Queues `data` for sending. Calls to `enqueue` are delivered in call order.
    /// `completion` runs once the transport has accepted the bytes (back-pressure point).
    func enqueue(_ data: Data, completion: @escaping @Sendable (Error?) -> Void)
    /// Closes the stream. Pending and future reads fail.
    func close()
}

extension ByteStream {
    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            enqueue(data) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
}

/// `ByteStream` over an `NWConnection`.
final class NWByteStream: ByteStream, @unchecked Sendable {
    let connection: NWConnection
    private let queue: DispatchQueue

    init(connection: NWConnection, queue: DispatchQueue = DispatchQueue(label: "squickshare.connection")) {
        self.connection = connection
        self.queue = queue
    }

    /// Starts the connection and waits until it is ready.
    func start(timeout: TimeInterval) async throws {
        let once = OnceFlag()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.stateUpdateHandler = { [connection] state in
                    switch state {
                    case .ready:
                        if once.claim() { continuation.resume() }
                    case .failed(let error):
                        if once.claim() { continuation.resume(throwing: Self.map(error)) }
                    case .waiting(let error):
                        if case .dns(let code) = error, code == -65570 {
                            if once.claim() { continuation.resume(throwing: TransportError.localNetworkDenied) }
                            connection.cancel()
                        }
                    case .cancelled:
                        if once.claim() { continuation.resume(throwing: TransportError.closed) }
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + timeout) { [connection] in
                    if once.claim() {
                        continuation.resume(throwing: TransportError.timedOut("connection"))
                        connection.cancel()
                    }
                }
            }
        } onCancel: { [connection] in
            connection.cancel()
        }
    }

    func read(exactly count: Int) async throws -> Data {
        guard count > 0 else { return Data() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                    if let data, data.count == count {
                        continuation.resume(returning: data)
                    } else if let error {
                        continuation.resume(throwing: Self.map(error))
                    } else {
                        continuation.resume(throwing: TransportError.closed)
                    }
                }
            }
        } onCancel: { [connection] in
            connection.cancel()
        }
    }

    func enqueue(_ data: Data, completion: @escaping @Sendable (Error?) -> Void) {
        connection.send(content: data, completion: .contentProcessed { error in
            completion(error.map(Self.map))
        })
    }

    func close() {
        connection.cancel()
    }

    static func map(_ error: NWError) -> TransportError {
        if case .dns(let code) = error, code == -65570 { return .localNetworkDenied }
        if case .posix(let code) = error, code == .ECANCELED { return .closed }
        return .network(error.debugDescription)
    }
}

/// A thread-safe flag that can be claimed once.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }

    var isClaimed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return claimed
    }
}

/// In-memory, connected pair of byte streams (for tests and fuzzing).
final class MemoryByteStream: ByteStream, @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var isClosed = false
    private var pendingRead: (count: Int, continuation: CheckedContinuation<Data, Error>)?
    private weak var peer: MemoryByteStream?

    static func pair() -> (MemoryByteStream, MemoryByteStream) {
        let a = MemoryByteStream()
        let b = MemoryByteStream()
        a.peer = b
        b.peer = a
        return (a, b)
    }

    func read(exactly count: Int) async throws -> Data {
        guard count > 0 else { return Data() }
        return try await withTaskCancellationHandler {
            try await readNow(count)
        } onCancel: {
            self.closeLocal()
        }
    }

    private func readNow(_ count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if buffer.count >= count {
                let chunk = buffer.prefix(count)
                buffer.removeFirst(count)
                lock.unlock()
                continuation.resume(returning: Data(chunk))
            } else if isClosed {
                lock.unlock()
                continuation.resume(throwing: TransportError.closed)
            } else {
                pendingRead = (count, continuation)
                lock.unlock()
            }
        }
    }

    func enqueue(_ data: Data, completion: @escaping @Sendable (Error?) -> Void) {
        lock.lock()
        let closed = isClosed
        lock.unlock()
        guard !closed, let peer else {
            completion(TransportError.closed)
            return
        }
        peer.receive(data)
        completion(nil)
    }

    /// Delivers raw bytes as if they came from the peer (used by fuzz tests).
    func receive(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var ready: (CheckedContinuation<Data, Error>, Data)?
        if let pending = pendingRead, buffer.count >= pending.count {
            let chunk = Data(buffer.prefix(pending.count))
            buffer.removeFirst(pending.count)
            pendingRead = nil
            ready = (pending.continuation, chunk)
        }
        lock.unlock()
        if let (continuation, chunk) = ready { continuation.resume(returning: chunk) }
    }

    func close() {
        closeLocal()
        peer?.closeLocal()
    }

    /// Marks the peer's end as finished: reads drain the buffer, then fail.
    func closeLocal() {
        lock.lock()
        isClosed = true
        let pending = pendingRead
        pendingRead = nil
        lock.unlock()
        pending?.continuation.resume(throwing: TransportError.closed)
    }
}
