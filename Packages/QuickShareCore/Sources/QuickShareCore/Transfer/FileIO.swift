import Foundation

/// Runs blocking file I/O on a dedicated serial queue, off Swift's cooperative thread pool.
final class BlockingIO: @unchecked Sendable {
    private let queue: DispatchQueue

    init(label: String) {
        queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try work() })
            }
        }
    }
}

/// Streams one received file into a temporary file inside its destination folder,
/// then renames it into place. Memory use is one chunk at a time.
final class IncomingFileWriter: @unchecked Sendable {
    let payloadID: Int64
    let expectedSize: Int64
    let folder: URL
    let name: String
    private let tempURL: URL
    private let handle: FileHandle
    private let io: BlockingIO
    private(set) var written: Int64 = 0
    private var finished = false

    init(payloadID: Int64, expectedSize: Int64, folder: URL, name: String) throws {
        self.payloadID = payloadID
        self.expectedSize = expectedSize
        self.folder = folder
        self.name = name
        tempURL = folder.appendingPathComponent(".squick-share-\(UUID().uuidString).part")
        guard FileManager.default.createFile(atPath: tempURL.path, contents: nil) else {
            throw TransferError.fileAccess("cannot create temporary file")
        }
        handle = try FileHandle(forWritingTo: tempURL)
        io = BlockingIO(label: "squickshare.write.\(payloadID)")
    }

    /// Appends `data`, which must start at the current end of the file.
    func append(_ data: Data, at offset: Int64) async throws {
        guard offset == written else {
            throw TransferError.protocolViolation("chunk offset \(offset), expected \(written)")
        }
        guard written + Int64(data.count) <= expectedSize else {
            throw TransferError.protocolViolation("file payload larger than announced")
        }
        guard !data.isEmpty else { return }
        let handle = self.handle
        do {
            try await io.run { try handle.write(contentsOf: data) }
        } catch {
            throw Self.map(error)
        }
        written += Int64(data.count)
    }

    /// Verifies the size, closes and moves the file to its final, collision-free name.
    func finish() async throws -> URL {
        guard written == expectedSize else {
            throw TransferError.protocolViolation("file ended at \(written) of \(expectedSize) bytes")
        }
        let handle = self.handle, temp = tempURL, folder = self.folder, name = self.name
        let url = try await io.run { () throws -> URL in
            try handle.synchronize()
            try handle.close()
            return try Destination.moveExclusive(temp, to: folder, name: name)
        }
        finished = true
        return url
    }

    /// Deletes the temporary file. Safe to call more than once.
    func discard() {
        guard !finished else { return }
        finished = true
        try? handle.close()
        try? FileManager.default.removeItem(at: tempURL)
    }

    static func map(_ error: Error) -> TransferError {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteOutOfSpaceError { return .diskFull }
        let posix = ns.domain == NSPOSIXErrorDomain ? ns : ns.userInfo[NSUnderlyingErrorKey] as? NSError
        if let posix, posix.domain == NSPOSIXErrorDomain {
            if posix.code == Int(ENOSPC) || posix.code == Int(EDQUOT) { return .diskFull }
            if posix.code == Int(EFBIG) { return .fileTooLarge }   // e.g. a 4 GB limit on FAT32 volumes
        }
        return .fileAccess(ns.localizedDescription)
    }
}

/// Reads a file sequentially in fixed-size chunks.
final class FileChunkReader: @unchecked Sendable {
    private let handle: FileHandle
    private let io = BlockingIO(label: "squickshare.read")

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
    }

    func read(upTo count: Int) async throws -> Data {
        let handle = self.handle
        return try await io.run { try handle.read(upToCount: count) ?? Data() }
    }

    func close() {
        try? handle.close()
    }
}
