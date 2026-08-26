import Foundation
import os

public enum LogLevel: Int, Codable, Sendable, CaseIterable, Comparable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .debug: "debug"
        case .info: "info"
        case .warning: "warning"
        case .error: "error"
        }
    }
}

public struct LogEntry: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let date: Date
    public let level: LogLevel
    public let category: String
    public let message: String
}

/// The unified in-app log: everything flows to `os.Logger` (visible in
/// Console.app under subsystem `com.puttybyte.sightsandsounds`) AND into
/// an in-memory ring buffer the Log window renders — no OSLogStore
/// entitlement quirks involved.
///
/// Entries may contain real file and tag names: the window is local-only
/// by nature, and copied log text is private data like any other.
public final class AppLog: @unchecked Sendable {
    public static let shared = AppLog()

    public static let capacity = 2_000

    private let lock = NSLock()
    private var entries: [LogEntry] = []
    private var loggers: [String: Logger] = [:]

    public func log(_ level: LogLevel, _ category: String, _ message: String) {
        let entry = LogEntry(
            id: UUID(), date: Date(), level: level, category: category, message: message)
        lock.lock()
        entries.append(entry)
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
        let logger = loggers[category] ?? {
            let created = Logger(subsystem: "com.puttybyte.sightsandsounds", category: category)
            loggers[category] = created
            return created
        }()
        lock.unlock()

        switch level {
        case .debug: logger.debug("\(message, privacy: .public)")
        case .info: logger.info("\(message, privacy: .public)")
        case .warning: logger.warning("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        }
        appendToFileIfConfigured(entry)
    }

    /// Daily file (`sas-YYYY-MM-DD.log`) in the settings-chosen log
    /// directory, when one is set. Best-effort; the ring buffer and
    /// os.Logger remain the primary record.
    private func appendToFileIfConfigured(_ entry: LogEntry) {
        guard let directory = AppSettingsStore.shared.current.logDirectory else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let url = URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent("sas-\(formatter.string(from: entry.date)).log")
        let line = "\(entry.date.ISO8601Format()) [\(entry.level.label)] \(entry.category): \(entry.message)\n"
        lock.lock()
        defer { lock.unlock() }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                try Data(line.utf8).write(to: url)
            } else {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
            }
        } catch {
            // Never recurse into log() from here.
        }
    }

    public func debug(_ category: String, _ message: String) { log(.debug, category, message) }
    public func info(_ category: String, _ message: String) { log(.info, category, message) }
    public func warning(_ category: String, _ message: String) { log(.warning, category, message) }
    public func error(_ category: String, _ message: String) { log(.error, category, message) }

    /// A consistent copy of the buffer, newest last.
    public func snapshot() -> [LogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    /// Distinct categories seen so far, for the filter menu.
    public func categories() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(Set(entries.map(\.category))).sorted()
    }

    /// Test hook.
    public func clear() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }
}
