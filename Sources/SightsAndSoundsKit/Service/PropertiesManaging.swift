import Foundation
import GRDB

/// Get Info, for a library: what it is, what is in it, how much of it
/// has been hashed, thumbnailed and read, and the few settings it keeps
/// about itself.
public protocol PropertiesManaging: Sendable {
    /// Everything the window shows, as one answer.
    func libraryProperties() async throws -> LibraryProperties

    /// The library's name, in its own identity row.
    func renameLibrary(to name: String) async throws

    /// The characters a file name is split at when it is read for tags.
    func setSeparatorCharacters(_ characters: String) async throws

    /// The extensions this library takes as video and as audio, in
    /// place of the app's own; nil for either goes back to the app's.
    func setExtensionOverrides(video: [String]?, audio: [String]?) async throws
}

public struct LibraryProperties: Codable, Equatable, Sendable {
    public struct SourceLine: Codable, Equatable, Sendable, Identifiable {
        public var id: UUID
        public var name: String
        /// The folder, on the Mac that holds the library.
        public var rootPath: String
        public var enabled: Bool
        public var itemCount: Int
    }

    public var info: LibraryInfo?
    /// Where the library's file is, on the Mac that holds it.
    public var filePath: String?
    public var fileBytes: Int64 = 0
    public var migrations = 0
    public var videoCount = 0
    public var audioCount = 0
    public var songs = 0
    public var clips = 0
    public var exportedClips = 0
    public var mediaBytes: Int64 = 0
    public var sources: [SourceLine] = []
    public var hashed = 0
    public var hashable = 0
    public var thumbnailsOnDisk = 0
    public var thumbnailFailures = 0
    public var fingerprints = 0
    public var ocrItems = 0
    public var pendingDuplicates = 0
    public var categories = 0
    public var tags = 0
    public var fields = 0
    public var jobsLogged = 0
    public var lastBackup: Date?

    public init() {}
}

// MARK: - On this Mac

extension LocalLibraryService {
    public func libraryProperties() async throws -> LibraryProperties {
        var properties = LibraryProperties()
        properties.info = try library.info()
        properties.filePath = library.fileURL?.path
        if let path = properties.filePath {
            properties.fileBytes = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
        }
        properties.migrations = try library.appliedMigrations().count

        let base = properties
        properties = try await library.writer.read { db -> LibraryProperties in
            var filled = base
            func count(_ sql: String) throws -> Int {
                try Int.fetchOne(db, sql: sql) ?? 0
            }
            filled.videoCount = try count("SELECT COUNT(*) FROM mediaItem WHERE kind = 0 AND clipExported = 0")
            filled.audioCount = try count("SELECT COUNT(*) FROM mediaItem WHERE kind = 1 AND clipExported = 0")
            // Songs and clips are one kind of named range now, so
            // Contents says which is which.
            filled.songs = try count(
                "SELECT COUNT(*) FROM mediaItem WHERE segmentRole = 'song' AND clipExported = 0")
            filled.clips = try count(
                "SELECT COUNT(*) FROM mediaItem WHERE segmentRole = 'clip' AND clipExported = 0")
            filled.exportedClips = try count("SELECT COUNT(*) FROM mediaItem WHERE isExportedClip")
            filled.mediaBytes = try Int64.fetchOne(
                db, sql: "SELECT COALESCE(SUM(fileSize), 0) FROM mediaItem WHERE parentMediaItemID IS NULL") ?? 0
            filled.hashed = try count("SELECT COUNT(*) FROM mediaItem WHERE contentHash IS NOT NULL")
            filled.hashable = try count(
                "SELECT COUNT(*) FROM mediaItem WHERE parentMediaItemID IS NULL AND clipExported = 0")
            filled.thumbnailFailures = try count(
                "SELECT COUNT(*) FROM thumbnailState WHERE failureMessage IS NOT NULL")
            filled.fingerprints = try count("SELECT COUNT(*) FROM audioFingerprint")
            filled.ocrItems = try count("SELECT COUNT(DISTINCT mediaItemID) FROM ocrTextLine")
            filled.categories = try count("SELECT COUNT(*) FROM tagCategory")
            filled.tags = try count("SELECT COUNT(*) FROM tag")
            filled.fields = try count("SELECT COUNT(*) FROM fieldDefinition")
            filled.jobsLogged = try count("SELECT COUNT(*) FROM job")
            let sources = try Source.order(sql: "name").fetchAll(db)
            filled.sources = try sources.map { source in
                LibraryProperties.SourceLine(
                    id: source.id, name: source.name, rootPath: source.rootPath, enabled: source.enabled,
                    itemCount: try Int.fetchOne(
                        db, sql: "SELECT COUNT(*) FROM mediaItem WHERE sourceID = ? AND clipExported = 0",
                        arguments: [source.id]) ?? 0)
            }
            return filled
        }

        properties.pendingDuplicates = try library.pendingCandidates().count
        // Last backup comes from the backups on disk — the only place
        // that fact exists.
        properties.lastBackup = LibraryDatabase
            .backups(in: LibraryDatabase.defaultBackupDirectory())
            .first { $0.libraryName == properties.info?.name }?.createdAt
        // Disk state IS the thumbnail truth (the sweep's rule).
        if let info = properties.info {
            let folder = ThumbnailStore.root.appendingPathComponent(info.libraryID.uuidString, isDirectory: true)
            properties.thumbnailsOnDisk = (try? FileManager.default.contentsOfDirectory(atPath: folder.path).count) ?? 0
        }
        return properties
    }

    public func renameLibrary(to name: String) async throws {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw ServiceError.emptyName }
        try await library.writer.write { db in
            try db.execute(sql: "UPDATE libraryInfo SET name = ?", arguments: [name])
        }
    }

    public func setSeparatorCharacters(_ characters: String) async throws {
        try await library.writer.write { db in
            try db.execute(sql: "UPDATE libraryInfo SET separatorCharacters = ?", arguments: [characters])
        }
    }

    public func setExtensionOverrides(video: [String]?, audio: [String]?) async throws {
        try library.setExtensionOverrides(video: video, audio: audio)
    }
}
