import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// A tile drags out as its file — onto the Finder, into another app —
/// as files do everywhere on the Mac; the grid had no drag at all. An
/// embedded clip has no file of its own (its "file" would be the whole
/// parent), and an offline item's file cannot be reached, so neither
/// offers one.
@Suite @MainActor struct TileDragTests {
    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(25)) }
        #expect(condition())
    }

    @Test func aTileDragsItsOwnFileOnly() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tile-drag-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("video".utf8).write(to: root.appendingPathComponent("show.mp4"))
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Drag")
        let here = Source(name: "Here", rootPath: root.path)
        let gone = Source(name: "Gone", rootPath: "/Volumes/SAS-Test-Gone-\(UUID().uuidString)")
        let show = MediaItem(sourceID: here.id, kind: .video, relativePath: "show.mp4", needsReview: false)
        let clip = MediaItem(
            sourceID: here.id, kind: .video, relativePath: "show.mp4", needsReview: false,
            parentMediaItemID: show.id, clipStartSeconds: 1, clipEndSeconds: 2)
        let away = MediaItem(sourceID: gone.id, kind: .video, relativePath: "away.mp4", needsReview: false)
        try await library.writer.write { db in
            try here.insert(db)
            try gone.insert(db)
            try show.insert(db)
            try clip.insert(db)
            try away.insert(db)
        }
        let model = BrowseModel(libraryID: UUID(), library: library, runner: JobRunner(library: library))
        try await waitUntil { model.items.count >= 2 && !model.offlineItems.isEmpty }

        #expect(model.dragFileURL(for: show)?.lastPathComponent == "show.mp4")
        #expect(model.dragFileURL(for: clip) == nil)
        #expect(model.dragFileURL(for: away) == nil)
    }
}
