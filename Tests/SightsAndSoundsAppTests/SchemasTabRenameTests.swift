import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// Renaming the selected schema in the Schemas tab used to add a second
/// schema under the new name and leave the old one behind.
@Suite @MainActor struct SchemasTabRenameTests {
    @Test func renamingTheSelectedSchemaKeepsOneSchema() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Schemas")
        let model = SchemasTabModel(service: LocalLibraryService(library: library))
        model.startNew()
        model.draftName = "Notes"
        model.draftKeys = [SchemaKey(key: "venue")]
        await model.save()
        let notes = try #require(model.schemas.first)

        model.select(notes)
        model.draftName = "Show Notes"
        await model.save()

        #expect(model.schemas.map(\.name) == ["Show Notes"])
        #expect(model.schemas.first?.id == notes.id)
        #expect(model.loadError == nil)
    }
}
