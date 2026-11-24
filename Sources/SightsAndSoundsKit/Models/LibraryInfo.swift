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

    /// Which characters `separatorsToSpaces` converts. Library-wide on
    /// purpose: a category chooses WHETHER to apply separators, never
    /// which — nobody wants a hyphen to split Band names but not Venue
    /// names.
    public var separatorCharacters: String

    /// The search-string recipe, as JSON (spec 17). Per library because
    /// its parts name categories.
    public var searchRecipe: String?

    /// Whether this library keeps a content hash (MD5) of every file.
    /// Off by default: hashing reads each file end to end, which on a
    /// network volume is the costliest thing an import queues, and a
    /// library whose files are re-encoded before import gains nothing
    /// from it. On for a library of files that cannot be replaced (Home
    /// Videos), where the stored hash is what Verify Integrity checks
    /// the file against later. Turning it off keeps the hashes already
    /// stored.
    public var hashesFiles: Bool

    public init(
        libraryID: UUID = UUID(), name: String, createdAt: Date = Date(),
        videoExtensionsOverride: [String]? = nil,
        audioExtensionsOverride: [String]? = nil,
        importBoxes: String? = nil,
        separatorCharacters: String = "-._",
        searchRecipe: String? = nil,
        hashesFiles: Bool = false
    ) {
        self.id = 1
        self.libraryID = libraryID
        self.name = name
        self.createdAt = createdAt
        self.videoExtensionsOverride = videoExtensionsOverride
        self.audioExtensionsOverride = audioExtensionsOverride
        self.importBoxes = importBoxes
        self.separatorCharacters = separatorCharacters
        self.searchRecipe = searchRecipe
        self.hashesFiles = hashesFiles
    }

    /// The effective import sets for this library.
    public func effectiveVideoExtensions(appWide: [String]) -> Set<String> {
        Set((videoExtensionsOverride ?? appWide).map { $0.lowercased() })
    }

    public func effectiveAudioExtensions(appWide: [String]) -> Set<String> {
        Set((audioExtensionsOverride ?? appWide).map { $0.lowercased() })
    }
}
