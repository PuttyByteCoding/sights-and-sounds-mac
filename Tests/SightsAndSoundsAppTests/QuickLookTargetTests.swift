import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// Space is Quick Look, as in Finder and Photos. What it shows: the
/// selection, in listing order, starting at the focused tile when that
/// is part of it; with no selection, just the focused tile. Files on an
/// offline source cannot be shown and are left out.
@Suite @MainActor struct QuickLookTargetTests {
    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(25)) }
        #expect(condition())
    }

    private func model() async throws -> (BrowseModel, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quick-look-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "QuickLook")
        let here = Source(name: "Here", rootPath: root.path)
        let gone = Source(name: "Gone", rootPath: "/Volumes/SAS-Test-Gone-\(UUID().uuidString)")
        try await library.writer.write { db in
            try here.insert(db)
            try gone.insert(db)
            for name in ["a", "b", "c"] {
                try Data(name.utf8).write(to: root.appendingPathComponent("\(name).mp4"))
                try MediaItem(sourceID: here.id, kind: .video, relativePath: "\(name).mp4", needsReview: false).insert(db)
            }
            try MediaItem(sourceID: gone.id, kind: .video, relativePath: "d.mp4", needsReview: false).insert(db)
        }
        let model = BrowseModel(libraryID: UUID(), library: library, runner: JobRunner(library: library))
        try await waitUntil { model.items.count == 4 && model.offlineItems.count == 1 }
        return (model, root)
    }

    @Test func withNoSelectionItShowsTheFocusedTile() async throws {
        let (model, root) = try await model()
        defer { try? FileManager.default.removeItem(at: root) }
        let b = try #require(model.visibleItems.first { $0.relativePath == "b.mp4" })
        model.moveFocus(to: b.id)

        let target = model.quickLookTarget()

        #expect(target?.current.lastPathComponent == "b.mp4")
        #expect(target?.all.map(\.lastPathComponent) == ["b.mp4"])
    }

    @Test func withASelectionItShowsTheSelectionFromTheFocusedTile() async throws {
        let (model, root) = try await model()
        defer { try? FileManager.default.removeItem(at: root) }
        for item in model.visibleItems { model.click(item.id, extend: true, range: false) }
        let c = try #require(model.visibleItems.first { $0.relativePath == "c.mp4" })
        model.moveFocus(to: c.id)

        let target = model.quickLookTarget()

        #expect(target?.all.map(\.lastPathComponent) == ["a.mp4", "b.mp4", "c.mp4"])  // d is offline
        #expect(target?.current.lastPathComponent == "c.mp4")
    }

    @Test func nothingFocusedOrSelectedShowsNothing() async throws {
        let (model, root) = try await model()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(model.quickLookTarget() == nil)
    }
}
