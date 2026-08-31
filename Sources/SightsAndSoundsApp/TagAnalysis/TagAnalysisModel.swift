import AVFoundation
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

    /// The rail preview's own player — the numpad transport works here
    /// exactly as in the player window, off the same key map and the
    /// same skip settings, because seek distances are muscle memory.
    /// Loads paused: this is a triage surface, and sound the operator
    /// did not ask for is noise.
    let previewPlayer = AVPlayer()
    private(set) var previewPlaying = false
    private(set) var previewSeconds: Double = 0
    private(set) var previewDuration: Double = 0
    /// Which video the preview currently holds — reload() runs after
    /// every commit and sweep, and replacing the item each time reset
    /// playback to a paused first frame ("it appears to be frame by
    /// frame"). The item is replaced only when the VIDEO changes.
    private var previewItemID: UUID?
    private var previewTimeObserver: Any?
    private var previewEndObserver: NSObjectProtocol?
    /// What the displayed video already wears — the baseline every
    /// decision is made against, so it sits in view instead of in memory.
    private(set) var appliedTags: [(category: TagCategory, tags: [Tag])] = []
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

    /// Left-rail filters — the comp's EVIDENCE SOURCES and STATUS blocks.
    var readerFilter: String?
    var statusFilter: StatusFilter = .undecided

    enum StatusFilter: String, CaseIterable {
        case undecided, inBasket, ignored, everything

        var label: String {
            switch self {
            case .undecided: "Undecided"
            case .inBasket: "In basket"
            case .ignored: "Ignored"
            case .everything: "Everything"
            }
        }
    }


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
        // Suggested first — the rows a click can finish are worth the
        // top of the table.
        return (analysis.suggested + analysis.unmapped).map {
            TableRow(candidate: $0, findings: findingsByText[$0.value] ?? [])
        }
    }

    var visibleRows: [TableRow] {
        allRows.filter { matches($0) }
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

    func status(of row: TableRow) -> StatusFilter {
        if row.candidate.suppressedByRule != nil { return .ignored }
        let mappedCategoryID = row.candidate.category.flatMap { self.category(named: $0)?.id }
        if isStaged(value: row.candidate.value, categoryID: mappedCategoryID)
            || row.findings.contains(where: { isStaged(tagID: $0.tag.id) })
        {
            return .inBasket
        }
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

    /// How many places in THIS video the string was found. Library-wide
    /// reach used to show here and was removed on review: "it should
    /// only have the information pulled from the single video."
    func occurrenceCount(for candidate: AnalysisCandidate) -> Int {
        candidate.origins.count
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
        jump(to: index + delta)
    }

    /// The queue strip's click, and what the arrows are made of — same
    /// commit-then-clear contract whichever way you arrive at a video.
    func jump(to next: Int) {
        guard queue.indices.contains(next), next != index else { return }
        commitBasket()
        index = next
        videosVisitedThisPass += 1
        selectedCandidateID = nil
        searchText = ""
        analysis = .empty
        reload()
    }

    // MARK: - The preview transport

    /// Point the preview at the current video — only when the video
    /// actually changed. A reload that changed tags or rules must not
    /// interrupt playback in flight.
    func reloadPreview() {
        guard currentItemID != previewItemID else { return }
        previewItemID = currentItemID
        previewPlayer.pause()
        previewPlaying = false
        previewSeconds = 0
        previewDuration = 0
        if let previewEndObserver {
            NotificationCenter.default.removeObserver(previewEndObserver)
            self.previewEndObserver = nil
        }
        guard let item = currentItem,
              let url = (try? library.resolvedFileURL(for: item)) ?? nil
        else {
            previewPlayer.replaceCurrentItem(with: nil)
            return
        }
        let playerItem = AVPlayerItem(url: url)
        previewPlayer.replaceCurrentItem(with: playerItem)
        previewDuration = item.durationSeconds ?? 0
        installPreviewObservers(for: playerItem)
    }

    private func installPreviewObservers(for playerItem: AVPlayerItem) {
        if previewTimeObserver == nil {
            // One periodic observer for the player's lifetime — it
            // follows item replacement on its own.
            previewTimeObserver = previewPlayer.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
            ) { [weak self] time in
                Task { @MainActor in self?.previewSeconds = time.seconds }
            }
        }
        previewEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: playerItem, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.previewPlaying = false }
        }
    }

    func previewTogglePlay() {
        previewPlaying ? previewPlayer.pause() : previewPlayer.play()
        previewPlaying.toggle()
    }

    /// The mini scrubber's click — a fraction of the duration.
    func previewSeek(toFraction fraction: Double) {
        guard previewDuration > 0 else { return }
        previewSeek(to: fraction.clamped01 * previewDuration)
    }

    /// The player window's digit table, verbatim — numpad seeks, 5
    /// pauses, 0 to the start, − to near the end. The triage flags in
    /// the map (favorite and friends) deliberately do NOT fire here:
    /// this window's decisions are tags, and a stray numpad press must
    /// not silently flag a video.
    func handlePreviewKey(character: Character, shift: Bool, numpad: Bool) -> Bool {
        guard let action = PlayerKeyMap.action(
            character: character, shift: shift, numpad: numpad,
            settings: AppSettingsStore.shared.current.skip)
        else { return false }
        switch action {
        case .seek(let seconds):
            previewSeek(by: seconds)
        case .playPause:
            previewTogglePlay()
        case .seekToStart:
            previewPlayer.seek(to: .zero)
        case .seekToNearEnd:
            let duration = previewPlayer.currentItem?.duration.seconds ?? 0
            if duration.isFinite, duration > 5 {
                previewSeek(to: duration - 5)
            }
        case .toggleFavorite, .toggleNeedsReview, .toggleMarkedForDeletion,
             .togglePlaybackIssue:
            return false
        }
        return true
    }

    func previewSeek(by seconds: Double) {
        previewSeek(to: previewPlayer.currentTime().seconds + seconds)
    }

    private func previewSeek(to seconds: Double) {
        previewPlayer.seek(
            to: CMTime(seconds: max(0, seconds), preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero)
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
                self.appliedTags = (try? library.tags(of: itemID)) ?? []
                self.reloadPreview()
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

    func select(_ id: AnalysisCandidate.ID?) {
        selectedCandidateID = id
    }

    // MARK: - Decide actions beyond the basket

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
    /// rule, so the never-useful leading token stops appearing — an
    /// ordinary rule row, one editor, one storage, one backup path.
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
    /// tag. Vocabulary, not tagging — it writes immediately rather than
    /// through the basket, because an alias belongs to the library, not
    /// to this video.
    func addAlias(_ value: String, toTag tagID: UUID) {
        do {
            try library.addAlias(value.trimmingCharacters(in: .whitespacesAndNewlines), toTag: tagID)
            reload()
        } catch {
            loadError = "\(error)"
        }
    }

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
