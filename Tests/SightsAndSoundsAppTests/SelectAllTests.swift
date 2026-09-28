import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// ⌘A selects everything the grid shows — the Mac's Select All, which
/// the grid did not have. "Everything shown" is the visible listing:
/// items hidden with the offline toggle are not selected behind the
/// user's back.
@Suite @MainActor struct SelectAllTests {
    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(25)) }
        #expect(condition())
    }

    @Test func selectAllTakesEveryVisibleItem() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "SelectAll")
        let here = Source(name: "Here", rootPath: FileManager.default.temporaryDirectory.path)
        let gone = Source(name: "Gone", rootPath: "/Volumes/SAS-Test-Gone-\(UUID().uuidString)")
        try await library.writer.write { db in
            try here.insert(db)
            try gone.insert(db)
            for n in 0..<6 {
                try MediaItem(sourceID: n < 4 ? here.id : gone.id, kind: .video,
                              relativePath: "\(n).mp4", needsReview: false).insert(db)
            }
        }
        let model = BrowseModel(libraryID: UUID(), library: library, runner: JobRunner(library: library))
        try await waitUntil { model.items.count == 6 && model.offlineItems.count == 2 }
        model.hideOfflineItems = true

        model.selectAll()

        #expect(model.selection == Set(model.visibleItems.map(\.id)))
        #expect(model.selection.count == 4)
    }
}
