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

    /// An imported vocabulary carries its display styles across without
    /// the caller restating them.
    @Test func importCarriesTheDisplayStyle() async throws {
        let f = try FilterFixture()
        var band = f.band
        band.displayStyle = .checkboxes
        try f.library.updateCategory(band)
        let json = try VocabularyIO.exportJSON(from: f.library)

        let target = try LibraryDatabase.openInMemory()
        try target.ensureInfo(name: "T")
        _ = try VocabularyIO.importJSON(json, into: target)
        let styles = try await target.writer.read { db in
            try TagCategory.fetchAll(db)
        }
        #expect(styles.first { $0.name == "Band" }?.displayStyle == .checkboxes)
    }
}

/// Saved tile views, and the two older shapes of this section that must
/// keep loading: the per-field booleans (#99's predecessor) and the
/// placements that replaced them.
@Suite struct TileViewSettingsTests {

    @Test func aFreshInstallGetsTheShippedViews() {
        let grid = GridSettings()
        #expect(grid.views.map(\.name)
            == ["Default", "Triage", "Tagging", "Contact sheet", "Clean"])
        #expect(grid.activeView.name == "Default")
        #expect(grid.activeView.entries(in: .below).map(\.value) == [.fileName])
    }

    @Test func legacyBooleansBecomeOneCarriedForwardView() throws {
        let json = """
        {"thumbnailSize": 250, "showsFileName": false, "showsDuration": true,
         "showsPath": true, "showsDuplicate": false}
        """
        let grid = try JSONDecoder().decode(GridSettings.self, from: Data(json.utf8))
        #expect(grid.thumbnailSize == 250)
        // What was on lands under the thumbnail, and it is what opens.
        #expect(grid.activeView.name == "Custom")
        #expect(Set(grid.activeView.entries(in: .below).map(\.value)) == [.duration, .path])
        #expect(!grid.activeView.contains(.fileName))
        // The shipped views are still there to switch to.
        #expect(grid.views.count == TileView.shipped.count + 1)
    }

    @Test func legacyPlacementsKeepTheirCorners() throws {
        let json = """
        {"fileName": "bottomLeft", "favorite": "topRight", "duration": "hidden",
         "tags": "under"}
        """
        let grid = try JSONDecoder().decode(GridSettings.self, from: Data(json.utf8))
        #expect(grid.activeView.slot(of: .fileName) == .bottomLeft)
        #expect(grid.activeView.slot(of: .favorite) == .topRight)
        #expect(grid.activeView.slot(of: .tags) == .below)
        #expect(!grid.activeView.contains(.duration))
    }

    @Test func viewsRoundTrip() throws {
        var grid = GridSettings()
        grid.views[0].toggle(.fileSize, in: .topLeft)
        grid.views[0].update(.fileSize) { $0.alignment = .center; $0.width = .fixed(120) }
        grid.activeViewID = grid.views[1].id
        let data = try JSONEncoder().encode(grid)
        let decoded = try JSONDecoder().decode(GridSettings.self, from: data)
        #expect(decoded == grid)
        #expect(decoded.activeView.name == "Triage")
    }

    /// A value lives in one slot at a time — moving it does not leave a
    /// copy behind in the slot it came from.
    @Test func aValueLivesInOneSlot() {
        var view = TileView(name: "Test")
        view.toggle(.duration, in: .topLeft)
        view.toggle(.duration, in: .bottomRight)
        #expect(view.slot(of: .duration) == .bottomRight)
        #expect(view.entries(in: .topLeft).isEmpty)
        view.toggle(.duration, in: .bottomRight)
        #expect(!view.contains(.duration))
        #expect(view.placements.isEmpty)
    }

    /// Only the views that actually show tags pay for the join.
    @Test func onlyTagViewsNeedTheBatchQueries() {
        var grid = GridSettings()
        grid.activeViewID = grid.views.first { $0.name == "Clean" }?.id
        #expect(!grid.needsTagData)
        grid.activeViewID = grid.views.first { $0.name == "Tagging" }?.id
        #expect(grid.needsTagData)
    }

    /// The per-category entries survive a round trip through the raw
    /// string form, which is what settings.json stores.
    @Test func perCategoryTagValuesRoundTripThroughTheirRawForm() {
        let id = UUID()
        let value = TileValue.tagsIn(id)
        #expect(TileValue(rawValue: value.rawValue) == value)
        #expect(TileValue(rawValue: "tags:not-a-uuid") == nil)
    }

    /// A named view that has since been deleted must not leave the grid
    /// with nothing to draw.
    @Test func aMissingActiveViewFallsBackToTheFirst() {
        var grid = GridSettings()
        grid.activeViewID = UUID()
        #expect(grid.activeView.name == "Default")
        #expect(grid.activeIndex == 0)
    }
}
