import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// A tag key changes one item's tags. It used to re-read the whole
/// vocabulary, every alias and the key bindings and rebuild the search
/// index — on the main actor, on every press — so tagging slowed with
/// the size of the library's vocabulary.
@Suite(.writesVideo) @MainActor struct TagKeyRefreshTests {
    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(25)) }
        #expect(condition())
    }

    @Test func aTagKeyIsQuickWhateverTheVocabulary() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tag-key-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await DemoMediaFactory.writeVideo(to: root.appendingPathComponent("a.mp4"), seconds: 2, variant: 0)
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Big vocabulary")
        let source = Source(name: "S", rootPath: root.path)
        let item = MediaItem(sourceID: source.id, kind: .video, relativePath: "a.mp4", durationSeconds: 2, needsReview: false)
        let band = TagCategory(name: "Band")
        let tag = SightsAndSoundsKit.Tag(tagCategoryID: band.id, name: "Band number 0")
        try await library.writer.write { db in
            try source.insert(db)
            try item.insert(db)
            try band.insert(db)
            try tag.insert(db)
            try TagAlias(tagID: tag.id, alias: "alias 0").insert(db)
            for n in 1..<6_000 {
                let other = SightsAndSoundsKit.Tag(tagCategoryID: band.id, name: "Band number \(n)")
                try other.insert(db)
                try TagAlias(tagID: other.id, alias: "alias \(n)").insert(db)
            }
        }
        let model = PlayerModel(
            request: PlayerRequest(libraryID: UUID(), itemID: item.id, playlist: [item.id], name: "One"),
            library: library, appDatabase: nil)
        defer { model.shutdown() }
        try await waitUntil { model.item?.id == item.id && model.panelVocabulary.first?.tags.count == 6_000 }

        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for _ in 0..<20 { model.toggleTag(tag.id) }
        }
        #expect(elapsed < .seconds(0.5), "20 presses took \(elapsed)")
        // Each press is a write on its way and then a re-read of the
        // panel; what it shows is checked once those have landed.
        try await waitUntil { model.isSettled }
        #expect(!model.hasTag(tag.id))  // an even number of toggles
        model.toggleTag(tag.id)
        try await waitUntil { model.isSettled }
        #expect(model.hasTag(tag.id))

        // A brand-new tag still reaches the vocabulary and the search.
        model.addTag(named: "Brand New Band", categoryID: band.id)
        try await waitUntil { model.isSettled }
        #expect(model.panelVocabulary.first?.tags.contains { $0.name == "Brand New Band" } == true)
        #expect(model.tagSearchIndex.contains { $0.tag.name == "Brand New Band" })
    }
}
