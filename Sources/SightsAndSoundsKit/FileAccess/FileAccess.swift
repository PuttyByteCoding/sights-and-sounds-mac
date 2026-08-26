import Foundation

/// The one narrow interface between the app and the file system.
///
/// **Rule: no code outside this file touches `FileManager`, `FileHandle`, or
/// path-based I/O directly.** The app ships unsandboxed for now (locked
/// decision 04), but sandboxing later means moving every file access onto
/// security-scoped bookmarks — keeping all access behind this protocol makes
/// that a change to one conformance instead of a hunt through the codebase.
///
/// Deliberately small. It grows only when a phase needs a new operation,
/// and each addition is reviewed against "could a sandboxed implementation
/// provide this?"
public protocol FileAccess: Sendable {
    /// Whether the location exists and is reachable right now. Drives the
    /// per-source online/offline state (offline is observed, never stored).
    func isReachable(_ url: URL) -> Bool

    /// Immediate children of a directory.
    func contentsOfDirectory(at url: URL) throws -> [URL]

    /// Every regular file under a directory, recursively, hidden files
    /// skipped. Order is unspecified; callers sort.
    func allFiles(under url: URL) throws -> [URL]

    /// Size of the file in bytes.
    func fileSize(at url: URL) throws -> Int64

    /// Stream a file's contents in chunks (hashing, checksumming). The
    /// whole file never sits in memory.
    func readFile(at url: URL, chunk: (Data) throws -> Void) throws

    /// Move a file, creating intermediate directories for the destination.
    /// Never overwrites — the caller resolves collisions first.
    func moveFile(at url: URL, to destination: URL) throws

    /// Permanently remove a file. The caller owns confirmation.
    func removeFile(at url: URL) throws
}

/// The real implementation over `FileManager`.
public struct LiveFileAccess: FileAccess {
    public init() {}

    public func isReachable(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public func contentsOfDirectory(at url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    }

    public func allFiles(under url: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles])
        else { return [] }
        var files: [URL] = []
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true { files.append(fileURL) }
        }
        return files
    }

    public func fileSize(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }

    public func readFile(at url: URL, chunk: (Data) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty {
            try chunk(data)
        }
    }

    public func moveFile(at url: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: destination)
    }

    public func removeFile(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}
