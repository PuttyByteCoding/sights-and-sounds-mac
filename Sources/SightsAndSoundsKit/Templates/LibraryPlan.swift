import Foundation

/// An editable blueprint for a library's vocabulary — the data model behind
/// the category review screen.
///
/// Both ways a library comes into being produce one of these: template-based
/// creation (`LibraryTemplate.plan(named:)`) and snapshot migration (the
/// migrator builds a plan from the old vocabulary). The review screen edits
/// the plan — rename, exclude, adjust — and `LibraryCreator` executes it.
/// Built once, used by both flows, exactly as the brief specifies.
public struct LibraryPlan: Sendable, Equatable, Codable {
    public var name: String
    public var categories: [PlannedCategory]
    /// Media-item-scope fields (tag-scope fields live on their category).
    public var itemFields: [PlannedItemField]

    public init(name: String, categories: [PlannedCategory] = [], itemFields: [PlannedItemField] = []) {
        self.name = name
        self.categories = categories
        self.itemFields = itemFields
    }

    /// Problems that would make the plan unwritable. Empty means valid.
    public func validationErrors() -> [String] {
        var errors: [String] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            errors.append("The library needs a name.")
        }

        let included = categories.filter(\.include)
        var seen: Set<String> = []
        for category in included {
            let trimmed = category.name.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                errors.append("A category has an empty name.")
                continue
            }
            if !seen.insert(trimmed.lowercased()).inserted {
                errors.append("Duplicate category name '\(trimmed)'.")
            }
        }
        if included.filter(\.isDefaultFocus).count > 1 {
            errors.append("At most one category can be the default focus.")
        }

        var fieldSeen: Set<String> = []
        for field in itemFields where field.include {
            let trimmed = field.name.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                errors.append("A field has an empty name.")
                continue
            }
            if !fieldSeen.insert(trimmed.lowercased()).inserted {
                errors.append("Duplicate field name '\(trimmed)'.")
            }
        }
        return errors
    }
}

/// One category in the plan. `originalName` keeps what the template or the
/// old library called it, so the review screen can show "renamed from …".
public struct PlannedCategory: Sendable, Equatable, Identifiable, Codable {
    public var id: UUID
    /// Unchecked in review = not created. Nothing is written for an
    /// excluded category — its tags and fields simply don't exist.
    public var include: Bool
    public var name: String
    public let originalName: String

    public var allowMultiple: Bool
    public var displayAsCheckboxes: Bool
    public var sortOrder: Int
    public var notes: String
    public var hiddenFromBrowse: Bool
    public var sectionLabel: String?
    public var isDefaultFocus: Bool
    public var textFormat: TextFormat
    public var separatorsToSpaces: Bool
    public var writebackEnabled: Bool
    public var writebackField: String?

    public var tags: [PlannedTag]
    /// Tag-scope fields attached to this category.
    public var fields: [PlannedTagField]

    public init(
        id: UUID = UUID(),
        include: Bool = true,
        name: String,
        allowMultiple: Bool = true,
        displayAsCheckboxes: Bool = false,
        sortOrder: Int = 0,
        notes: String = "",
        hiddenFromBrowse: Bool = false,
        sectionLabel: String? = nil,
        isDefaultFocus: Bool = false,
        textFormat: TextFormat = .noFormatting,
        separatorsToSpaces: Bool = false,
        writebackEnabled: Bool = true,
        writebackField: String? = nil,
        tags: [PlannedTag] = [],
        fields: [PlannedTagField] = []
    ) {
        self.id = id
        self.include = include
        self.name = name
        self.originalName = name
        self.allowMultiple = allowMultiple
        self.displayAsCheckboxes = displayAsCheckboxes
        self.sortOrder = sortOrder
        self.notes = notes
        self.hiddenFromBrowse = hiddenFromBrowse
        self.sectionLabel = sectionLabel
        self.isDefaultFocus = isDefaultFocus
        self.textFormat = textFormat
        self.separatorsToSpaces = separatorsToSpaces
        self.writebackEnabled = writebackEnabled
        self.writebackField = writebackField
        self.tags = tags
        self.fields = fields
    }
}

public struct PlannedTag: Sendable, Equatable, Codable {
    public var name: String
    public var aliases: [String]
    public var isFavorite: Bool
    public var sortOrder: Int
    public var notes: String
    public var hiddenByDefault: Bool

    public init(
        name: String, aliases: [String] = [], isFavorite: Bool = false,
        sortOrder: Int = 0, notes: String = "", hiddenByDefault: Bool = false
    ) {
        self.name = name
        self.aliases = aliases
        self.isFavorite = isFavorite
        self.sortOrder = sortOrder
        self.notes = notes
        self.hiddenByDefault = hiddenByDefault
    }
}

public struct PlannedTagField: Sendable, Equatable, Codable {
    public var name: String
    public var dataType: FieldDataType
    public var required: Bool
    public var sortOrder: Int
    public var notes: String

    public init(
        name: String, dataType: FieldDataType = .text, required: Bool = false,
        sortOrder: Int = 0, notes: String = ""
    ) {
        self.name = name
        self.dataType = dataType
        self.required = required
        self.sortOrder = sortOrder
        self.notes = notes
    }
}

public struct PlannedItemField: Sendable, Equatable, Identifiable, Codable {
    public var id: UUID
    public var include: Bool
    public var name: String
    public var dataType: FieldDataType
    public var required: Bool
    public var sortOrder: Int
    public var notes: String

    public init(
        id: UUID = UUID(), include: Bool = true, name: String,
        dataType: FieldDataType = .text, required: Bool = false,
        sortOrder: Int = 0, notes: String = ""
    ) {
        self.id = id
        self.include = include
        self.name = name
        self.dataType = dataType
        self.required = required
        self.sortOrder = sortOrder
        self.notes = notes
    }
}
