import Foundation
import GRDB

/// One string a reader found, with where it came from.
public struct AnalysisSourceText: Equatable, Sendable {
    public let readerID: String
    /// The key the text sat under, when the source has keys — an embedded
    /// metadata field name. Sidecar lines and paths have none.
    public let key: String?
    public let text: String
    /// OCR only: the moment the text was read, for the evidence still.
    public let timeSeconds: Double?

    public init(readerID: String, key: String?, text: String, timeSeconds: Double? = nil) {
        self.readerID = readerID
        self.key = key
        self.text = text
        self.timeSeconds = timeSeconds
    }
}

/// A place metadata about one video might live.
///
/// **Registered as data, never a switch** — the same contract as
/// `SubParser`, and for the same reason: the future web-page reader and
/// JSON-schema matcher are new registrations, not rewrites. A reader only
/// GATHERS strings; it never parses them (the recursive hub does) and
/// never judges them (the rules do).
public protocol AnalysisReader: Sendable {
    var id: String { get }
    var displayName: String { get }
    /// `fileURL` is the resolved media file, nil while the source is
    /// offline. A reader that needs the disk returns [] then — offline
    /// must degrade to "less evidence", never an error.
    func read(
        item: MediaItem, fileURL: URL?, library: LibraryDatabase
    ) throws -> [AnalysisSourceText]
}

// MARK: - Embedded metadata

/// The swept ffprobe pairs. The sweep stays a sweep (ffprobe is the one
/// genuinely slow read); this reader only queries what it stored.
public struct EmbeddedMetadataReader: AnalysisReader {
    public let id = "embeddedMetadata"
    public let displayName = "Embedded metadata"

    public init() {}

    public func read(
        item: MediaItem, fileURL: URL?, library: LibraryDatabase
    ) throws -> [AnalysisSourceText] {
        try library.writer.read { db in
            try EmbeddedMetadataPair
                .filter(sql: "mediaItemID = ?", arguments: [item.id])
                .fetchAll(db)
        }.map { AnalysisSourceText(readerID: id, key: $0.key, text: $0.value) }
    }
}

// MARK: - Path

/// The item's path, as ONE string. Splitting it is parsing, and parsing
/// belongs to the hub — the path sub-parser splits it there, and each
/// directory name loops back in as text in its own right.
public struct PathAnalysisReader: AnalysisReader {
    public let id = "path"
    public let displayName = "File path"

    public init() {}

    public func read(
        item: MediaItem, fileURL: URL?, library: LibraryDatabase
    ) throws -> [AnalysisSourceText] {
        [AnalysisSourceText(readerID: id, key: nil, text: item.relativePath)]
    }
}

// MARK: - On-screen text

public struct OcrAnalysisReader: AnalysisReader {
    public let id = "onScreen"
    public let displayName = "On-screen text"

    public init() {}

    public func read(
        item: MediaItem, fileURL: URL?, library: LibraryDatabase
    ) throws -> [AnalysisSourceText] {
        try library.writer.read { db in
            try OcrTextLine
                .filter(sql: "mediaItemID = ?", arguments: [item.id])
                .order(sql: "timeSeconds")
                .fetchAll(db)
        }.map { AnalysisSourceText(readerID: id, key: nil, text: $0.text, timeSeconds: $0.timeSeconds) }
    }
}

// MARK: - Sidecars

/// Shared plumbing: every `.ext` file in the video's folder. Folder-level
/// on purpose — "some folders with concerts have a text file about the
/// show" — which also covers the same-basename convention for free, since
/// a same-name sidecar lives in the same folder.
enum SidecarFiles {
    /// Files above this size are skipped, not truncated: a 100 MB "txt"
    /// is not show notes, and half a JSON document parses as nothing.
    static let maxBytes = 512 * 1024

    static func contents(besideFile fileURL: URL?, extension ext: String) -> [(name: String, text: String)] {
        guard let folder = fileURL?.deletingLastPathComponent() else { return [] }
        let listing = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles])) ?? []
        return listing
            .filter { $0.pathExtension.lowercased() == ext }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size <= maxBytes else { return nil }
                guard let data = try? Data(contentsOf: url) else { return nil }
                // UTF-8 first; Latin-1 second because it cannot fail and
                // old scene-release notes are full of it. Losing accents
                // beats losing the file.
                let text = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1)
                guard let text, !text.isEmpty else { return nil }
                return (url.lastPathComponent, text)
            }
    }
}

/// Unstructured show notes: every `.txt` beside the video, line by line.
/// Lines are the unit because "tapper: Mike Jones" patterns are lines,
/// and the rules that strip such prefixes are authored against lines.
public struct SidecarTextReader: AnalysisReader {
    public let id = "sidecarText"
    public let displayName = "Text files"

    public init() {}

    public func read(
        item: MediaItem, fileURL: URL?, library: LibraryDatabase
    ) throws -> [AnalysisSourceText] {
        SidecarFiles.contents(besideFile: fileURL, extension: "txt").flatMap { file in
            var seen = Set<String>()
            return file.text.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
                .map { AnalysisSourceText(readerID: id, key: nil, text: $0) }
        }
    }
}

/// Structured sidecars: every `.json` beside the video, whole — the hub's
/// JSON sub-parser explodes it into leaves with their keys, which is
/// what lets a `keyEquals("taper")` rule fire on a value inside the file.
public struct SidecarJsonReader: AnalysisReader {
    public let id = "sidecarJson"
    public let displayName = "JSON files"

    public init() {}

    public func read(
        item: MediaItem, fileURL: URL?, library: LibraryDatabase
    ) throws -> [AnalysisSourceText] {
        SidecarFiles.contents(besideFile: fileURL, extension: "json").map {
            AnalysisSourceText(readerID: id, key: nil, text: $0.text)
        }
    }
}
