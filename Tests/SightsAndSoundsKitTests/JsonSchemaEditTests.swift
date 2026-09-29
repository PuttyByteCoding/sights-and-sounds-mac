import Foundation
import Testing

@testable import SightsAndSoundsKit

/// The Schemas tab edits a schema it has selected. Saving went by NAME:
/// renaming "Notes" to "Show Notes" inserted a second schema and left the
/// first behind, and a new schema given an existing name silently took
/// over that schema's keys. Saving by id changes exactly one schema and
/// refuses a name another schema already has.
@Suite struct JsonSchemaEditTests {
    private func library() throws -> LibraryDatabase {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Schemas")
        return library
    }

    @Test func renamingASchemaKeepsOneSchema() throws {
        let library = try library()
        let notes = try library.saveJsonSchema(id: nil, named: "Notes", keys: [SchemaKey(key: "a")])
        let renamed = try library.saveJsonSchema(id: notes.id, named: "Show Notes", keys: [SchemaKey(key: "b")])

        #expect(renamed.id == notes.id)
        let all = try library.jsonSchemas()
        #expect(all.map(\.name) == ["Show Notes"])
        #expect(all.first?.keys.map(\.key) == ["b"])
    }

    @Test func aNewSchemaCannotTakeAnExistingName() throws {
        let library = try library()
        _ = try library.saveJsonSchema(id: nil, named: "Notes", keys: [SchemaKey(key: "a")])

        #expect(throws: JsonSchemaError.nameTaken("notes")) {
            try library.saveJsonSchema(id: nil, named: "notes", keys: [SchemaKey(key: "b")])
        }
        #expect(try library.jsonSchemas().first?.keys.map(\.key) == ["a"])
    }

    @Test func aRenameCannotTakeAnotherSchemasName() throws {
        let library = try library()
        _ = try library.saveJsonSchema(id: nil, named: "Notes", keys: [SchemaKey(key: "a")])
        let other = try library.saveJsonSchema(id: nil, named: "Setlist", keys: [SchemaKey(key: "b")])

        #expect(throws: JsonSchemaError.nameTaken("NOTES")) {
            try library.saveJsonSchema(id: other.id, named: "NOTES", keys: [SchemaKey(key: "c")])
        }
        #expect(try library.jsonSchemas().map(\.name) == ["Notes", "Setlist"])
    }

    /// Changing only the case of a schema's own name is a rename, not a clash.
    @Test func aCaseOnlyRenameIsAllowed() throws {
        let library = try library()
        let notes = try library.saveJsonSchema(id: nil, named: "notes", keys: [SchemaKey(key: "a")])
        _ = try library.saveJsonSchema(id: notes.id, named: "Notes", keys: [SchemaKey(key: "a")])
        #expect(try library.jsonSchemas().map(\.name) == ["Notes"])
    }
}
