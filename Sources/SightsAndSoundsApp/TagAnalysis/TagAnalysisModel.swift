import Foundation
import GRDB
import Observation
import SightsAndSoundsKit

/// The per-video analysis window's state: the queue being walked, the
/// displayed video's analysis, and the basket of tags staged for it.
///
/// **Nothing writes until the basket commits** — on advance (either
/// direction), window close, or an explicit Save. That is the reviewed
/// decision: finish judging a video, then its tags land together.
@Observable
@MainActor
final class TagAnalysisModel {

    let library: LibraryDatabase
    let libraryID: UUID

    /// The queue this window walks — the same listing the player takes.
    /// Analysis always looks at ONE video, `queue[index]`: metadata from
    /// one video is not evidence about another.
    private(set) var queue: [UUID]
    private(set) var index: Int
    private(set) var currentItem: MediaItem?

    private(set) var analysis: ItemAnalysis = .empty
    private(set) var rules: [RuleEngine.Rule] = []
    private(set) var categories: [TagCategory] = []
    private(set) var isLoading = false
    private(set) var loadError: String?

    /// Tags staged for the DISPLAYED video. Values stay editable in here
    /// right up to commit.
    private(set) var basket: [PendingTag] = []

    /// What this pass over the queue has written so far.
    private(set) var tagsCommittedThisPass = 0
    private(set) var videosVisitedThisPass = 1

    var searchText = ""
    var selectedCandidateID: AnalysisCandidate.ID?

    init(library: LibraryDatabase, libraryID: UUID, queue: [UUID], startAt: Int = 0) {
        self.library = library
        self.libraryID = libraryID
        self.queue = queue
        self.index = queue.indices.contains(startAt) ? startAt : 0
    }

    var currentItemID: UUID? {
        queue.indices.contains(index) ? queue[index] : nil
    }

    // MARK: - Derived

    var selectedCandidate: AnalysisCandidate? {
        (analysis.suggested + analysis.unmapped).first { $0.id == selectedCandidateID }
    }

    var visibleSuggested: [AnalysisCandidate] { filtered(analysis.suggested) }
    var visibleUnmapped: [AnalysisCandidate] { filtered(analysis.unmapped) }

    var visibleExisting: [ExistingTagFinding] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return analysis.existing }
        return analysis.existing.filter {
            $0.tag.name.localizedCaseInsensitiveContains(query)
                || $0.foundIn.localizedCaseInsensitiveContains(query)
        }
    }

    private func filtered(_ candidates: [AnalysisCandidate]) -> [AnalysisCandidate] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return candidates }
        return candidates.filter {
            $0.value.localizedCaseInsensitiveContains(query)
                || ($0.key?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    /// Already staged, so a row can say "in the basket" instead of
    /// offering itself twice.
    func isStaged(value: String, categoryID: UUID?) -> Bool {
        basket.contains {
            $0.value.caseInsensitiveCompare(value) == .orderedSame
                && (categoryID == nil || $0.categoryID == categoryID)
        }
    }

    func isStaged(tagID: UUID) -> Bool {
        basket.contains { $0.existingTagID == tagID }
    }

    func category(named name: String) -> TagCategory? {
        categories.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    // MARK: - Walking the queue

    var canGoPrevious: Bool { index > 0 }
    var canGoNext: Bool { index + 1 < queue.count }

    func goNext() { step(1) }
    func goPrevious() { step(-1) }

    /// Clamped at the ends, like the player. **Advancing commits the
    /// basket first** — that is the contract: finish a video, move on,
    /// its tags are saved — then the working state clears, because all
    /// of it points at strings the next video may not contain.
    private func step(_ delta: Int) {
        let next = index + delta
        guard queue.indices.contains(next) else { return }
        commitBasket()
        index = next
        videosVisitedThisPass += 1
        selectedCandidateID = nil
        searchText = ""
        analysis = .empty
        reload()
    }

    // MARK: - Loading

    func reload() {
        guard let itemID = currentItemID else {
            analysis = .empty
            return
        }
        isLoading = true
        let library = library
        Task {
            do {
                let rules = try library.analysisRules()
                let categories = try library.vocabulary().map(\.category)
                // The pipeline reads disk (sidecars) and walks the parser
                // — off the main actor, so a slow folder never freezes
                // the arrows.
                let analysis = try await Task.detached(priority: .userInitiated) {
                    try library.analyzeItem(itemID, rules: rules)
                }.value
                // The queue may have advanced while this ran; results for
                // a video no longer displayed are dropped, not shown.
                guard itemID == self.currentItemID else { return }
                self.rules = rules
                self.categories = categories
                self.analysis = analysis
                self.currentItem = try await library.writer.read {
                    try MediaItem.fetchOne($0, key: itemID)
                }
                self.loadError = nil
            } catch {
                self.loadError = "\(error)"
            }
            self.isLoading = false
        }
    }

    /// The sweep runs on the job runner; the model only tracks that one
    /// is in flight.
    func beginSweep() { isLoading = true }
    func finishSweep() { reload() }

    // MARK: - The basket

    /// Stage a candidate — value already edited by the caller if the
    /// operator trimmed it by hand.
    func stage(value: String, categoryID: UUID, existingTagID: UUID? = nil) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !isStaged(value: trimmed, categoryID: categoryID) else { return }
        basket.append(
            PendingTag(value: trimmed, categoryID: categoryID, existingTagID: existingTagID))
    }

    func stage(_ finding: ExistingTagFinding) {
        guard !isStaged(tagID: finding.tag.id) else { return }
        basket.append(PendingTag(
            value: finding.tag.name, categoryID: finding.tag.tagCategoryID,
            existingTagID: finding.tag.id))
    }

    func unstage(_ id: PendingTag.ID) {
        basket.removeAll { $0.id == id }
    }

    func updateStaged(_ id: PendingTag.ID, value: String) {
        guard let at = basket.firstIndex(where: { $0.id == id }) else { return }
        basket[at].value = value
        // An edited value is no longer the existing tag it came from —
        // committing it must create/match by NAME, not silently apply a
        // tag whose name is now different from what the row shows.
        basket[at].existingTagID = nil
    }

    func discardBasket() {
        basket = []
    }

    /// Write the basket for the displayed video. Called by advance, by
    /// Save, and by the window closing — the three ends of "I am done
    /// with this one".
    func commitBasket() {
        guard let itemID = currentItemID, !basket.isEmpty else { return }
        do {
            tagsCommittedThisPass += try library.commitPendingTags(basket, to: itemID)
            basket = []
            reload()
        } catch {
            loadError = "\(error)"
        }
    }
}
