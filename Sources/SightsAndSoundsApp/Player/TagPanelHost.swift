import Foundation
import SightsAndSoundsKit

/// What the tag panel tags, and how. The player is one host: the item on
/// screen, written as each tag is picked. The Import window is the
/// other: the tags staged for the files about to go in, written when the
/// import runs. One panel serves both, so tagging an import is the same
/// typing, arrowing and Enter as tagging a video. The Import window used
/// to have its own boxes, which offered five plain matches and nothing
/// for the keyboard.
///
/// A host is an `@Observable` class: the panel reads it through this
/// protocol, and observation follows the concrete type's properties.
@MainActor
protocol TagPanelHost: AnyObject {
    var service: any LibraryService { get }
    var libraryID: UUID { get }

    /// Every category the panel draws, with its tags.
    var panelVocabulary: [CategoryTags] { get }
    /// The panel's rows in order.
    var panelRows: [PanelRow] { get }
    /// The tags the subject wears (or has staged), by category.
    var itemTags: [CategoryTags] { get }
    var tagSearchIndex: [TagSearchEntry] { get }
    /// Applied this session, newest first: the ↑ history.
    var recentlyAppliedTagIDs: [UUID] { get }
    /// The category whose tags Alt+1…9 toggles.
    var checkboxCategory: CategoryTags? { get }

    /// Which field holds the keyboard, mirrored from the panel's focus.
    var tagFieldCategoryID: UUID? { get set }
    var tagFieldListOpen: Bool { get set }

    /// What is being tagged. A change resets the fields, and the first
    /// field takes the keyboard.
    var taggingSubjectID: UUID? { get }
    /// The right-click removal's wording.
    var removalLabel: String { get }
    /// The item a right-click's "Replace…" concerns; nil replaces
    /// everywhere.
    var actionItemID: UUID? { get }

    func hasTag(_ tagID: UUID) -> Bool
    func toggleTag(_ tagID: UUID)
    /// The vocabulary changed (a tag was made or edited): read it again.
    func refreshTagging()
    func movePanelRow(_ row: PanelRow, before target: PanelRow?)
    /// A tag field took the keyboard.
    func tagFieldFocused()

    /// The player, for the parts that need a playing item: the screen
    /// read, Tag Analysis, the digit keys and the zone badge. nil hides
    /// them.
    var playerModel: PlayerModel? { get }

    /// Names offered under a category's matches that are not tags yet —
    /// the Import window's words from the folder name.
    func extraNames(for categoryID: UUID) -> [String]
    /// One of those names picked: make it a tag, then apply it.
    func applyName(_ name: String, in categoryID: UUID)
    /// Whether a category keeps its tags for the next import; nil draws
    /// no control.
    func sticky(for categoryID: UUID) -> Bool?
    func setSticky(_ sticky: Bool, for categoryID: UUID)
}

extension TagPanelHost {
    var playerModel: PlayerModel? { nil }
    func extraNames(for categoryID: UUID) -> [String] { [] }
    func applyName(_ name: String, in categoryID: UUID) {}
    func sticky(for categoryID: UUID) -> Bool? { nil }
    func setSticky(_ sticky: Bool, for categoryID: UUID) {}

    /// Move the keyboard to the next (or previous) field, wrapping. The
    /// walk is the panel's order minus the checkbox categories, which
    /// have no field. False when there is nothing to walk, so the caller
    /// can fall back to the zone walk.
    @discardableResult
    func advanceTagField(reverse: Bool) -> Bool {
        let typable = Set(panelVocabulary.filter { $0.category.displayStyle == .search }.map(\.id))
        let fields = panelRows.compactMap { row -> UUID? in
            if let id = row.categoryID { return typable.contains(id) ? id : nil }
            return row.focusID
        }
        guard !fields.isEmpty else { return false }
        guard let current = tagFieldCategoryID, let index = fields.firstIndex(of: current)
        else {
            tagFieldCategoryID = fields.first
            return true
        }
        let next = (index + (reverse ? fields.count - 1 : 1)) % fields.count
        tagFieldCategoryID = fields[next]
        return true
    }
}
