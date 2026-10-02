import Foundation
import os

/// Protocol-level logging. Messages describe frame types, order, sizes and states only.
/// They never contain file contents, file names, full paths or key material.
public final class Diagnostics: @unchecked Sendable {
    public enum Level: Int, Sendable, Comparable {
        case debug, info, error
        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    public struct Entry: Sendable {
        public let date: Date
        public let level: Level
        public let category: String
        public let message: String
    }

    private let lock = NSLock()
    private var _verbose = false
    private let sink: (@Sendable (Entry) -> Void)?
    private let logger = Logger(subsystem: "squick-share", category: "protocol")

    /// - Parameter sink: receives every entry at or above the current level (debug only when verbose).
    public init(verbose: Bool = false, sink: (@Sendable (Entry) -> Void)? = nil) {
        _verbose = verbose
        self.sink = sink
    }

    public var verbose: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _verbose }
        set { lock.lock(); _verbose = newValue; lock.unlock() }
    }

    public func log(_ level: Level, _ category: String, _ message: @autoclosure () -> String) {
        if level == .debug, !verbose { return }
        let text = message()
        switch level {
        case .debug: logger.debug("[\(category, privacy: .public)] \(text, privacy: .public)")
        case .info: logger.info("[\(category, privacy: .public)] \(text, privacy: .public)")
        case .error: logger.error("[\(category, privacy: .public)] \(text, privacy: .public)")
        }
        sink?(Entry(date: Date(), level: level, category: category, message: text))
    }

    public func debug(_ category: String, _ message: @autoclosure () -> String) { log(.debug, category, message()) }
    public func info(_ category: String, _ message: @autoclosure () -> String) { log(.info, category, message()) }
    public func error(_ category: String, _ message: @autoclosure () -> String) { log(.error, category, message()) }

    /// A diagnostics instance that discards everything.
    public static let silent = Diagnostics()
}
