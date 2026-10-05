import Foundation
import GRDB
import Testing

@testable import SightsAndSoundsKit

/// The Maintenance window's reads and the few things it does, as asked
/// of the library's service. The library is a file here, since a backup
/// is a copy of one; backups go to the test run's own folder.
@Suite struct MaintenanceManagingTests {
    struct Fixture {
        let root: URL
        let library: LibraryDatabase
        let service: LocalLibraryService
        let a: MediaItem
        let b: MediaItem
        /// On a source that is not mounted.
        let away: MediaItem

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("sas-maintenance-\(UUID().uuidString)", isDirectory: true)
            let media = root.appendingPathComponent("media", isDirectory: true)
            try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
            try Data(repeating: 1, count: 1_000).write(to: media.appendingPathComponent("a.mp4"))
            try Data(repeating: 2, count: 2_000).write(to: media.appendingPathComponent("b.mp4"))
            library = try LibraryDatabase.open(at: root.appendingPathComponent("Maint.sqlite"))
            try library.ensureInfo(name: "Maint")
            service = LocalLibraryService(library: library, fileAccess: LiveFileAccess(discarding: .permanently))
            let source = Source(name: "Here", rootPath: media.path)
            let elsewhere = Source(name: "Unplugged", rootPath: media.path + "-not-mounted")
            // Recorded smaller than it is on disk.
            a = MediaItem(sourceID: source.id, kind: .video, relativePath: "a.mp4", fileSize: 10)
            b = MediaItem(sourceID: source.id, kind: .video, relativePath: "b.mp4", fileSize: 2_000)
            away = MediaItem(sourceID: elsewhere.id, kind: .video, relativePath: "c.mp4", fileSize: 5)
            try library.writer.write { [a, b, away] db in
                try source.insert(db)
                try elsewhere.insert(db)
                for row in [a, b, away] { try row.insert(db) }
            }
        }

        func tearDown() {
            try? library.close()
            try? FileManager.default.removeItem(at: root)
        }

        func item(_ id: UUID) throws -> MediaItem? { try library.writer.read { try MediaItem.fetchOne($0, key: id) } }
    }

    @Test func theSnapshotIsOneAnswerAndListsBackupsOnlyWhenAsked() async throws {
        let f = try Fixture()
        defer { f.tearDown() }
        let plain = try await f.service.maintenanceSnapshot(includingBackups: false)
        #expect(plain.findings.isEmpty && plain.runs.isEmpty)
        #expect(plain.backups == nil, "the backups were opened though nobody asked")
        #expect(plain.stagedCount == 0 && plain.reclaimableBytes == 0)

        #expect(try await f.service.setStaging(.toDelete, on: true, itemIDs: [f.b.id]).isEmpty)
        let after = try await f.service.maintenanceSnapshot(includingBackups: false)
        #expect(after.stagedCount == 1)
        #expect(after.reclaimableBytes == 2_000)
        // The snapshot crosses to another Mac as it is.
        let sent = try JSONDecoder().decode(MaintenanceSnapshot.self, from: JSONEncoder().encode(after))
        #expect(sent == after)
    }

    @Test(.timeLimit(.minutes(1)))
    func aBackupIsMadeAndThenListed() async throws {
        let f = try Fixture()
        defer { f.tearDown() }
        let backup = try await f.service.backUp()
        defer { try? FileManager.default.removeItem(at: backup) }
        #expect(backup.pathExtension == "sqlite")
        #expect(FileManager.default.fileExists(atPath: backup.path))
        #expect(backup.path.hasPrefix(LibraryDatabase.defaultBackupDirectory().path), "not in the backup folder")
        let listed = try #require(try await f.service.maintenanceSnapshot(includingBackups: true).backups)
        let mine = try #require(listed.first { $0.url.lastPathComponent == backup.lastPathComponent })
        #expect(mine.libraryName == "Maint")
        #expect(mine.bytes > 0)
        let sent = try JSONDecoder().decode(LibraryDatabase.BackupFile.self, from: JSONEncoder().encode(mine))
        #expect(sent == mine)
    }

    @Test func theSizeOnDiskIsAcceptedAsTheItemsSize() async throws {
        let f = try Fixture()
        defer { f.tearDown() }
        try await f.service.acceptDiskSize(itemID: f.a.id)
        #expect(try f.item(f.a.id)?.fileSize == 1_000)
        #expect(try f.item(f.b.id)?.fileSize == 2_000)
    }

    /// With no items named the preview is of every item that is a file
    /// of its own — a segment is a part of its video's file. An item
    /// whose drive is unplugged is listed as skipped, with why.
    @Test(.timeLimit(.minutes(1)))
    func aPreviewOfTheWholeLibraryLeavesSegmentsOut() async throws {
        let f = try Fixture()
        defer { f.tearDown() }
        _ = try f.library.createEmbeddedClip(
            parentID: f.away.id, name: "Song", startSeconds: 1, endSeconds: 2, role: .song)

        let one = try await f.service.previewWriteback(itemIDs: [f.away.id])
        #expect(one.files.map(\.itemID) == [f.away.id])
        #expect(one.files.first?.skipReason != nil, "an unplugged drive's file was not skipped")
        #expect(one.writableFiles.isEmpty)

        let whole = try await f.service.previewWriteback(itemIDs: nil)
        #expect(Set(whole.files.map(\.itemID)) == [f.a.id, f.b.id, f.away.id])
        let sent = try JSONDecoder().decode(WritebackPreview.self, from: JSONEncoder().encode(one))
        #expect(sent == one)
    }

    /// Maintenance purges everything marked, where Review purges what is
    /// ticked: nil is every marked item, and nothing that is not marked.
    @Test func purgingWithNoItemsNamedTakesEverythingMarkedAndNothingElse() async throws {
        let f = try Fixture()
        defer { f.tearDown() }
        #expect(try await f.service.setStaging(.toDelete, on: true, itemIDs: [f.a.id, f.b.id]).isEmpty)
        let outcome = try await f.service.purgeMarked(itemIDs: nil)
        #expect(outcome.rowsDeleted == 2 && outcome.filesDeleted == 2)
        #expect(try f.item(f.a.id) == nil && f.item(f.b.id) == nil)
        #expect(try f.item(f.away.id) != nil)
        #expect(try await f.service.maintenanceSnapshot(includingBackups: false).stagedCount == 0)
    }
}
