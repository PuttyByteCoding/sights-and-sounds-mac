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
            for planned in plan.categories where planned.include {
                let category = TagCategory(
                    name: planned.name.trimmingCharacters(in: .whitespaces),
                    allowMultiple: planned.allowMultiple,
                    displayAsCheckboxes: planned.displayAsCheckboxes,
                    sortOrder: planned.sortOrder,
                    notes: planned.notes,
                    hiddenFromBrowse: planned.hiddenFromBrowse,
                    sectionLabel: planned.sectionLabel,
                    isDefaultFocus: planned.isDefaultFocus,
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
