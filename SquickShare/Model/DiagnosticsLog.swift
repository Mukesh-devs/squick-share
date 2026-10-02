import AppKit
import Foundation
import QuickShareCore

/// Ring buffer of protocol diagnostics for "Copy diagnostic log".
/// Entries come from QuickShareCore and never contain file contents, file names, paths or keys.
final class DiagnosticsLog: @unchecked Sendable {
    static let capacity = 4000
    private let lock = NSLock()
    private var entries: [Diagnostics.Entry] = []

    #if DEBUG
    /// Debug builds mirror the log to a file in the app's temporary folder for automated checks.
    private lazy var debugFile: FileHandle? = {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("diagnostics.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return try? FileHandle(forWritingTo: url)
    }()
    #endif

    func append(_ entry: Diagnostics.Entry) {
        lock.lock()
        entries.append(entry)
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
        #if DEBUG
        debugFile?.write(Data("\(entry.date) [\(entry.category)] \(entry.message)\n".utf8))
        #endif
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    func clear() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }

    /// The log as text, preceded by a header describing this build and its settings.
    func export(header: [String: String]) -> String {
        lock.lock()
        let snapshot = entries
        lock.unlock()
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        var lines = ["squick-share diagnostic log", String(repeating: "=", count: 27)]
        lines += header.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
        lines.append("")
        lines += snapshot.map { entry in
            let level = switch entry.level { case .debug: "D"; case .info: "I"; case .error: "E" }
            return "\(formatter.string(from: entry.date)) \(level) [\(entry.category)] \(entry.message)"
        }
        return lines.joined(separator: "\n")
    }
}
