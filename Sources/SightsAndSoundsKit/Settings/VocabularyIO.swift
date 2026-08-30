import Foundation
import GRDB

/// Vocabulary export/import — a library's categories, tags, aliases and
/// fields as a JSON file. The format IS `LibraryPlan` (the same shape the
/// creation templates and the migrator's review use), so one format
/// serves templates, migration review and interchange.
public enum VocabularyIO {
    /// The library's full vocabulary as a plan.
    public static func exportPlan(from library: LibraryDatabase) throws -> LibraryPlan {
        try library.writer.read { db in
            let categories = try TagCategory.order(sql: "sortOrder, name").fetchAll(db)
            let tags = try Tag.order(sql: "sortOrder, name").fetchAll(db)
            let aliases = try TagAlias.fetchAll(db)
            let fields = try FieldDefinition.order(sql: "sortOrder, name").fetchAll(db)

            let tagsByCategory = Dictionary(grouping: tags, by: \.tagCategoryID)
            let aliasesByTag = Dictionary(grouping: aliases, by: \.tagID)
            let tagFields = Dictionary(
                grouping: fields.filter { $0.scope == .tag }, by: { $0.tagCategoryID! })

            let planned = categories.map { category in
                PlannedCategory(
                    name: category.name,
                    allowMultiple: category.allowMultiple,
                    displayStyle: category.displayStyle,
                    sortOrder: category.sortOrder,
                    notes: category.notes,
                    hiddenFromBrowse: category.hiddenFromBrowse,
                    sectionLabel: category.sectionLabel,
                    textFormat: category.textFormat,
                    separatorsToSpaces: category.separatorsToSpaces,
                    writebackEnabled: category.writebackEnabled,
                    writebackField: category.writebackField,
                    tags: (tagsByCategory[category.id] ?? []).map { tag in
                        PlannedTag(
                            name: tag.name,
                            aliases: (aliasesByTag[tag.id] ?? []).map(\.alias).sorted(),
                            isFavorite: tag.isFavorite,
                            sortOrder: tag.sortOrder,
                            notes: tag.notes,
                            hiddenByDefault: tag.hiddenByDefault)
                    },
                    fields: (tagFields[category.id] ?? []).map { field in
                        PlannedTagField(
                            name: field.name, dataType: field.dataType,
                            required: field.required, sortOrder: field.sortOrder,
                            notes: field.notes)
                    })
            }
            let itemFields = fields.filter { $0.scope == .mediaItem }.map { field in
                PlannedItemField(
                    name: field.name, dataType: field.dataType,
                    required: field.required, sortOrder: field.sortOrder, notes: field.notes)
            }
            let name = (try LibraryInfo.fetchOne(db)?.name) ?? "Library"
            return LibraryPlan(name: name, categories: planned, itemFields: itemFields)
        }
    }

    public static func exportJSON(from library: LibraryDatabase) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(try exportPlan(from: library))
    }

    public struct ImportOutcome: Sendable, Equatable {
        public var categoriesCreated = 0
        public var tagsCreated = 0
        public var fieldsCreated = 0
        public var skippedExisting = 0
    }

    /// Merge a vocabulary file into a library: categories match by name
    /// (case-insensitive) and keep their existing configuration; missing
    /// categories, tags, aliases and fields are created. Never deletes,
    /// never reconfigures — import is additive by design.
    @discardableResult
    public static func importJSON(_ data: Data, into library: LibraryDatabase) throws -> ImportOutcome {
        let plan = try JSONDecoder().decode(LibraryPlan.self, from: data)
        var outcome = ImportOutcome()

        for planned in plan.categories where planned.include {
            let existing = try library.writer.read { db in
                try TagCategory
                    .filter(sql: "name = ?", arguments: [planned.name])
                    .fetchOne(db)
            }
            let category: TagCategory
            if let existing {
                category = existing
                outcome.skippedExisting += 1
            } else {
                category = TagCategory(
                    name: planned.name,
                    allowMultiple: planned.allowMultiple,
                    displayStyle: planned.displayStyle,
                    sortOrder: planned.sortOrder,
                    notes: planned.notes,
                    hiddenFromBrowse: planned.hiddenFromBrowse,
                    sectionLabel: planned.sectionLabel,
                    textFormat: planned.textFormat,
                    separatorsToSpaces: planned.separatorsToSpaces,
                    writebackEnabled: planned.writebackEnabled,
                    writebackField: planned.writebackField)
                try library.createCategory(category)
                outcome.categoriesCreated += 1
            }

            let existingTags = Set(try library.writer.read { db in
                try String.fetchAll(
                    db, sql: "SELECT name FROM tag WHERE tagCategoryID = ?",
                    arguments: [category.id])
            }.map { $0.lowercased() })
            for plannedTag in planned.tags {
                if existingTags.contains(plannedTag.name.lowercased()) {
                    outcome.skippedExisting += 1
                    continue
                }
                let tag = try library.ensureTag(named: plannedTag.name, inCategory: category.id)
                for alias in plannedTag.aliases {
                    try library.addAlias(alias, toTag: tag.id)
                }
                if plannedTag.hiddenByDefault {
                    try library.setTagHidden(tag.id, true)
                }
                outcome.tagsCreated += 1
            }

            let existingFields = Set(try library.writer.read { db in
                try String.fetchAll(
                    db, sql: "SELECT name FROM fieldDefinition WHERE tagCategoryID = ?",
                    arguments: [category.id])
            }.map { $0.lowercased() })
            for field in planned.fields where !existingFields.contains(field.name.lowercased()) {
                try library.writer.write { db in
                    try FieldDefinition(
                        name: field.name, dataType: field.dataType, scope: .tag,
                        tagCategoryID: category.id, required: field.required,
                        sortOrder: field.sortOrder, notes: field.notes).insert(db)
                }
                outcome.fieldsCreated += 1
            }
        }

        let existingItemFields = Set(try library.writer.read { db in
            try String.fetchAll(
                db, sql: "SELECT name FROM fieldDefinition WHERE scope = 'mediaItem'")
        }.map { $0.lowercased() })
        for field in plan.itemFields where field.include {
            if existingItemFields.contains(field.name.lowercased()) {
                outcome.skippedExisting += 1
                continue
            }
            try library.writer.write { db in
                try FieldDefinition(
                    name: field.name, dataType: field.dataType, scope: .mediaItem,
                    required: field.required, sortOrder: field.sortOrder,
                    notes: field.notes).insert(db)
            }
            outcome.fieldsCreated += 1
        }
        return outcome
    }
}
