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
/// by nature, and copied log text is private data like any other. For
/// the same reason the message goes to the SYSTEM log as private: the
/// unified log persists and travels in sysdiagnoses, and `.public` put
/// every path it was given in there readable by anyone running
/// `log show`. Console shows it redacted unless a debugger is attached;
/// the Log window and the optional log file keep the full text.
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
        case .debug: logger.debug("\(message, privacy: .private)")
        case .info: logger.info("\(message, privacy: .private)")
        case .warning: logger.warning("\(message, privacy: .private)")
        case .error: logger.error("\(message, privacy: .private)")
        }
        appendToFileIfConfigured(entry)
    }

    /// Daily file (`sas-YYYY-MM-DD.log`) in the settings-chosen log
    /// directory, when one is set. Best-effort; the ring buffer and
    /// os.Logger remain the primary record.
    ///
    /// Written on a serial queue of its own: it used to open and close a
    /// file handle for every line, under the buffer's lock, on whichever
    /// thread logged — often the main one.
    private func appendToFileIfConfigured(_ entry: LogEntry) {
        lock.lock()
        let directory = fileDirectory
        lock.unlock()
        guard let directory else { return }
        fileQueue.async { [dayFormatter] in
            Self.append(entry, to: directory, dayFormatter: dayFormatter)
        }
    }

    /// Where the daily file goes, or nil for none. The settings store
    /// tells the log; the log never asks the store. Asking is how a
    /// settings file that would not decode crashed every launch: the
    /// store logged the problem while it was still being created, and
    /// the log then asked for the store being created.
    private var fileDirectory: String?

    func setFileDirectory(_ path: String?) {
        lock.lock()
        fileDirectory = path
        lock.unlock()
    }

    private let fileQueue = DispatchQueue(label: "com.puttybyte.sightsandsounds.log-file", qos: .utility)
    private let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// Wait for queued file writes — for tests that read the file.
    func flushFileForTesting() { fileQueue.sync {} }

    /// Only ever called on `fileQueue`, one line at a time.
    private static func append(_ entry: LogEntry, to directory: String, dayFormatter: DateFormatter) {
        let url = URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent("sas-\(dayFormatter.string(from: entry.date)).log")
        let line = "\(entry.date.ISO8601Format()) [\(entry.level.label)] \(entry.category): \(entry.message)\n"
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
