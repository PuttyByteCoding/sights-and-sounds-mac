import Foundation
import GRDB
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// Examine is a scoped Media Signal sweep over the selection, so a pilot
/// on a few known files can run ahead of a library sweep that takes days.
@Suite @MainActor struct ExamineSelectionTests {
    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }

    @Test func examineQueuesOneScopedSweepNamingTheParentsOfWhatIsSelected() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Examine")
        // An unreachable root: the sweep has to be queued, but must not
        // find any file to open.
        let source = Source(name: "S", rootPath: "/tmp/sas-examine-\(UUID().uuidString)")
        let video = MediaItem(sourceID: source.id, kind: .video, relativePath: "a.mp4", needsReview: false)
        var clip = MediaItem(sourceID: source.id, kind: .video, relativePath: "a.mp4", needsReview: false)
        clip.parentMediaItemID = video.id
        clip.clipStartSeconds = 1
        clip.clipEndSeconds = 2
        let other = MediaItem(sourceID: source.id, kind: .video, relativePath: "b.mp4", needsReview: false)
        let segment = clip
        try await library.writer.write { db in
            try source.insert(db)
            try video.insert(db)
            try segment.insert(db)
            try other.insert(db)
        }
        // A runner with no job types registered: the row is queued and
        // then fails as unknown, which is fine; the row is what is tested.
        let model = BrowseModel(libraryID: UUID(), library: library, runner: JobRunner(library: library))
        try await waitUntil { model.items.count == 3 }
        model.click(video.id, extend: true, range: false)
        model.click(segment.id, extend: false, range: false)

        model.examineSelection()

        try await waitUntil {
            (try? library.writer.read { try JobRecord.filter(sql: "kind = ?", arguments: [MediaSignalJob.kind]).fetchCount($0) }) == 1
        }
        let row = try #require(try await library.writer.read {
            try JobRecord.filter(sql: "kind = ?", arguments: [MediaSignalJob.kind]).fetchOne($0)
        })
        let payload = try JSONDecoder().decode(MediaSignalJob.Payload.self, from: try #require(row.payload))
        // The video once, for itself and its clip; not the unselected one.
        #expect(payload.itemIDs == [video.id])
        #expect(model.selection.isEmpty)
    }

    @Test func nothingSelectedQueuesNothing() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Examine")
        let model = BrowseModel(libraryID: UUID(), library: library, runner: JobRunner(library: library))
        model.examineSelection()
        try await Task.sleep(for: .milliseconds(50))
        let rows = try await library.writer.read { try JobRecord.fetchCount($0) }
        #expect(rows == 0)
    }
}
