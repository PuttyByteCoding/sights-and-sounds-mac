import Foundation
import Testing
@testable import SightsAndSoundsKit

/// Issue #23: the JSON settings store (tolerant decode, round-trip,
/// legacy migration) and vocabulary export/import.
@Suite struct SettingsTests {

    @Test func handEditedJSONWithMissingKeysLoadsCleanly() throws {
        // Only one key present; everything else defaults.
        let partial = #"{"ocrSampleIntervalSeconds": 2.5}"#
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(partial.utf8))
        #expect(decoded.ocrSampleIntervalSeconds == 2.5)
        #expect(decoded.videoExtensions == AppSettings.defaultVideoExtensions)
        #expect(decoded.skip == SkipSettings())
        #expect(decoded.backupDirectory == nil)

        // Unknown keys are ignored.
        let extra = #"{"someFutureKey": true, "audioExtensions": ["flac"]}"#
        let decoded2 = try JSONDecoder().decode(AppSettings.self, from: Data(extra.utf8))
        #expect(decoded2.audioExtensions == ["flac"])
    }

    @Test func storeRoundTripsThroughDisk() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-settings-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }

        let store = AppSettingsStore(fileURL: file)
        store.update {
            $0.backupDirectory = "/Volumes/Backups"
            $0.skip.key7Seconds = 300
        }
        // A fresh store from the same file sees the saved values.
        let reloaded = AppSettingsStore(fileURL: file)
        #expect(reloaded.current.backupDirectory == "/Volumes/Backups")
        #expect(reloaded.current.skip.key7Seconds == 300)
        // The file itself is valid, pretty JSON.
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("\"backupDirectory\""))
    }

    @Test func invalidJSONFallsBackToDefaults() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-settings-bad-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("{{not json".utf8).write(to: file)
        let store = AppSettingsStore(fileURL: file)
        #expect(store.current == AppSettings())
    }

    @Test func vocabularyExportImportRoundTrips() async throws {
        let f = try FilterFixture()
        try f.library.addAlias("Soundboard", toTag: f.sbd.id)
        try await f.library.writer.write { db in
            try FieldDefinition(
                name: "Lesson Number", dataType: .number, scope: .mediaItem).insert(db)
        }

        let json = try VocabularyIO.exportJSON(from: f.library)
        let plan = try JSONDecoder().decode(LibraryPlan.self, from: json)
        #expect(plan.categories.map(\.name) == ["Band", "Recording Type"])
        #expect(plan.categories[1].tags.contains { $0.name == "SBD" && $0.aliases == ["Soundboard"] })
        #expect(plan.itemFields.map(\.name) == ["Lesson Number"])

        // Import into an empty library: everything created.
        let target = try LibraryDatabase.openInMemory()
        try target.ensureInfo(name: "Target")
        let outcome = try VocabularyIO.importJSON(json, into: target)
        #expect(outcome.categoriesCreated == 2)
        #expect(outcome.tagsCreated == 5)
        #expect(outcome.fieldsCreated == 1)
        let names = try await target.writer.read { try TagCategory.fetchAll($0).map(\.name) }
        #expect(Set(names) == ["Band", "Recording Type"])
        // Aliases came along.
        #expect(try await target.writer.read { try TagAlias.fetchCount($0) } == 1)

        // Import again: additive means nothing new, nothing broken.
        let again = try VocabularyIO.importJSON(json, into: target)
        #expect(again.categoriesCreated == 0)
        #expect(again.tagsCreated == 0)
        #expect(again.skippedExisting > 0)
    }

    @Test func importNeverStealsDefaultFocus() async throws {
        let f = try FilterFixture()
        var band = f.band
        band.isDefaultFocus = true
        try f.library.updateCategory(band)
        let json = try VocabularyIO.exportJSON(from: f.library)

        let target = try LibraryDatabase.openInMemory()
        try target.ensureInfo(name: "T")
        let existing = TagCategory(name: "Existing", isDefaultFocus: true)
        try target.createCategory(existing)

        _ = try VocabularyIO.importJSON(json, into: target)
        let focused = try await target.writer.read { db in
            try TagCategory.filter(sql: "isDefaultFocus = 1").fetchAll(db).map(\.name)
        }
        #expect(focused == ["Existing"])  // the import didn't take it
    }

    @Test func legacySkipMigratesOnce() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-settings-mig-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let app = try AppDatabase.openInMemory()
        let legacy = SkipSettings(key1Seconds: 9)
        try app.setPreference(
            "playbackSkips",
            to: String(data: try JSONEncoder().encode(legacy), encoding: .utf8)!)

        let store = AppSettingsStore(fileURL: file)
        store.migrateLegacySkipForTesting(from: app)
        #expect(store.current.skip.key1Seconds == 9)

        // Second migration is a no-op (the file now exists).
        try app.setPreference("playbackSkips", to: "{\"key1Seconds\": 99}")
        store.migrateLegacySkipForTesting(from: app)
        #expect(store.current.skip.key1Seconds == 9)
    }
}
