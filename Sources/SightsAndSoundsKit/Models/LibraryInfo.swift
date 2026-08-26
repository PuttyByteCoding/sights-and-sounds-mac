import Foundation
import GRDB

/// The library's own identity, stored inside its file — one row, ever.
/// The app-level registry (`AppDatabase`) caches this and reconciles by
/// `libraryID` when a file moves, so renaming or relocating a library
/// file never orphans its registry entry.
public struct LibraryInfo: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "libraryInfo"

    /// Always 1 — the schema CHECK-constrains this table to a single row.
    public var id: Int64
    public var libraryID: UUID
    public var name: String
    public var createdAt: Date

    public init(libraryID: UUID = UUID(), name: String, createdAt: Date = Date()) {
        self.id = 1
        self.libraryID = libraryID
        self.name = name
        self.createdAt = createdAt
    }
}
