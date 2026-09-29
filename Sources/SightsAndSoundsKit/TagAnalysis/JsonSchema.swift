import Foundation
import GRDB

/// One expected key in a schema: its name, whether the schema requires
/// it to match, and — the point of the whole feature — which category
/// its values belong to.
public struct SchemaKey: Codable, Equatable, Sendable, Identifiable {
    public var key: String
    public var required: Bool
    /// Category NAME, like a rule's assignCategory — resolved at apply
    /// time, reported (never invented) when the library lacks it.
    public var category: String?

    public var id: String { key }

    public init(key: String, required: Bool = true, category: String? = nil) {
        self.key = key
        self.required = required
        self.category = category
    }
}

/// A named JSON shape the operator has taught the library — "JSON with
/// taper and venue keys is my show-notes format". Authored, like rules
/// and saved filters, so it migrates where derived state would not.
public struct JsonSchemaDefinition: Codable, Equatable, Identifiable, Sendable,
    FetchableRecord, PersistableRecord
{
    public static let databaseTableName = "jsonSchema"

    public var id: UUID
    public var name: String
    public var definitionJSON: String
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, definitionJSON: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.definitionJSON = definitionJSON
        self.createdAt = createdAt
    }

    public var keys: [SchemaKey] {
        (try? JSONDecoder().decode([SchemaKey].self, from: Data(definitionJSON.utf8))) ?? []
    }

    /// A payload matches when every REQUIRED key is present — compared
    /// through the engine's one key fold, so `Taper`, `taper` and
    /// `taper[0]` are the same key here exactly as they are to a
    /// keyEquals rule.
    public func matches(payloadKeys: Set<String>) -> Bool {
        let required = keys.filter(\.required).map { KeyNormalizer.normalize($0.key) }
        guard !required.isEmpty else { return false }
        let folded = Set(payloadKeys.map { KeyNormalizer.normalize($0) })
        return required.allSatisfy { folded.contains($0) }
    }

    /// folded key → category name, for the keys this schema maps.
    public var categoryByFoldedKey: [String: String] {
        Dictionary(
            keys.compactMap { key in
                key.category.map { (KeyNormalizer.normalize(key.key), $0) }
            },
            uniquingKeysWith: { first, _ in first })
    }
}

public enum JsonSchemaError: Error, Equatable, CustomStringConvertible {
    case nameTaken(String)
    case notFound

    public var description: String {
        switch self {
        case .nameTaken(let name): "a schema named “\(name)” already exists — select it to edit it"
        case .notFound: "that schema no longer exists"
        }
    }
}

extension LibraryDatabase {

    public func jsonSchemas() throws -> [JsonSchemaDefinition] {
        try writer.read { db in
            try JsonSchemaDefinition.order(sql: "name COLLATE NOCASE").fetchAll(db)
        }
    }

    /// Save under a name — an existing name is replaced in place, same
    /// identity, exactly as saved filters behave.
    @discardableResult
    public func saveJsonSchema(named rawName: String, keys: [SchemaKey]) throws -> JsonSchemaDefinition {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw DatabaseError(message: "a schema needs a name")
        }
        let json = String(data: try JSONEncoder().encode(keys), encoding: .utf8) ?? "[]"
        return try writer.write { db in
            if var existing = try JsonSchemaDefinition
                .filter(sql: "name = ? COLLATE NOCASE", arguments: [name])
                .fetchOne(db)
            {
                existing.name = name
                existing.definitionJSON = json
                try existing.update(db)
                return existing
            }
            let made = JsonSchemaDefinition(name: name, definitionJSON: json)
            try made.insert(db)
            return made
        }
    }

    /// Save what the editor has open: the schema with this id (a rename
    /// changes that one schema), or a new one when `id` is nil. A name
    /// that belongs to ANOTHER schema is refused — the by-name save above
    /// would have made a second schema on a rename, or replaced someone
    /// else's keys on a new one.
    @discardableResult
    public func saveJsonSchema(
        id: UUID?, named rawName: String, keys: [SchemaKey]
    ) throws -> JsonSchemaDefinition {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw DatabaseError(message: "a schema needs a name")
        }
        let json = String(data: try JSONEncoder().encode(keys), encoding: .utf8) ?? "[]"
        return try writer.write { db in
            if let holder = try JsonSchemaDefinition
                .filter(sql: "name = ? COLLATE NOCASE", arguments: [name])
                .fetchOne(db), holder.id != id
            {
                throw JsonSchemaError.nameTaken(name)
            }
            guard let id else {
                let made = JsonSchemaDefinition(name: name, definitionJSON: json)
                try made.insert(db)
                return made
            }
            guard var existing = try JsonSchemaDefinition.fetchOne(db, key: id) else {
                throw JsonSchemaError.notFound
            }
            existing.name = name
            existing.definitionJSON = json
            try existing.update(db)
            return existing
        }
    }

    public func deleteJsonSchema(_ id: UUID) throws {
        _ = try writer.write { db in
            try JsonSchemaDefinition.deleteOne(db, key: id)
        }
    }
}
