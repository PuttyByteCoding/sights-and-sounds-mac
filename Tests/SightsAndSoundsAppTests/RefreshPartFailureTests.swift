import Foundation
import GRDB
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// A refresh loads several parts in one go. They shared one `do`, so a
/// throw in any of them — the saved filters, the duplicate count — skipped
/// applying all of them, left the listing unloaded, and replaced the grid
/// with "Query Failed" for something that was not the listing. Each part
/// now fails on its own and says so on the error line.
@Suite @MainActor struct RefreshPartFailureTests {
    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(25)) }
        #expect(condition())
    }

    @Test func aFailingSidebarPartLeavesTheGridListed() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Parts")
        let source = Source(name: "Here", rootPath: FileManager.default.temporaryDirectory.path)
        try await library.writer.write { db in
            try source.insert(db)
            for n in 0..<3 {
                try MediaItem(sourceID: source.id, kind: .video, relativePath: "\(n).mp4",
                              needsReview: false).insert(db)
            }
            // The saved filters cannot be read.
            try db.execute(sql: "DROP TABLE \(SavedFilter.databaseTableName)")
        }
        let model = BrowseModel(libraryID: UUID(), library: library, runner: JobRunner(library: library))

        try await waitUntil { model.items.count == 3 }
        #expect(model.listingError == nil)
        try await waitUntil { model.errorMessage != nil }
    }
}
