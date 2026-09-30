import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// Organise and Maintenance › Write-back say they act on "the filtered
/// items", but open in a window of their own with a fresh model — no
/// filter at all. Filtering the grid to 12 items and pressing Move moved
/// every video in the library. The window now carries the grid's items
/// with it.
@Suite @MainActor struct AuxWindowScopeTests {
    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(25)) }
        #expect(condition())
    }

    @Test func organiseAndMaintenanceOpenOnWhatTheGridShows() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Scope")
        let source = Source(name: "Here", rootPath: FileManager.default.temporaryDirectory.path)
        try await library.writer.write { db in
            try source.insert(db)
            for n in 0..<6 {
                try MediaItem(sourceID: source.id, kind: .video,
                              relativePath: "\(n < 2 ? "keep" : "other")-\(n).mp4",
                              needsReview: false).insert(db)
            }
        }
        let model = BrowseModel(libraryID: UUID(), library: library, runner: JobRunner(library: library))
        try await waitUntil { model.items.count == 6 }
        model.setSearchText("keep")
        try await waitUntil { model.visibleItems.count == 2 }

        for kind in [AuxWindowRequest.Kind.organise, .maintenance] {
            let request = model.auxRequest(kind)
            #expect(request.scopeItemIDs == model.visibleItems.map(\.id), "\(kind)")
        }
        // Other windows are about the library, not the listing.
        #expect(model.auxRequest(.review).scopeItemIDs == nil)

        // The Window menu (⌥⌘4, ⌥⌘5) opens the same window the toolbar
        // does: it built a bare request, so Maintenance opened on the
        // whole library and a second window beside the toolbar's.
        for kind in AuxWindowRequest.Kind.allCases {
            #expect(ViewMenuCommands.request(kind, libraryID: model.libraryID, browse: model)
                    == model.auxRequest(kind), "\(kind)")
        }
        // A focused grid of another library lends nothing.
        let elsewhere = UUID()
        #expect(ViewMenuCommands.request(.maintenance, libraryID: elsewhere, browse: model)
                == AuxWindowRequest(libraryID: elsewhere, kind: .maintenance))
    }

    /// Windows saved before the scope existed reopen on the whole library.
    @Test func aSavedRequestWithoutAScopeStillDecodes() throws {
        let saved = #"{"libraryID":"\#(UUID().uuidString)","kind":"organise","itemIDs":[]}"#
        let request = try JSONDecoder().decode(AuxWindowRequest.self, from: Data(saved.utf8))
        #expect(request.scopeItemIDs == nil)
    }

    /// With nothing narrowing the grid, the window's own unfiltered listing
    /// IS the grid's, so it carries no list: the list is the window's
    /// identity and its saved state, and an unfiltered library put every
    /// item's id into both (and opened a new window per listing).
    @Test func anUnfilteredGridSendsOrganiseNoList() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Unfiltered")
        let source = Source(name: "Here", rootPath: FileManager.default.temporaryDirectory.path)
        try await library.writer.write { db in
            try source.insert(db)
            for n in 0..<4 {
                try MediaItem(sourceID: source.id, kind: .video, relativePath: "\(n).mp4", needsReview: false).insert(db)
            }
        }
        let model = BrowseModel(libraryID: UUID(), library: library, runner: JobRunner(library: library))
        try await waitUntil { model.items.count == 4 }
        #expect(model.auxRequest(.organise).scopeItemIDs == nil)
        // Maintenance's write-back reads no list as every item of every
        // kind — audio the grid never showed included — so it always gets
        // the grid's items.
        #expect(model.auxRequest(.maintenance).scopeItemIDs == model.visibleItems.map(\.id))

        // Audio as well as video is narrower than nothing: the window's own
        // listing is video only, so the grid's items travel.
        _ = model.toggleKind(.audio)
        try await waitUntil { model.kinds.contains(.audio) }
        #expect(model.auxRequest(.organise).scopeItemIDs != nil)
    }
}

