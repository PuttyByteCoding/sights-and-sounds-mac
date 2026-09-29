import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// Tag Manager, Review, Maintenance and Organise read the library into
/// state of their own when they open, and nothing told them afterwards:
/// a D-mark made in the player never reached an open Review, a tag
/// renamed from the sidebar stayed old in Tag Manager. Their window's
/// model now counts the hub's deliveries by domain, and each window
/// reloads when the domains it shows change.
@Suite @MainActor struct AuxWindowsFollowChangesTests {
    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(25)) }
        #expect(condition())
    }

    @Test func aWriteFromElsewhereIsCountedForItsDomain() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Follow")
        let model = BrowseModel(libraryID: UUID(), library: library, runner: JobRunner(library: library))
        // The baseline once deliveries have gone quiet, not after a fixed
        // wait: on a loaded machine a late startup delivery landing after
        // the baseline would read as a change.
        var quiet = 0, last = model.changeCounts
        while quiet < 8 {
            try await Task.sleep(for: .milliseconds(50))
            quiet = model.changeCounts == last ? quiet + 1 : 0
            last = model.changeCounts
        }
        let vocabularyBefore = model.changeCount([.vocabulary])
        let itemsBefore = model.changeCount([.items])

        // Another window adds a category.
        try await library.writer.write { try TagCategory(name: "Band").insert($0) }

        try await waitUntil { model.changeCount([.vocabulary]) > vocabularyBefore }
        #expect(model.changeCount([.items]) == itemsBefore)
    }
}
