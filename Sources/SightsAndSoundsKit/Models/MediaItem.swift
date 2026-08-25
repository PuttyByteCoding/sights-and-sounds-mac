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
/// What lives here vs. in a side table follows one line: **columns the
/// browse filter or grid reads stay on the row; state only one feature
/// reads lives beside that feature** (`contentHashFailure`,
/// `thumbnailState`, `ocrProgress`). The old app's core entity accreted 48
/// columns by ignoring that line.
public struct MediaItem: Codable, Equatable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "mediaItem"

    public var id: UUID
    /// Real ownership — never inferred from a path prefix. Deleting a
    /// source with items is refused by the schema (RESTRICT); removal is
    /// an explicit app operation.
    public var sourceID: UUID
    public var kind: MediaKind

    /// Source-relative path, canonical form (see `MediaPath.normalize`).
    /// Unique within its source.
    public private(set) var relativePath: String
    /// Directory portion of `relativePath`, denormalized so the exact-folder
    /// filter is an indexed SQL equality. Maintained by `setRelativePath` —
    /// the only write path — so it cannot drift.
    public private(set) var folderPath: String
    /// File-name portion of `relativePath`, maintained the same way.
    public private(set) var fileName: String

    // Probe metadata (ffprobe/AVFoundation). Nullable until probed; codecs
    // are raw probe strings, not enums — the old app's codec enum needed a
    // schema change per new codec. Derived classifications (dimension
    // format, aspect label) are computed in code, not stored.
    public var fileSize: Int64
    public var durationSeconds: Double?
    public var width: Int?
    public var height: Int?
    public var videoCodec: String?
    public var audioCodec: String?
    public var pixelFormat: String?
    public var frameRate: Double?
    public var bitrate: Int64?
    public var videoStreamCount: Int?
    public var audioStreamCount: Int?
    public var sampleRate: Int?
    public var bitDepth: Int?
    public var audioChannels: Int?
    /// When the content itself was recorded/created (container metadata),
    /// as opposed to `ingestDate` (when it entered the library).
    public var contentCreatedAt: Date?

    /// Hash of file contents. Named for the role, not the algorithm — the
    /// old `Md5` column made changing algorithms a schema migration.
    /// Duplicate hashes are data for human review, not a constraint
    /// violation, so the index is non-unique.
    public var contentHash: String?

    public var ingestDate: Date
    public var notes: String

    // Progress state. Lives on the media item (decided 2026-08-25): one
    // person's library, and paired devices share the host's state.
    public var watchCount: Int
    public var resumePositionSeconds: Double?
    public var completed: Bool
    public var lastWatchedAt: Date?

    // Structural status flags (system-managed, not user tags). Read by the
    // filter and the grid — that is why they are columns.
    public var needsReview: Bool
    public var playbackIssue: Bool
    public var markedForDeletion: Bool
    public var isFavorite: Bool

    // Clip relationship + classification. `parentMediaItemID` non-nil means
    // this row is a named range inside the parent's file; the range fields
    // drive auto-seek and loop-back in playback. The Status "clip" filter
    // is the umbrella union of the three markers.
    public var parentMediaItemID: UUID?
    public var clipStartSeconds: Double?
    public var clipEndSeconds: Double?
    public var isClip: Bool
    public var isExportedClip: Bool
    public var isEdited: Bool
    /// True once an embedded clip row has been exported to a standalone
    /// file. Such rows are hidden from every listing surface (they only
    /// feed the parent scrubber's "exported from here" breadcrumb).
    public var clipExported: Bool
    /// Soft reference to the standalone item exported from this clip — no
    /// FK on purpose: deleting the export just leaves the breadcrumb
    /// pointing nowhere, exactly the old behavior.
    public var exportedToMediaItemID: UUID?

    public init(
        id: UUID = UUID(),
        sourceID: UUID,
        kind: MediaKind,
        relativePath: String,
        fileSize: Int64 = 0,
        durationSeconds: Double? = nil,
        width: Int? = nil,
        height: Int? = nil,
        videoCodec: String? = nil,
        audioCodec: String? = nil,
        pixelFormat: String? = nil,
        frameRate: Double? = nil,
        bitrate: Int64? = nil,
        videoStreamCount: Int? = nil,
        audioStreamCount: Int? = nil,
        sampleRate: Int? = nil,
        bitDepth: Int? = nil,
        audioChannels: Int? = nil,
        contentCreatedAt: Date? = nil,
        contentHash: String? = nil,
        ingestDate: Date = Date(),
        notes: String = "",
        watchCount: Int = 0,
        resumePositionSeconds: Double? = nil,
        completed: Bool = false,
        lastWatchedAt: Date? = nil,
        needsReview: Bool = true,
        playbackIssue: Bool = false,
        markedForDeletion: Bool = false,
        isFavorite: Bool = false,
        parentMediaItemID: UUID? = nil,
        clipStartSeconds: Double? = nil,
        clipEndSeconds: Double? = nil,
        isClip: Bool = false,
        isExportedClip: Bool = false,
        isEdited: Bool = false,
        clipExported: Bool = false,
        exportedToMediaItemID: UUID? = nil
    ) {
        self.id = id
        self.sourceID = sourceID
        self.kind = kind
        let normalized = MediaPath.normalize(relativePath)
        self.relativePath = normalized
        self.folderPath = MediaPath.folder(of: normalized)
        self.fileName = MediaPath.fileName(of: normalized)
        self.fileSize = fileSize
        self.durationSeconds = durationSeconds
        self.width = width
        self.height = height
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.pixelFormat = pixelFormat
        self.frameRate = frameRate
        self.bitrate = bitrate
        self.videoStreamCount = videoStreamCount
        self.audioStreamCount = audioStreamCount
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.audioChannels = audioChannels
        self.contentCreatedAt = contentCreatedAt
        self.contentHash = contentHash
        self.ingestDate = ingestDate
        self.notes = notes
        self.watchCount = watchCount
        self.resumePositionSeconds = resumePositionSeconds
        self.completed = completed
        self.lastWatchedAt = lastWatchedAt
        self.needsReview = needsReview
        self.playbackIssue = playbackIssue
        self.markedForDeletion = markedForDeletion
        self.isFavorite = isFavorite
        self.parentMediaItemID = parentMediaItemID
        self.clipStartSeconds = clipStartSeconds
        self.clipEndSeconds = clipEndSeconds
        self.isClip = isClip
        self.isExportedClip = isExportedClip
        self.isEdited = isEdited
        self.clipExported = clipExported
        self.exportedToMediaItemID = exportedToMediaItemID
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
