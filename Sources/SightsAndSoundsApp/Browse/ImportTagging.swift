import Foundation
import SightsAndSoundsKit

/// The Import window as the tag panel's host: the subject is the import
/// in hand, and a tag picked is staged for every file in it rather than
/// written to an item. The window used to stage tags in boxes of its own
/// that offered five plain matches and nothing for the keyboard; it now
/// shows the player's panel, so tagging an import is the same typing,
/// arrowing and Enter as tagging a video.
///
/// It owns what is staged and the boxes that say what stays for the
/// next import, so the panel and the window read one copy of each.
@Observable @MainActor
final class ImportTagging: TagPanelHost {
    let service: any LibraryService
    let libraryID: UUID
    /// The library window's vocabulary changed hands: ask it to read
    /// again (a tag made or edited here, the categories reordered).
    @ObservationIgnored var onVocabularyChanged: () -> Void = {}

    /// What the import will apply.
    var draft = StagingDraft()
    /// The saved boxes: media-item fields shown under the panel, and
    /// which categories are sticky.
    var boxes: [ImportBox] = []
    /// A write that failed, for the window's notice line.
    var failure: String?

    private(set) var panelVocabulary: [CategoryTags] = []
    private(set) var tagSearchIndex: [TagSearchEntry] = []
    private(set) var recentlyAppliedTagIDs: [UUID] = []
    var tagFieldCategoryID: UUID?
    var tagFieldListOpen = false
    /// Bumped when the stored row order changes, so the rows re-read it.
    private var rowOrderVersion = 0

    /// Saves of the boxes, one at a time in the order made.
    @ObservationIgnored private let boxWrites = WriteQueue()

    init(service: any LibraryService, libraryID: UUID) {
        self.service = service
        self.libraryID = libraryID
    }

    /// The library's vocabulary as the browse window has it.
    func show(vocabulary: [CategoryTags], aliases: [UUID: [String]]) {
        panelVocabulary = vocabulary
        tagSearchIndex = TagSearchEntry.index(
            vocabulary: vocabulary.map { ($0.category, $0.tags) }, aliases: aliases)
    }

    // MARK: TagPanelHost

    /// One subject for the window's life: the fields are not reset
    /// between imports, and the first one takes the keyboard once.
    let taggingSubjectID: UUID? = UUID()
    var removalLabel: String { "Remove from This Import" }
    var actionItemID: UUID? { nil }
    /// Alt+1…9 is the player's key handler; there is none here, so no
    /// checkbox list claims the keys.
    var checkboxCategory: CategoryTags? { nil }

    /// The player's order, without the Tag Analysis row: there is no
    /// playing item for it to read.
    var panelRows: [PanelRow] { storedRows.filter { $0 != .results } }

    /// The order the player keeps, Tag Analysis row included.
    private var storedRows: [PanelRow] {
        _ = rowOrderVersion
        let settings = AppSettingsStore.shared.current
        return TagPanelOrder.rows(
            vocabulary: panelVocabulary.map(\.category.id),
            stored: settings.tagPanelRowOrder,
            seed: (
                universal: settings.universalTagFieldPosition,
                results: settings.analysisResultsFieldPosition))
    }

    var itemTags: [CategoryTags] {
        let staged = Set(draft.tagIDs)
        return panelVocabulary.compactMap { entry in
            let tags = entry.tags.filter { staged.contains($0.id) }
            return tags.isEmpty ? nil : CategoryTags(category: entry.category, tags: tags)
        }
    }

    func hasTag(_ tagID: UUID) -> Bool { draft.tagIDs.contains(tagID) }

    /// Staged or unstaged. A radio category holds one tag, so staging
    /// one of its tags replaces the other.
    func toggleTag(_ tagID: UUID) {
        if let index = draft.tagIDs.firstIndex(of: tagID) {
            draft.tagIDs.remove(at: index)
            return
        }
        if let entry = panelVocabulary.first(where: { $0.tags.contains { $0.id == tagID } }),
           entry.category.displayStyle == .radio {
            let siblings = Set(entry.tags.map(\.id))
            draft.tagIDs.removeAll { siblings.contains($0) }
        }
        draft.tagIDs.append(tagID)
        recentlyAppliedTagIDs.removeAll { $0 == tagID }
        recentlyAppliedTagIDs.insert(tagID, at: 0)
        if recentlyAppliedTagIDs.count > 30 { recentlyAppliedTagIDs.removeLast() }
    }

    func refreshTagging() { onVocabularyChanged() }

    /// The same drag as the player's, on the same stored order: moved
    /// in the full list, so the hidden Tag Analysis row keeps its place.
    func movePanelRow(_ row: PanelRow, before target: PanelRow?) {
        let stored = storedRows
        let rows = TagPanelOrder.moved(stored, row, before: target)
        guard rows != stored else { return }
        AppSettingsStore.shared.update { $0.tagPanelRowOrder = rows.map(\.key) }
        rowOrderVersion += 1
        let order = rows.compactMap(\.categoryID), service = service
        Task { [weak self] in
            do {
                try await service.setCategoryOrder(order)
                self?.onVocabularyChanged()
            } catch {
                self?.failure = "Could not reorder the categories: \(error)"
            }
        }
    }

    func tagFieldFocused() {}

    func sticky(for categoryID: UUID) -> Bool? {
        boxes.first { $0.categoryID == categoryID }?.sticky ?? false
    }

    func setSticky(_ sticky: Bool, for categoryID: UUID) {
        if let index = boxes.firstIndex(where: { $0.categoryID == categoryID }) {
            boxes[index].sticky = sticky
        } else {
            boxes.append(ImportBox(source: .category(categoryID), sticky: sticky))
        }
        saveBoxes()
    }

    // MARK: Boxes

    func saveBoxes() {
        let service = service, boxes = boxes
        boxWrites.send { try await service.setImportBoxes(boxes) }
    }

    /// What the sticky boxes kept from the last import, only values that
    /// still exist: a sticky tag since deleted left a dead id in the draft
    /// that showed as an empty "Will apply" with no pill to remove.
    func stickyDraft() -> StagingDraft {
        let present = Set(panelVocabulary.flatMap(\.tags).map(\.id))
        return StagingDraft(
            tagIDs: boxes.filter(\.sticky).flatMap(\.stickyTagIDs).filter { present.contains($0) },
            fieldValues: Dictionary(
                uniqueKeysWithValues: boxes.compactMap { box in
                    guard box.sticky, let fieldID = box.fieldID,
                          let value = box.stickyValue else { return nil }
                    return (fieldID, value)
                }))
    }

    /// An import landed: the sticky boxes keep what was staged in them.
    func persistSticky(from draft: StagingDraft) {
        for index in boxes.indices where boxes[index].sticky {
            if let categoryID = boxes[index].categoryID {
                let inCategory = Set(panelVocabulary
                    .first { $0.category.id == categoryID }?.tags.map(\.id) ?? [])
                boxes[index].stickyTagIDs = draft.tagIDs.filter { inCategory.contains($0) }
            }
            if let fieldID = boxes[index].fieldID {
                boxes[index].stickyValue = draft.fieldValues[fieldID]
            }
        }
        saveBoxes()
    }
}
