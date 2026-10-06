import Foundation
import GRDB

/// One time this app rewrote an item's file: when, by what, and whether the
/// streams were re-encoded or only copied. Media Signal reads a file's
/// encoder stamp as proof of a transcode; every ffmpeg path here leaves
/// one ("Lavf…"), so a file this app only copied read as re-encoded. The
/// history says which stamps are ours — and what was actually done.
public struct FileRewrite: Codable, Equatable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "fileRewrite"

    public enum Operation: String, Codable, Sendable, CaseIterable {
        case tagWrite, tagRestore, remux, repair
        /// A file swap that had landed when the app died, settled on relaunch.
        case swapRecovered
        /// Not this app's doing: the file changed outside it, and Maintenance
        /// accepted the size on disk.
        case changedOutside
        /// A new file this app made from others; the note names them.
        case encoded, joined, blocksRemoved

        var phrase: String {
            switch self {
            case .tagWrite: "tags written"
            case .tagRestore: "tags restored"
            case .remux: "remuxed"
            case .repair: "repaired"
            case .swapRecovered: "file swap settled after relaunch"
            case .changedOutside: "changed outside the app"
            case .encoded: "encoded here"
            case .joined: "joined here from parts"
            case .blocksRemoved: "made here with blocks cut out"
            }
        }
    }

    public var id: UUID
    public var mediaItemID: UUID
    public var happenedAt: Date
    public var operation: Operation
    /// What did the writing: "ffmpeg", "AtomicParsley", "metaflac",
    /// "AVFoundation", or nil when unknown.
    public var tool: String?
    /// The streams themselves were re-encoded, not copied.
    public var reencoded: Bool
    public var note: String?

    public init(
        id: UUID = UUID(), mediaItemID: UUID, happenedAt: Date = Date(), operation: Operation,
        tool: String? = nil, reencoded: Bool, note: String? = nil
    ) {
        self.id = id
        self.mediaItemID = mediaItemID
        self.happenedAt = happenedAt
        self.operation = operation
        self.tool = tool
        self.reencoded = reencoded
        self.note = note
    }

    /// "repaired · 2 Oct 2026 · ffmpeg, re-encoded (Salvage by re-encoding)"
    public var summary: String {
        var parts = [operation.phrase, happenedAt.formatted(date: .abbreviated, time: .omitted)]
        var how: [String] = []
        if let tool { how.append(tool) }
        how.append(reencoded ? "re-encoded" : "streams copied")
        parts.append(how.joined(separator: ", ") + (note.map { " (\($0))" } ?? ""))
        return parts.joined(separator: " · ")
    }

    /// Whether this rewrite leaves ffmpeg's muxer stamp on the file.
    var stampsLavf: Bool { tool?.lowercased().contains("ffmpeg") == true }
}

extension LibraryDatabase {
    /// Record a rewrite, in the same write that forgets the old readings.
    static func recordRewrite(
        _ itemID: UUID, _ operation: FileRewrite.Operation, tool: String?, reencoded: Bool,
        note: String? = nil, in db: Database
    ) throws {
        try FileRewrite(mediaItemID: itemID, operation: operation, tool: tool, reencoded: reencoded, note: note)
            .insert(db)
    }

    /// An item's rewrites, newest first. Tag writes made before this
    /// history existed are read off their run rows, so a file written
    /// then is not called a transcode now.
    public func rewrites(of itemID: UUID) throws -> [FileRewrite] {
        try writer.read { db in try Self.rewrites(of: itemID, in: db) }
    }

    static func rewrites(of itemID: UUID, in db: Database) throws -> [FileRewrite] {
        // Newest first; two in one write share a timestamp, so insertion
        // order breaks the tie.
        let recorded = try FileRewrite.fetchAll(
            db, sql: "SELECT * FROM fileRewrite WHERE mediaItemID = ? ORDER BY happenedAt DESC, rowid DESC",
            arguments: [itemID])
        let earliestRecorded = recorded.map(\.happenedAt).min() ?? .distantFuture
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT run.startedAt AS at, file.usedRemuxFallback AS fallback \
            FROM tagWriteRunFile file JOIN tagWriteRun run ON run.id = file.tagWriteRunID \
            WHERE file.mediaItemID = ? AND file.status = ? AND run.startedAt < ?
            """,
            arguments: [itemID, WriteRunFileStatus.written.rawValue, earliestRecorded])
        let earlier = rows.map { row in
            FileRewrite(
                mediaItemID: itemID, happenedAt: row["at"], operation: .tagWrite,
                tool: (row["fallback"] as Bool) ? "ffmpeg" : nil, reencoded: false)
        }
        return recorded + earlier.sorted { $0.happenedAt > $1.happenedAt }
    }
}
