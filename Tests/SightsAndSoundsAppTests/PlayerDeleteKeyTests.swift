import AVFoundation
import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// ⇧⌫: toggle the deletion mark and move on. It reaches the model from
/// anywhere in the window — any zone, either key map, inside a tag
/// field — so what it does must not depend on where the keyboard was.
/// Marking advances; unmarking stays put, the bound-key rule, so what
/// you just restored is still in front of you.
@Suite @MainActor struct PlayerDeleteKeyTests {
    private func makeLibrary() async throws -> (LibraryDatabase, Source, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("player-delete-\(UUID().uuidString)", isDirectory: true)
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "DeleteKey")
        let source = Source(name: "S", rootPath: root.path)
        try await library.writer.write { try source.insert($0) }
        return (library, source, root)
    }

    private func insert(
        _ library: LibraryDatabase, _ source: Source, _ root: URL, _ path: String, variant: Int
    ) async throws -> MediaItem {
        try await DemoMediaFactory.writeVideo(
            to: root.appendingPathComponent(path), seconds: 2, variant: variant)
        let item = MediaItem(
            sourceID: source.id, kind: .video, relativePath: path,
            durationSeconds: 2, needsReview: false)
        try await library.writer.write { try item.insert($0) }
        return item
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(25)) }
        #expect(condition())
    }

    private func stored(_ library: LibraryDatabase, _ id: UUID) throws -> MediaItem? {
        try library.writer.read { try MediaItem.fetchOne($0, key: id) }
    }

    @Test func anUnmarkedItemIsMarkedAndTheQueueAdvances() async throws {
        let (library, source, root) = try await makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try await insert(library, source, root, "a.mp4", variant: 0)
        let b = try await insert(library, source, root, "b.mp4", variant: 1)
        let model = PlayerModel(
            request: PlayerRequest(
                libraryID: UUID(), itemID: a.id, playlist: [a.id, b.id], name: "Two"),
            library: library, appDatabase: nil)
        defer { model.shutdown() }
        try await waitUntil { model.item?.id == a.id && model.fileURL != nil }

        model.toggleDeletionAndAdvance()

        try await waitUntil { model.item?.id == b.id }
        #expect(try stored(library, a.id)?.markedForDeletion == true)
        #expect(model.triageCount == 0, "outside Triage mode the pass count is untouched")
    }

    @Test func aMarkedItemIsUnmarkedAndStaysPut() async throws {
        let (library, source, root) = try await makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try await insert(library, source, root, "a.mp4", variant: 0)
        let b = try await insert(library, source, root, "b.mp4", variant: 1)
        try library.stage(.toDelete, itemID: a.id)
        let model = PlayerModel(
            request: PlayerRequest(
                libraryID: UUID(), itemID: a.id, playlist: [a.id, b.id], name: "Two"),
            library: library, appDatabase: nil)
        defer { model.shutdown() }
        try await waitUntil { model.item?.id == a.id && model.fileURL != nil }

        model.toggleDeletionAndAdvance()

        try await Task.sleep(for: .milliseconds(300))
        #expect(model.item?.id == a.id)
        #expect(try stored(library, a.id)?.markedForDeletion == false)
    }

    @Test func theLastItemIsMarkedAndStays() async throws {
        let (library, source, root) = try await makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try await insert(library, source, root, "a.mp4", variant: 0)
        let model = PlayerModel(
            request: PlayerRequest(
                libraryID: UUID(), itemID: a.id, playlist: [a.id], name: "One"),
            library: library, appDatabase: nil)
        defer { model.shutdown() }
        try await waitUntil { model.item?.id == a.id && model.fileURL != nil }

        model.toggleDeletionAndAdvance()

        try await Task.sleep(for: .milliseconds(300))
        #expect(model.item?.id == a.id)
        #expect(model.item?.markedForDeletion == true)
    }

    @Test func aMarkInsideTriageModeCountsAsOneDecision() async throws {
        let (library, source, root) = try await makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try await insert(library, source, root, "a.mp4", variant: 0)
        let b = try await insert(library, source, root, "b.mp4", variant: 1)
        let model = PlayerModel(
            request: PlayerRequest(
                libraryID: UUID(), itemID: a.id, playlist: [a.id, b.id], name: "Two"),
            library: library, appDatabase: nil)
        defer { model.shutdown() }
        try await waitUntil { model.item?.id == a.id && model.fileURL != nil }
        model.triageMode = true

        model.toggleDeletionAndAdvance()

        try await waitUntil { model.item?.id == b.id }
        #expect(model.triageCount == 1)
    }

    /// The setting: the ordinary mark (D, the ⌫ key, the toolbar button)
    /// moves on as ⇧⌫ always has. Off, it toggles and stays put.
    @Test func withTheSettingOnTheOrdinaryMarkMovesOnToo() async throws {
        let (library, source, root) = try await makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try await insert(library, source, root, "a.mp4", variant: 0)
        let b = try await insert(library, source, root, "b.mp4", variant: 1)
        let model = PlayerModel(
            request: PlayerRequest(
                libraryID: UUID(), itemID: a.id, playlist: [a.id, b.id], name: "Two"),
            library: library, appDatabase: nil)
        defer { model.shutdown() }
        try await waitUntil { model.item?.id == a.id && model.fileURL != nil }

        AppSettingsStore.shared.update { $0.deletionMarkAdvances = false }
        defer { AppSettingsStore.shared.update { $0.deletionMarkAdvances = false } }
        model.markForDeletion()
        try await waitUntil { model.item?.markedForDeletion == true }
        #expect(model.item?.id == a.id)  // stayed put, as before
        model.markForDeletion()  // unmark, so the next mark is a mark
        try await waitUntil { model.item?.markedForDeletion == false }

        AppSettingsStore.shared.update { $0.deletionMarkAdvances = true }
        model.markForDeletion()
        try await waitUntil { model.item?.id == b.id }
        #expect(try stored(library, a.id)?.markedForDeletion == true)
    }
}
