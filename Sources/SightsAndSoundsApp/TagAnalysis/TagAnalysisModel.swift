import Foundation
import GRDB
import Observation
import SightsAndSoundsKit

/// The companion window's state: the analysis of whatever the followed
/// player is showing, and the filters over it. It does not own a video
/// or a queue — the session says which item, and the player owns the
/// walk. Accepting applies at once through the session's hook, so the
/// player's panel refreshes on the same call.
@Observable
@MainActor
final class TagAnalysisModel {

    let session: TagAnalysisSession
    var library: LibraryDatabase { session.library }
    var libraryID: UUID { session.libraryID }

    private(set) var analysis: ItemAnalysis = .empty
    /// The shown item's row — its name for the panes, its file for the
    /// evidence stills. Fetched with each reload; nil between items.
    private(set) var currentItem: MediaItem?
    private(set) var rules: [RuleEngine.Rule] = []
    private(set) var categories: [TagCategory] = []
    private(set) var isLoading = false
    private(set) var loadError: String?

    /// What this pass has done so far — a pass being the life of this
    /// window over whatever the player walked through.
    private(set) var tagsAppliedThisPass = 0
    private(set) var videosVisitedThisPass = 1

    var searchText = ""
    var selectedCandidateID: AnalysisCandidate.ID?

    /// The rail's Reader I/O page replaces the candidate table while on
    /// — a sibling view of the same video.
    var showingReaderIO = false

    /// Left-rail filters — the comp's EVIDENCE SOURCES and STATUS blocks.
    var readerFilter: String?
    var statusFilter: StatusFilter = .undecided

    enum StatusFilter: String, CaseIterable {
        case undecided, applied, ignored, everything

        var label: String {
            switch self {
            case .undecided: "Undecided"
            case .applied: "Applied"
            case .ignored: "Ignored"
            case .everything: "Everything"
            }
        }
    }

    /// The item the reload in flight (or the last one) was for — the
    /// guard that drops results for an item the player has left.
    private var loadedItemID: UUID?

    init(session: TagAnalysisSession) {
        self.session = session
        session.companionDidOpen()
        observeSession()
        if session.itemID != nil { reload() }
    }

    // MARK: - Following the player

    var currentItemID: UUID? { session.itemID }
    var playerIsOpen: Bool { session.playerIsOpen }

    /// "3 of 41", or nil for a single item.
    var positionText: String? {
        guard let position = session.position else { return nil }
        return "\(position.index + 1) of \(position.count)"
    }

    /// One observation at a time, re-armed after each change lands.
    /// `onChange` fires before the new value is visible, so the work is
    /// hopped to the next main-actor turn.
    private func observeSession() {
        withObservationTracking {
            _ = session.itemID
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.itemChanged()
                self.observeSession()
            }
        }
    }

    /// The player moved on: stamp the departed video, count the visit,
    /// drop everything that pointed at its strings, and reload.
    private func itemChanged() {
        guard session.itemID != loadedItemID else { return }
        if loadedItemID != nil {
            markAnalyzed(loadedItemID)
            videosVisitedThisPass += 1
        }
        selectedCandidateID = nil
        searchText = ""
        analysis = .empty
        currentItem = nil
        reload()
    }

    /// Stamp a video as analyzed, at the current analyzer version.
    /// Moving past without applying anything still counts — seeing the
    /// evidence and judging nothing tag-worthy IS an analysis.
    private func markAnalyzed(_ id: UUID?) {
        guard let id else { return }
        try? library.markAnalyzed(id)
    }

    /// The window is going away: the companion's half of the session
    /// clears and the shown video is stamped.
    func close() {
        markAnalyzed(loadedItemID)
        session.companionDidClose()
    }

    // MARK: - Derived

    var selectedCandidate: AnalysisCandidate? {
        (analysis.suggested + analysis.unmapped).first { $0.id == selectedCandidateID }
    }

    /// One row per string — the comp's single table. The suggestion
    /// column carries the classification instead of three separate
    /// sections: a rule mapping, an existing-tag hit, or nothing.
    struct TableRow: Identifiable {
        let candidate: AnalysisCandidate
        let findings: [ExistingTagFinding]
        var id: AnalysisCandidate.ID { candidate.id }
    }

    var allRows: [TableRow] {
        let findingsByText = Dictionary(grouping: analysis.existing, by: \.foundIn)
        return (analysis.suggested + analysis.unmapped).map {
            TableRow(candidate: $0, findings: findingsByText[$0.value] ?? [])
        }
    }

    var visibleRows: [TableRow] {
        allRows.filter { matches($0) }
    }

    /// The inspector's right column: everything this reader's strings
    /// became, whichever bucket they landed in.
    func candidates(fromReader readerID: String) -> [TableRow] {
        allRows.filter { row in
            row.candidate.origins.contains { $0.readerID == readerID }
        }
    }

    func count(reader: String?) -> Int {
        allRows.count { row in
            (reader == nil || row.candidate.origins.contains { $0.readerID == reader })
                && status(of: row) == .undecided
        }
    }

    func count(status: StatusFilter) -> Int {
        if status == .everything { return allRows.count }
        return allRows.count(where: { self.status(of: $0) == status })
    }

    /// Applied means a found tag is already on the video — the reload
    /// after an apply is what moves a row here.
    func status(of row: TableRow) -> StatusFilter {
        if row.candidate.suppressedByRule != nil { return .ignored }
        if !row.findings.isEmpty, row.findings.allSatisfy(\.alreadyApplied) { return .applied }
        return .undecided
    }

    private func matches(_ row: TableRow) -> Bool {
        if let readerFilter,
           !row.candidate.origins.contains(where: { $0.readerID == readerFilter })
        {
            return false
        }
        if statusFilter != .everything, status(of: row) != statusFilter { return false }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return row.candidate.value.localizedCaseInsensitiveContains(query)
            || (row.candidate.key?.localizedCaseInsensitiveContains(query) ?? false)
    }

    /// How many places in THIS video the string was found.
    func occurrenceCount(for candidate: AnalysisCandidate) -> Int {
        candidate.origins.count
    }

    func category(named name: String) -> TagCategory? {
        categories.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    // MARK: - Loading

    /// Everything the analysis needs, then the analysis itself off the
    /// main actor. Results for an item the player has since left are
    /// dropped, not shown.
    func reload() {
        guard let itemID = currentItemID else {
            analysis = .empty
            session.companionDidReload(.empty)
            return
        }
        loadedItemID = itemID
        isLoading = true
        session.companionWillReload()
        let library = library
        Task {
            do {
                let rules = try library.analysisRules()
                let categories = try library.vocabulary().map(\.category)
                let analysis = try await Task.detached(priority: .userInitiated) {
                    try library.analyzeItem(itemID, rules: rules)
                }.value
                guard itemID == self.currentItemID else { return }
                self.currentItem = try await library.writer.read {
                    try MediaItem.fetchOne($0, key: itemID)
                }
                self.rules = rules
                self.categories = categories
                self.analysis = analysis
                self.session.companionDidReload(analysis)
                self.loadError = nil
            } catch {
                self.loadError = "\(error)"
                self.session.companionDidReload(.empty)
            }
            self.isLoading = false
        }
    }

    /// The sweep runs on the job runner; the model only tracks that one
    /// is in flight.
    func beginSweep() { isLoading = true }
    func finishSweep() { reload() }

    func select(_ id: AnalysisCandidate.ID?) {
        selectedCandidateID = id
    }

    // MARK: - Applying

    /// Apply an existing tag to the shown video, now, through the
    /// player's hook so its panel refreshes on the same call. The reload
    /// that follows moves the row to Applied.
    func applyNow(_ tag: Tag) {
        session.apply(tag)
        tagsAppliedThisPass += 1
        reload()
    }

    /// Create (or find by name) then apply — the decide pane's Assign.
    func applyNew(value: String, categoryID: UUID) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let tag = try library.ensureTag(named: trimmed, inCategory: categoryID)
            applyNow(tag)
        } catch {
            loadError = "\(error)"
        }
    }

    // MARK: - Decide actions that write rules or vocabulary

    /// The comp's "Ignore this key": never offer it again, reversible.
    /// Implemented as an authored ignore RULE — candidates become rules —
    /// so reversing it is deleting the rule, and the Ignored status
    /// filter is the list the comp promises.
    func ignoreRule(for candidate: AnalysisCandidate) {
        let matcher: RuleMatcher = candidate.key.flatMap { key in
            key.isEmpty ? nil : .keyEquals(key: key)
        } ?? .valueStartsWith(prefix: candidate.value)
        do {
            try library.saveAnalysisRule(
                RuleEngine.Rule(id: UUID(), matcher: matcher, actions: [.ignore]))
            reload()
        } catch {
            loadError = "\(error)"
        }
    }

    /// The comp's "Hide the prefix": a pathRootStartsWith + hidePrefix
    /// rule, so the never-useful leading token stops appearing.
    func hidePrefixRule(root: String) {
        let trimmed = root.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        do {
            try library.saveAnalysisRule(
                RuleEngine.Rule(
                    id: UUID(), matcher: .pathRootStartsWith(root: trimmed),
                    actions: [.hidePrefix]))
            reload()
        } catch {
            loadError = "\(error)"
        }
    }

    /// The comp's "Add as an alias": folds this spelling into an existing
    /// tag. Vocabulary, not tagging — it writes immediately, because an
    /// alias belongs to the library, not to this video.
    func addAlias(_ value: String, toTag tagID: UUID) {
        do {
            try library.addAlias(value.trimmingCharacters(in: .whitespacesAndNewlines), toTag: tagID)
            reload()
        } catch {
            loadError = "\(error)"
        }
    }
}
