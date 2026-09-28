import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// Restore and Remove close the library's handle. Any window still
/// holding it is left with a closed handle, and every read after that
/// fails — so every window that holds one must count, not just the
/// library window. Properties and the auxiliary windows (Tag Manager,
/// Review, Tag Analysis…) stay open after the library window closes.
@Suite @MainActor struct LibraryInUseTests {
    private func registered(_ app: AppModel) throws -> (LibraryRef, URL) {
        let url = AppSettingsStore.testScratch
            .appendingPathComponent("in-use-\(UUID().uuidString).sqlite")
        let library = try LibraryDatabase.open(at: url)
        try library.ensureInfo(name: "InUse")
        let backup = try library.backup(
            into: AppSettingsStore.testScratch.appendingPathComponent("in-use-backups-\(UUID().uuidString)"))
        let ref = try #require(app.appDatabase).register(library)
        try library.close()
        app.refresh()
        return (ref, backup)
    }

    @Test func anAuxiliaryOrPropertiesWindowBlocksARestore() throws {
        let app = AppModel()
        let (ref, backup) = try registered(app)
        app.holdLibrary(ref.id)

        #expect(throws: AppModel.LibraryInUse.self) {
            try app.restoreLibrary(id: ref.id, from: backup)
        }

        app.releaseLibrary(ref.id)
        try app.restoreLibrary(id: ref.id, from: backup)
    }

    @Test func anAuxiliaryWindowBlocksARemove() throws {
        let app = AppModel()
        let (ref, _) = try registered(app)
        app.holdLibrary(ref.id)

        app.removeLibrary(id: ref.id)

        #expect(app.libraries.contains { $0.id == ref.id })
        #expect(app.loadError != nil)
    }

    @Test func twoWindowsHoldUntilBothClose() throws {
        let app = AppModel()
        let (ref, backup) = try registered(app)
        app.holdLibrary(ref.id)
        app.holdLibrary(ref.id)
        app.releaseLibrary(ref.id)

        #expect(throws: AppModel.LibraryInUse.self) {
            try app.restoreLibrary(id: ref.id, from: backup)
        }
    }

    /// Restoring a library nobody has open must not "open" it on the
    /// way: that stamped it as last opened and started a background
    /// settle of interrupted moves on a handle about to be closed.
    @Test func restoringAClosedLibraryDoesNotCountAsOpeningIt() throws {
        let app = AppModel()
        let (ref, backup) = try registered(app)
        let before = app.libraries.first { $0.id == ref.id }?.lastOpenedAt

        try app.restoreLibrary(id: ref.id, from: backup)

        #expect(app.libraries.first { $0.id == ref.id }?.lastOpenedAt == before)
    }
}
