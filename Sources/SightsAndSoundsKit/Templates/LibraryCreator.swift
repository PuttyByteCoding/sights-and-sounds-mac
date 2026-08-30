import Foundation
import GRDB

public struct LibraryPlanError: Error, CustomStringConvertible {
    public let problems: [String]
    public var description: String {
        "invalid library plan: " + problems.joined(separator: " ")
    }
}

/// Executes a reviewed `LibraryPlan`: creates the library file, stamps its
/// identity, writes the vocabulary, and (optionally) adds the first source
/// and registers the library with the app store.
///
/// Nothing is written until the whole plan validates — the review screen's
/// contract is "adjust freely, nothing exists yet".
/// What a freshly created library actually contains, read back.
///
/// A migration that wrote the wrong thing is far cheaper to catch now
/// than after a week of tagging, and the same read-back is worth having
/// for a template: it is the difference between "Create succeeded" and
/// "here is what exists".
public struct CreationVerification: Sendable, Equatable {
    public var categories: Int
    public var tags: Int
    public var aliases: Int
    public var fields: Int

    /// What the plan said should exist. A mismatch on any row is the
    /// finding.
    public static func expected(from plan: LibraryPlan) -> CreationVerification {
        let included = plan.categories.filter(\.include)
        return CreationVerification(
            categories: included.count,
            tags: included.reduce(0) { $0 + $1.tags.count },
            aliases: included.reduce(0) { $0 + $1.tags.reduce(0) { $0 + $1.aliases.count } },
            fields: included.reduce(0) { $0 + $1.fields.count }
                + plan.itemFields.filter(\.include).count)
    }

    public func matches(_ other: CreationVerification) -> Bool { self == other }
}

extension LibraryDatabase {
    /// Read the library back and count what is in it.
    public func creationVerification() throws -> CreationVerification {
        try writer.read { db in
            CreationVerification(
                categories: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tagCategory") ?? 0,
                tags: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tag") ?? 0,
                aliases: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tagAlias") ?? 0,
                fields: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM fieldDefinition") ?? 0)
        }
    }
}

public enum LibraryCreator {
    @discardableResult
    public static func create(
        at url: URL,
        plan: LibraryPlan,
        firstSource: Source? = nil,
        registerIn app: AppDatabase? = nil
    ) throws -> LibraryDatabase {
        let problems = plan.validationErrors()
        guard problems.isEmpty else { throw LibraryPlanError(problems: problems) }

        let library = try LibraryDatabase.open(at: url)
        try library.ensureInfo(name: plan.name)

        try library.writer.write { db in
            // The colour is dealt in plan order, so a new library's
            // categories never open with two of them the same hue.
            for (hue, planned) in plan.categories.filter(\.include).enumerated() {
                let category = TagCategory(
                    name: planned.name.trimmingCharacters(in: .whitespaces),
                    allowMultiple: planned.allowMultiple,
                    displayStyle: planned.displayStyle,
                    sortOrder: planned.sortOrder,
                    notes: planned.notes,
                    hiddenFromBrowse: planned.hiddenFromBrowse,
                    // The plan's hue when the template seeded one;
                    // otherwise dealt in plan order, so no two
                    // categories open the same colour.
                    colorIndex: planned.colorIndex == 0 ? hue : planned.colorIndex,
                    sectionLabel: planned.sectionLabel,
                    textFormat: planned.textFormat,
                    separatorsToSpaces: planned.separatorsToSpaces,
                    writebackEnabled: planned.writebackEnabled,
                    writebackField: planned.writebackField)
                try category.insert(db)

                for plannedTag in planned.tags {
                    let tag = Tag(
                        tagCategoryID: category.id,
                        name: plannedTag.name,
                        hiddenByDefault: plannedTag.hiddenByDefault,
                        isFavorite: plannedTag.isFavorite,
                        sortOrder: plannedTag.sortOrder,
                        notes: plannedTag.notes)
                    try tag.insert(db)
                    for alias in plannedTag.aliases {
                        try TagAlias(tagID: tag.id, alias: alias).insert(db)
                    }
                }

                for plannedField in planned.fields {
                    try FieldDefinition(
                        name: plannedField.name,
                        dataType: plannedField.dataType,
                        scope: .tag,
                        tagCategoryID: category.id,
                        required: plannedField.required,
                        sortOrder: plannedField.sortOrder,
                        notes: plannedField.notes).insert(db)
                }
            }

            for field in plan.itemFields where field.include {
                try FieldDefinition(
                    name: field.name.trimmingCharacters(in: .whitespaces),
                    dataType: field.dataType,
                    scope: .mediaItem,
                    required: field.required,
                    sortOrder: field.sortOrder,
                    notes: field.notes).insert(db)
            }

            if let source = firstSource {
                try source.insert(db)
            }
        }

        if let app {
            try app.register(library)
        }
        return library
    }
}
