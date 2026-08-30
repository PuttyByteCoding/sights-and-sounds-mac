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

    /// Per-library import-extension overrides. nil = inherit the
    /// app-wide lists; a value REPLACES them (dropping extensions
    /// matters as much as adding). In the library file, so expectations
    /// about the library's content travel with it.
    public var videoExtensionsOverride: [String]?
    public var audioExtensionsOverride: [String]?

    /// The import window's assignment boxes, as JSON. Per library
    /// because the vocabulary is: a Concerts library stages Band and
    /// Venue, a Learning library stages Course.
    public var importBoxes: String?

    public init(
        libraryID: UUID = UUID(), name: String, createdAt: Date = Date(),
        videoExtensionsOverride: [String]? = nil,
        audioExtensionsOverride: [String]? = nil,
        importBoxes: String? = nil
    ) {
        self.id = 1
        self.libraryID = libraryID
        self.name = name
        self.createdAt = createdAt
        self.videoExtensionsOverride = videoExtensionsOverride
        self.audioExtensionsOverride = audioExtensionsOverride
        self.importBoxes = importBoxes
    }

    /// The effective import sets for this library.
    public func effectiveVideoExtensions(appWide: [String]) -> Set<String> {
        Set((videoExtensionsOverride ?? appWide).map { $0.lowercased() })
    }

    public func effectiveAudioExtensions(appWide: [String]) -> Set<String> {
        Set((audioExtensionsOverride ?? appWide).map { $0.lowercased() })
    }
}
