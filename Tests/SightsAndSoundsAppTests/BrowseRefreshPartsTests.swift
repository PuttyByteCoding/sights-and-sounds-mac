import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// A change reloads what it touches, not the whole library. Every edit
/// used to re-read the sources and check each one's drive, reload the
/// vocabulary and every alias, rebuild a folder tree per source, and
/// recount every saved filter — to show one new tag pill.
@Suite @MainActor struct BrowseRefreshPartsTests {

    @Test func eachKindOfChangeNamesWhatItCanAffect() {
        #expect(BrowseRefresh.parts(for: [.tagging]) == [.counts, .savedFilterCounts, .listing])
        #expect(BrowseRefresh.parts(for: [.items]) == [.counts, .savedFilterCounts, .listing])
        #expect(BrowseRefresh.parts(for: [.vocabulary]) == [.vocabulary, .counts, .listing])
        #expect(BrowseRefresh.parts(for: [.sources]) == [.sources, .counts, .savedFilterCounts, .listing])
        #expect(BrowseRefresh.parts(for: [.savedFilters]) == [.savedFilters, .savedFilterCounts])
        #expect(BrowseRefresh.parts(for: [.duplicates]) == [.duplicates, .listing])
        // Blocks and snapshots only feed the tile menu: no listing query.
        #expect(BrowseRefresh.parts(for: [.itemDetails]) == [.menuFacts])
        #expect(BrowseRefresh.parts(for: []) == [])
        // Several at once is their union.
        #expect(BrowseRefresh.parts(for: [.savedFilters, .itemDetails])
            == [.savedFilters, .savedFilterCounts, .menuFacts])
    }

    /// Counts how often anything asks whether a drive is there.
    private final class CountingFiles: FileAccess, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var reachabilityChecks: Int { lock.withLock { count } }
        func isReachable(_ url: URL) -> Bool { lock.withLock { count += 1 }; return false }
        func contentsOfDirectory(at url: URL) throws -> [URL] { [] }
        func allFiles(under url: URL) throws -> [URL] { [] }
        func fileSize(at url: URL) throws -> Int64 { 0 }
        func readFile(at url: URL, chunk: (Data) throws -> Void) throws {}
        func moveFile(at url: URL, to destination: URL) throws {}
        func removeFile(at url: URL) throws {}
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }

    /// The reachability check is a filesystem call that can take a
    /// network timeout. A tag edit has no business making one.
    @Test func aTagEditDoesNotGoAndCheckTheDrives() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Parts")
        let source = Source(name: "S", rootPath: "/tmp/sas-parts-\(UUID().uuidString)")
        let item = MediaItem(sourceID: source.id, kind: .video, relativePath: "a.mp4", needsReview: false)
        let band = TagCategory(name: "Band")
        let tag = SightsAndSoundsKit.Tag(tagCategoryID: band.id, name: "Band A")
        try await library.writer.write { db in
            try source.insert(db)
            try item.insert(db)
            try band.insert(db)
            try tag.insert(db)
        }
        let files = CountingFiles()
        let model = BrowseModel(
            libraryID: UUID(), library: library, runner: JobRunner(library: library), fileAccess: files)
        try await waitUntil { model.items.count == 1 }
        try await Task.sleep(for: .milliseconds(300))  // the opening refresh is done
        let before = files.reachabilityChecks

        try library.assignTag(tag.id, to: item.id)
        try await waitUntil { (model.counts.byTag[tag.id] ?? 0) == 1 }

        #expect(files.reachabilityChecks == before)
    }
}
