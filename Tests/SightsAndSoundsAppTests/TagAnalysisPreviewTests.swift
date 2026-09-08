import AVFoundation
import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// The rail's preview player — the one AVPlayer that numpad 5, the
/// transport button and the scrubber all drive. It has to be pointed at
/// the CURRENT video, from the first video on; a key that plays an
/// empty player looks exactly like a key that does nothing.
@Suite @MainActor struct TagAnalysisPreviewTests {

    private func makeLibrary() async throws -> (LibraryDatabase, [MediaItem], URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sas-preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Preview")
        let source = Source(name: "S", rootPath: root.path)
        let items = ["a.mp4", "b.mp4"].map { name in
            FileManager.default.createFile(
                atPath: root.appendingPathComponent(name).path, contents: Data())
            return MediaItem(
                sourceID: source.id, kind: .video, relativePath: name, needsReview: false)
        }
        try await library.writer.write { db in
            try source.insert(db)
            for item in items { try item.insert(db) }
        }
        return (library, items, root)
    }

    /// `reload` finishes on a Task; wait for it rather than sleeping a
    /// guessed amount.
    private func settle(_ model: TagAnalysisModel) async throws {
        for _ in 0..<400 where model.isLoading {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(!model.isLoading)
    }

    private func previewFile(_ model: TagAnalysisModel) -> String? {
        (model.previewPlayer.currentItem?.asset as? AVURLAsset)?.url.lastPathComponent
    }

    @Test func thePreviewPlaysTheFirstVideoOnOpen() async throws {
        let (library, items, root) = try await makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = TagAnalysisModel(
            library: library, libraryID: UUID(), queue: items.map(\.id))

        model.reload()
        try await settle(model)

        #expect(previewFile(model) == "a.mp4")
    }

    @Test func advancingPointsThePreviewAtTheNewVideo() async throws {
        let (library, items, root) = try await makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = TagAnalysisModel(
            library: library, libraryID: UUID(), queue: items.map(\.id))
        model.reload()
        try await settle(model)

        model.goNext()
        try await settle(model)

        #expect(previewFile(model) == "b.mp4")
    }
}
