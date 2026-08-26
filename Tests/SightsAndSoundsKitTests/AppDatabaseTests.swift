import Foundation
import Testing
@testable import SightsAndSoundsKit

/// The app-level store: registry reconciliation and preferences.
@Suite struct AppDatabaseTests {

    @Test func registryReconcilesByLibraryID() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-app-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let app = try AppDatabase.openInMemory()
        let url = dir.appendingPathComponent("Concerts.sqlite")
        let library = try LibraryDatabase.open(at: url)
        try library.ensureInfo(name: "Concerts")

        let ref = try app.register(library)
        #expect(ref.name == "Concerts")
        #expect(try app.libraries().count == 1)

        // "Move" the file and re-register: same entry, new path — no dupe.
        // Close first: a WAL-mode library is one portable file only after
        // its final checkpoint.
        try library.close()
        let movedURL = dir.appendingPathComponent("Moved.sqlite")
        try FileManager.default.copyItem(at: url, to: movedURL)
        let moved = try LibraryDatabase.open(at: movedURL)
        let refreshed = try app.register(moved)
        #expect(refreshed.id == ref.id)
        #expect(refreshed.filePath == movedURL.path)
        #expect(try app.libraries().count == 1)
    }

    @Test func registeringAnonymousLibraryIsRefused() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-app-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let app = try AppDatabase.openInMemory()
        let library = try LibraryDatabase.open(at: dir.appendingPathComponent("NoName.sqlite"))
        #expect(throws: (any Error).self) { try app.register(library) }
    }

    @Test func preferencesUpsert() throws {
        let app = try AppDatabase.openInMemory()
        #expect(try app.preference("theme") == nil)
        try app.setPreference("theme", to: "dark")
        try app.setPreference("theme", to: "light")
        #expect(try app.preference("theme") == "light")
    }

    @Test func lastOpenedTouches() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-app-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let app = try AppDatabase.openInMemory()
        let library = try LibraryDatabase.open(at: dir.appendingPathComponent("L.sqlite"))
        let info = try library.ensureInfo(name: "L")
        try app.register(library)

        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        try app.touchLastOpened(info.libraryID, at: stamp)
        #expect(try app.libraries().first?.lastOpenedAt == stamp)
    }
}
