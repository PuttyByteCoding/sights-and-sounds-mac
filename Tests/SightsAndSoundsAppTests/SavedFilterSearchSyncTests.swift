import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// A saved filter carries its own search text. Applying one used to
/// leave the field showing the old text, and a keystroke still inside
/// its debounce then wrote the typed text over the saved filter's.
@Suite @MainActor struct SavedFilterSearchSyncTests {
    private func model() throws -> BrowseModel {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "SavedSearch")
        return BrowseModel(libraryID: UUID(), library: library, runner: JobRunner(library: library))
    }

    @Test func applyingASavedFilterShowsItsSearchTextAndBeatsAPendingKeystroke() async throws {
        let model = try model()
        var saved = MediaFilter()
        saved.searchText = "encore"
        model.filter = saved
        model.saveCurrentFilter(named: "Encores")
        let filter = try #require(model.savedFilters.first { $0.name == "Encores" })
        model.clearFilter()

        model.setSearchText("typed")
        model.applySavedFilter(filter)
        try await Task.sleep(for: .milliseconds(400))

        #expect(model.filter.searchText == "encore")
        #expect(model.searchDisplayText == "encore")
    }
}
