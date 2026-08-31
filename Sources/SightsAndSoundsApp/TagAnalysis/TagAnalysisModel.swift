import Foundation
import GRDB
import Observation
import SightsAndSoundsKit

/// The Candidates tab's state: the queue, what is filtered, what is
/// picked, and what the last decision was so it can be taken back.
///
/// The queue is **derived** in the Kit — recomputed from the underlying
/// data on every load rather than maintained — so this model reloads
/// after every decision instead of mutating rows in place. That is what
/// keeps the screen honest when one decision changes another candidate's
/// count.
@Observable
@MainActor
final class TagAnalysisModel {

    /// The status filter's options. `all` is not a source: it is the
    /// absence of one, which is why it is not a `TagCandidateSource` case.
    enum SourceFilter: Hashable {
        case all
        case source(TagCandidateSource)

        var label: String {
            switch self {
            case .all: "All sources"
            case .source(let source): source.displayName
            }
        }
    }

    enum StatusFilter: String, CaseIterable, Hashable {
        case undecided, suggested, covered

        var label: String {
            switch self {
            case .undecided: "Needs a decision"
            case .suggested: "Has a suggestion"
            case .covered: "Covered by a rule"
            }
        }
    }

    let library: LibraryDatabase
    let libraryID: UUID

    /// The queue this window walks — the same listing the player takes.
    /// Analysis always looks at ONE video, `queue[index]`: metadata from
    /// one video is not evidence about another, so there is no
    /// whole-library mode and no multi-item mode. The queue exists to be
    /// walked, exactly as the player walks it.
    private(set) var queue: [UUID]
    private(set) var index: Int
    /// The video on display, loaded for the header.
    private(set) var currentItem: MediaItem?

    private(set) var candidates: [TagCandidate] = []
    private(set) var categories: [TagCategory] = []
    private(set) var tagsByCategory: [UUID: [Tag]] = [:]

    /// Every tag, for the alias picker — the string is another name for
    /// one of these.
    var allTags: [Tag] { categories.flatMap { tagsByCategory[$0.id] ?? [] } }
    private(set) var rules: [RuleEngine.Rule] = []
    private(set) var isLoading = false
    private(set) var loadError: String?

    var sourceFilter: SourceFilter = .all
    var statusFilter: StatusFilter?
    var searchText = ""

    /// The row shown in the detail pane. Separate from `picked`: looking
    /// at a candidate is not the same as choosing it for a bulk action,
    /// and conflating them makes the bulk bar appear on a mere click.
    var selectedID: TagCandidate.ID?
    var picked: Set<TagCandidate.ID> = []

    private(set) var evidence: [CandidateEvidence] = []
    private(set) var itemsAffected = 0

    /// This pass's tally, and the one decision that can be taken back.
    /// One deep, deliberately: an undo stack over a derived queue would
    /// promise more than it can keep once a later decision has changed
    /// what the earlier one applied to.
    private(set) var acceptedThisPass = 0
    private(set) var ignoredThisPass = 0
    private(set) var lastDecision: (candidate: TagCandidate, wasAccepted: Bool)?

    init(library: LibraryDatabase, libraryID: UUID, queue: [UUID], startAt: Int = 0) {
        self.library = library
        self.libraryID = libraryID
        self.queue = queue
        self.index = queue.indices.contains(startAt) ? startAt : 0
    }

    var currentItemID: UUID? {
        queue.indices.contains(index) ? queue[index] : nil
    }

    /// What every Kit call is scoped to: the displayed video, alone.
    private var scope: Set<UUID>? {
        currentItemID.map { [$0] }
    }

    // MARK: - Walking the queue

    var canGoPrevious: Bool { index > 0 }
    var canGoNext: Bool { index + 1 < queue.count }

    func goNext() { step(1) }
    func goPrevious() { step(-1) }

    /// Clamped at the ends, like the player — SHIFT+arrows walk the same
    /// queue in both windows and must not disagree about what the last
    /// item does.
    private func step(_ delta: Int) {
        let next = index + delta
        guard queue.indices.contains(next) else { return }
        index = next
        // The analysis is per video, so the working state goes with the
        // video: a selection, a set of picks, or an undoable decision
        // from the previous one would silently point at strings the new
        // video may not even contain. The pass tally stays — it counts
        // the pass over the queue, not one video.
        selectedID = nil
        picked = []
        evidence = []
        itemsAffected = 0
        lastDecision = nil
        reload()
    }

    // MARK: - Derived

    var selected: TagCandidate? {
        candidates.first { $0.id == selectedID }
    }

    var pickedCandidates: [TagCandidate] {
        candidates.filter { picked.contains($0.id) }
    }

    /// The rows the table draws. Filtering happens here rather than in SQL
    /// because the queue is already in memory and bounded, and because
    /// the counts beside each filter have to be computed off the same
    /// list they filter — two sources of truth is how a facet count
    /// stops matching its own list.
    var visible: [TagCandidate] {
        candidates.filter { matches($0) }
    }

    func count(for filter: SourceFilter) -> Int {
        candidates.count { candidate in
            guard case .source(let source) = filter else { return true }
            return candidate.source == source
        }
    }

    func count(for filter: StatusFilter) -> Int {
        candidates.count { matches(status: filter, $0) }
    }

    private func matches(_ candidate: TagCandidate) -> Bool {
        if case .source(let source) = sourceFilter, candidate.source != source { return false }
        if let statusFilter, !matches(status: statusFilter, candidate) { return false }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return candidate.value.localizedCaseInsensitiveContains(query)
            || (candidate.key?.localizedCaseInsensitiveContains(query) ?? false)
    }

    private func matches(status: StatusFilter, _ candidate: TagCandidate) -> Bool {
        switch status {
        case .undecided: candidate.suggestedCategory == nil && candidate.coveredByRuleID == nil
        case .suggested: candidate.suggestedCategory != nil
        case .covered: candidate.coveredByRuleID != nil
        }
    }

    /// The category a decision would default to — the rule's suggestion
    /// when there is one, so accepting is one click and redirecting is a
    /// deliberate act.
    func suggestedCategory(for candidate: TagCandidate) -> TagCategory? {
        guard let name = candidate.suggestedCategory else { return nil }
        return categories.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    // MARK: - Loading

    /// The sweep runs on the job runner, so the model only tracks that
    /// one is in flight — progress belongs to the Background Tasks
    /// window, which already shows every job the same way.
    func beginSweep() { isLoading = true }

    func finishSweep() { reload() }

    func reload() {
        isLoading = true
        let library = library
        Task {
            do {
                let rules = try library.analysisRules()
                let vocabulary = try library.vocabulary()
                let candidates = try library.tagCandidates(rules: rules, within: scope)
                self.currentItem = try self.currentItemID.flatMap { id in
                    try library.writer.read { try MediaItem.fetchOne($0, key: id) }
                }
                self.rules = rules
                self.categories = vocabulary.map(\.category)
                self.tagsByCategory = Dictionary(
                    uniqueKeysWithValues: vocabulary.map { ($0.category.id, $0.tags) })
                self.candidates = candidates
                self.loadError = nil
                // A selection that no longer exists is dropped rather than
                // left pointing at nothing — the detail pane reads off it.
                if let selectedID, !candidates.contains(where: { $0.id == selectedID }) {
                    self.selectedID = nil
                }
                self.picked = self.picked.intersection(Set(candidates.map(\.id)))
                self.refreshEvidence()
                self.refreshAffected()
            } catch {
                self.loadError = "\(error)"
            }
            self.isLoading = false
        }
    }

    func refreshEvidence() {
        guard let selected else {
            evidence = []
            return
        }
        let library = library
        Task {
            evidence = (try? library.candidateEvidence(for: selected, within: scope)) ?? []
        }
    }

    private func refreshAffected() {
        let library = library, picked = pickedCandidates
        guard !picked.isEmpty else {
            itemsAffected = 0
            return
        }
        Task {
            itemsAffected = (try? library.itemsAffected(by: picked, within: scope)) ?? 0
        }
    }

    func select(_ candidate: TagCandidate) {
        selectedID = candidate.id
        refreshEvidence()
    }

    func togglePicked(_ candidate: TagCandidate) {
        if picked.contains(candidate.id) {
            picked.remove(candidate.id)
        } else {
            picked.insert(candidate.id)
        }
        refreshAffected()
    }

    func clearPicks() {
        picked.removeAll()
        itemsAffected = 0
    }

    // MARK: - Deciding

    func apply(_ candidate: TagCandidate, _ application: CandidateApplication) {
        do {
            _ = try library.apply(candidate, application, within: scope)
            lastDecision = (candidate, application != .ignore)
            if application == .ignore { ignoredThisPass += 1 } else { acceptedThisPass += 1 }
            reload()
        } catch {
            loadError = "\(error)"
        }
    }

    /// Apply each picked candidate's own suggestion. A candidate without
    /// one is **skipped, not guessed** — spec 14 §3 leaves the ambiguous
    /// ones for a human, and inventing a category here would be exactly
    /// the guess the suggestion column exists to avoid.
    func applyPickedSuggestions() {
        var applied = 0
        for candidate in pickedCandidates {
            guard let category = suggestedCategory(for: candidate) else { continue }
            do {
                _ = try library.apply(
                    candidate, .assignCategory(categoryID: category.id), within: scope)
                applied += 1
            } catch {
                loadError = "\(error)"
            }
        }
        acceptedThisPass += applied
        lastDecision = nil  // a bulk run is not one decision to take back
        clearPicks()
        reload()
    }

    func ignorePicked() {
        let picked = pickedCandidates
        for candidate in picked {
            try? library.decide(candidate, as: .ignored)
        }
        ignoredThisPass += picked.count
        lastDecision = nil
        clearPicks()
        reload()
    }

    /// Take back the last single decision. Only the decision row is
    /// undone; a category assignment that reached items is reverted
    /// through the ordinary tag history, not from here — spec 14 §9 is
    /// explicit that there is no third audit trail.
    func undoLastDecision() {
        guard let last = lastDecision else { return }
        try? library.clearDecision(for: last.candidate)
        if last.wasAccepted { acceptedThisPass -= 1 } else { ignoredThisPass -= 1 }
        lastDecision = nil
        reload()
    }
}
