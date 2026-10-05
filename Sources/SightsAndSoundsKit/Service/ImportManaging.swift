import Foundation
import GRDB

/// Import: what is under a source's folder that the library does not
/// have, and what the window keeps about importing. The folders are
/// read where they are; a window on another Mac is told what was found.
/// The import itself is a job (`JobRequest.importFiles`).
public protocol ImportManaging: Sendable {
    /// What the window shows before anything is scanned.
    func importOverview() async throws -> ImportOverview

    /// Every media file under a source's folder, against what the
    /// library already has. Nothing is written.
    func scanSource(sourceID: UUID) async throws -> ScanOutcome

    /// What one file under a source measures — its length, its size on
    /// screen — before it is imported. Empty for a file that cannot be
    /// read.
    func probeFile(sourceID: UUID, relativePath: String) async throws -> ProbeResult

    /// The boxes the library's import window stages values in.
    func importBoxes() async throws -> [ImportBox]
    func setImportBoxes(_ boxes: [ImportBox]) async throws

    /// Take files with this extension as video from now on, in this
    /// library only.
    func enableExtension(_ fileExtension: String) async throws
}

public struct ImportOverview: Codable, Equatable, Sendable {
    /// Items in the library, per source.
    public var itemCounts: [UUID: Int] = [:]
    /// Whether each source's folder can be reached now.
    public var online: [UUID: Bool] = [:]
    /// The last few imports, newest first.
    public var history: [JobRecord] = []
    /// The extensions in force for this library.
    public var videoExtensions: [String] = []
    public var audioExtensions: [String] = []
    /// The library has lists of its own, in place of the app's.
    public var hasOverride = false

    public init() {}
}

// MARK: - On this Mac

extension LocalLibraryService {
    public func importOverview() async throws -> ImportOverview {
        let appSettings = AppSettingsStore.shared.current
        var overview = try await library.writer.read { db -> ImportOverview in
            var result = ImportOverview()
            let rows = try Row.fetchAll(db, sql: "SELECT sourceID, COUNT(*) AS c FROM mediaItem GROUP BY sourceID")
            for row in rows {
                if let id = row["sourceID"] as UUID? { result.itemCounts[id] = row["c"] }
            }
            result.history = try JobRecord
                .filter(sql: "kind = ?", arguments: [ImportJob.kind])
                .order(sql: "createdAt DESC")
                .limit(12)
                .fetchAll(db)
            let info = try LibraryInfo.fetchOne(db)
            result.hasOverride = info?.videoExtensionsOverride != nil || info?.audioExtensionsOverride != nil
            result.videoExtensions = (info?.effectiveVideoExtensions(appWide: appSettings.videoExtensions)
                ?? Set(appSettings.videoExtensions.map { $0.lowercased() })).sorted()
            result.audioExtensions = (info?.effectiveAudioExtensions(appWide: appSettings.audioExtensions)
                ?? Set(appSettings.audioExtensions.map { $0.lowercased() })).sorted()
            return result
        }
        let sources = try await library.writer.read { try Source.fetchAll($0) }
        for source in sources {
            overview.online[source.id] = source.isOnline(using: fileAccess)
        }
        return overview
    }

    public func scanSource(sourceID: UUID) async throws -> ScanOutcome {
        try await MediaScanner.scan(source: try await source(sourceID), library: library, fileAccess: fileAccess)
    }

    public func probeFile(sourceID: UUID, relativePath: String) async throws -> ProbeResult {
        let root = URL(fileURLWithPath: try await source(sourceID).rootPath, isDirectory: true)
        let file = root.appendingPathComponent(relativePath)
        // Only a file of the source: not one a link in it leads out to.
        guard MediaPath.isReallyInside(root, file: file) else { return ProbeResult() }
        return await MediaProbe.probe(url: file)
    }

    public func importBoxes() async throws -> [ImportBox] {
        try library.importBoxes()
    }

    public func setImportBoxes(_ boxes: [ImportBox]) async throws {
        try library.setImportBoxes(boxes)
    }

    public func enableExtension(_ fileExtension: String) async throws {
        let settings = AppSettingsStore.shared.current
        let info = try library.info()
        let video = info?.effectiveVideoExtensions(appWide: settings.videoExtensions)
            ?? Set(settings.videoExtensions)
        let audio = info?.effectiveAudioExtensions(appWide: settings.audioExtensions)
            ?? Set(settings.audioExtensions)
        // Video by default: an unknown container is far more often
        // video, and the lists are visible in Settings either way.
        try library.setExtensionOverrides(
            video: video.union([fileExtension]).sorted(), audio: audio.sorted())
    }

    private func source(_ id: UUID) async throws -> Source {
        guard let source = try await library.writer.read({ try Source.fetchOne($0, key: id) }) else {
            throw ServiceError.noSuchSource
        }
        return source
    }
}
