import Foundation
import GRDB

/// What a library contained the last time it was closed.
///
/// The library picker shows counts, sizes and vocabulary size per row. It
/// cannot compute them: rendering three rows would mean opening three
/// library files and stat-ing every source root at launch — including the
/// unplugged drives, which is the slow case, and exactly what
/// `LibraryPropertiesView`'s "must never beachball on a big library"
/// comment exists to avoid.
///
/// So the registry caches this. Everything here is a fact about the
/// library FILE, which cannot change while the library is shut. Anything
/// that can — most of all whether a source's drive is plugged in — is
/// deliberately absent: the picker shows that only for a library that is
/// currently open, whose handle is already live and can be asked.
public struct LibrarySummary: Codable, Equatable, Sendable {
    public var itemCount: Int
    /// Top-level items only. An embedded clip's bytes live inside its
    /// parent's file, so counting both would double them.
    public var totalBytes: Int64
    public var sourceCount: Int
    public var categoryCount: Int
    public var tagCount: Int
    /// When these counts were taken — the picker says "as of each
    /// library's last close", and this is what makes that claim true.
    public var capturedAt: Date

    public init(
        itemCount: Int,
        totalBytes: Int64,
        sourceCount: Int,
        categoryCount: Int,
        tagCount: Int,
        capturedAt: Date = Date()
    ) {
        self.itemCount = itemCount
        self.totalBytes = totalBytes
        self.sourceCount = sourceCount
        self.categoryCount = categoryCount
        self.tagCount = tagCount
        self.capturedAt = capturedAt
    }
}

extension LibraryDatabase {
    /// Count this library for the registry's cache.
    ///
    /// Five aggregates in one read, off whatever actor the caller is on —
    /// never call it from the main actor on a large library. Counts are
    /// cheap (indexed), the `SUM(fileSize)` is a scan of one column.
    public func summary(at date: Date = Date()) throws -> LibrarySummary {
        try writer.read { db in
            func count(_ sql: String) throws -> Int {
                try Int.fetchOne(db, sql: sql) ?? 0
            }
            return LibrarySummary(
                itemCount: try count(
                    "SELECT COUNT(*) FROM mediaItem WHERE parentMediaItemID IS NULL"),
                totalBytes: try Int64.fetchOne(
                    db,
                    sql: "SELECT COALESCE(SUM(fileSize), 0) FROM mediaItem WHERE parentMediaItemID IS NULL") ?? 0,
                sourceCount: try count("SELECT COUNT(*) FROM source"),
                categoryCount: try count("SELECT COUNT(*) FROM tagCategory"),
                tagCount: try count("SELECT COUNT(*) FROM tag"),
                capturedAt: date)
        }
    }
}
