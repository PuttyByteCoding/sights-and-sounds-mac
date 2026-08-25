import Foundation
import GRDB

/// What kind of media file a row represents. Raw values match the old app's
/// `MediaKind` so the migrator can map by integer value.
public enum MediaKind: Int, Codable, Sendable, CaseIterable {
    case video = 0
    case audio = 1
}

/// The core entity. One row per media file in a library.
///
/// Phase 0 carries only the columns the three-way filter touches; Phase 1
/// brings the full schema (source ownership, probe metadata, per-feature
/// state in side tables — the 48-column lesson from the web app).
public struct MediaItem: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "mediaItem"

    public var id: UUID
    public var kind: MediaKind

    /// Source-relative path, canonical form (see `MediaPath.normalize`).
    public private(set) var relativePath: String
    /// Directory portion of `relativePath`, denormalized so the exact-folder
    /// filter is an indexed SQL equality. Maintained by `setRelativePath` —
    /// the only write path — so it cannot drift.
    public private(set) var folderPath: String
    /// File-name portion of `relativePath`, maintained the same way.
    public private(set) var fileName: String

    // Structural status flags (system-managed, not user tags). Same set the
    // old app exposed to the Status filter.
    public var needsReview: Bool
    public var playbackIssue: Bool
    public var markedForDeletion: Bool
    public var isFavorite: Bool

    // Clip relationship + classification. `parentMediaItemID` non-nil means
    // this row is a named range inside the parent's file. The Status "clip"
    // filter is the umbrella union of all three markers.
    public var parentMediaItemID: UUID?
    public var isClip: Bool
    public var isExportedClip: Bool
    public var isEdited: Bool
    /// True once an embedded clip row has been exported to a standalone file.
    /// Such rows are hidden from every listing surface (they only feed the
    /// parent scrubber's "exported from here" breadcrumb).
    public var clipExported: Bool

    public init(
        id: UUID = UUID(),
        kind: MediaKind,
        relativePath: String,
        needsReview: Bool = true,
        playbackIssue: Bool = false,
        markedForDeletion: Bool = false,
        isFavorite: Bool = false,
        parentMediaItemID: UUID? = nil,
        isClip: Bool = false,
        isExportedClip: Bool = false,
        isEdited: Bool = false,
        clipExported: Bool = false
    ) {
        self.id = id
        self.kind = kind
        let normalized = MediaPath.normalize(relativePath)
        self.relativePath = normalized
        self.folderPath = MediaPath.folder(of: normalized)
        self.fileName = MediaPath.fileName(of: normalized)
        self.needsReview = needsReview
        self.playbackIssue = playbackIssue
        self.markedForDeletion = markedForDeletion
        self.isFavorite = isFavorite
        self.parentMediaItemID = parentMediaItemID
        self.isClip = isClip
        self.isExportedClip = isExportedClip
        self.isEdited = isEdited
        self.clipExported = clipExported
    }

    /// The single mutation path for the path triplet — keeps `folderPath`
    /// and `fileName` in lockstep with `relativePath`.
    public mutating func setRelativePath(_ path: String) {
        let normalized = MediaPath.normalize(path)
        relativePath = normalized
        folderPath = MediaPath.folder(of: normalized)
        fileName = MediaPath.fileName(of: normalized)
    }
}
