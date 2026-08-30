import Foundation
import GRDB

/// How tag names typed or pasted into a category are normalized on save.
/// Raw values match the old app's enum order for the migrator's sake.
public enum TextFormat: Int, Codable, Sendable, CaseIterable {
    case noFormatting = 0
    case titleCase = 1
    case allLowercase = 2
    case allUppercase = 3
}

/// A classification within one library's vocabulary — Band, Venue, Subject.
/// Not a loose bundle: it carries rules about how many values apply, how
/// they display, and how they write back to file metadata (which is why
/// the old name "group" is banned).
public struct TagCategory: Codable, Equatable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "tagCategory"

    public var id: UUID
    public var name: String
    /// May an item carry several tags from this category (Band: yes,
    /// Year: no)?
    public var allowMultiple: Bool
    /// Render as a checkbox list of every tag instead of pill+autocomplete;
    /// also makes the category eligible for keyboard toggles.
    public var displayAsCheckboxes: Bool
    public var sortOrder: Int
    public var notes: String
    /// Hide from the browse filter panel (still available in editing).
    public var hiddenFromBrowse: Bool
    /// Index into the fixed hue palette. Pills, swatches and filter chips
    /// in three windows read it, so the colour is stored once here rather
    /// than invented per surface — and it is an index, not a hex, so a
    /// palette change moves every category at once. Wraps: an index past
    /// the palette is stable, never a crash or a default grey.
    public var colorIndex: Int
    /// Section separator above this category in the browse panel:
    /// nil = none, "" = plain divider, non-empty = labeled header.
    public var sectionLabel: String?
    /// The tag editor focuses this category's input on open. At most one
    /// category has it — enforced by the write path, as in the old app.
    public var isDefaultFocus: Bool
    public var textFormat: TextFormat
    /// Convert `-`/`.`/`_` to spaces (collapsing runs) before `textFormat`
    /// applies — "dave-matthews-band" + titleCase → "Dave Matthews Band".
    public var separatorsToSpaces: Bool
    /// Whether this category's tags are written to file metadata.
    public var writebackEnabled: Bool
    /// nil = auto (uppercased name as a custom field); non-nil = a
    /// standard-field key (ARTIST, DATE, …).
    public var writebackField: String?

    public init(
        id: UUID = UUID(),
        name: String,
        allowMultiple: Bool = true,
        displayAsCheckboxes: Bool = false,
        sortOrder: Int = 0,
        notes: String = "",
        hiddenFromBrowse: Bool = false,
        colorIndex: Int = 0,
        sectionLabel: String? = nil,
        isDefaultFocus: Bool = false,
        textFormat: TextFormat = .noFormatting,
        separatorsToSpaces: Bool = false,
        writebackEnabled: Bool = true,
        writebackField: String? = nil
    ) {
        self.id = id
        self.name = name
        self.allowMultiple = allowMultiple
        self.displayAsCheckboxes = displayAsCheckboxes
        self.sortOrder = sortOrder
        self.notes = notes
        self.hiddenFromBrowse = hiddenFromBrowse
        self.colorIndex = colorIndex
        self.sectionLabel = sectionLabel
        self.isDefaultFocus = isDefaultFocus
        self.textFormat = textFormat
        self.separatorsToSpaces = separatorsToSpaces
        self.writebackEnabled = writebackEnabled
        self.writebackField = writebackField
    }
}
