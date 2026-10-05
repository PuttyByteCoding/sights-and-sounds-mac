import Foundation
import Observation
import SightsAndSoundsKit

/// The Rules tab's state: the ordered rules, the one being edited, and
/// its dry run.
///
/// **Order is the engine** (spec 14 §5) — rules fold top to bottom and
/// actions fold in list order — so both orders are editable here and both
/// are persisted immediately. Nothing is staged: a reorder IS the change.
@Observable
@MainActor
final class RulesTabModel {

    let service: any LibraryService

    private(set) var rules: [RuleEngine.Rule] = []
    private(set) var dryRun: RuleDryRun?
    /// Per-card dry runs — the comp's "412 pairs · 380 items" lines.
    private(set) var cardDryRuns: [UUID: RuleDryRun] = [:]
    private(set) var lastApplied: RuleApplication?
    private(set) var loadError: String?
    /// An Apply in flight: a rule's writes walk the library, so they run
    /// off the main actor and the button waits for them.
    private(set) var isApplying = false

    private var dryRunTask: Task<Void, Never>?
    /// The draft's walk; tests slow it down to overlap edits with it.
    var walkDryRun: @Sendable (any LibraryService, RuleEngine.Rule) async throws -> RuleDryRun = {
        try await $0.dryRun(of: $1)
    }
    private var cardDryRunGeneration = 0
    /// Only the newest reading of the rules lands.
    private var reloadGeneration = 0

    var selectedID: UUID?

    /// The edit in progress. Held apart from `rules` so an argument
    /// half-typed into the matcher field is not saved on every keystroke
    /// — and so Revert has something to go back to.
    var draft: RuleEngine.Rule?

    /// This tab's writes, one at a time in the order they were asked
    /// for: two moves pressed quickly must not land the other way round.
    private let writes = WriteQueue()

    init(service: any LibraryService) {
        self.service = service
    }

    private func write(_ body: @escaping @Sendable (any LibraryService) async throws -> Void) async throws {
        let service = service
        try await writes.run { try await body(service) }.get()
    }

    var selected: RuleEngine.Rule? {
        rules.first { $0.id == selectedID }
    }

    var isDirty: Bool {
        guard let draft, let selected else { return draft != nil }
        return draft != selected
    }

    // MARK: - Loading

    func reload() async {
        reloadGeneration += 1
        let generation = reloadGeneration
        do {
            let fetched = try await service.analysisRules()
            guard generation == reloadGeneration else { return }
            rules = fetched
            loadError = nil
            refreshCardDryRuns()
            if let selectedID, !rules.contains(where: { $0.id == selectedID }) {
                self.selectedID = nil
                draft = nil
            }
            refreshDryRun()
        } catch {
            loadError = "\(error)"
        }
    }

    /// One queue computation for all cards — the service's, off the main
    /// actor, since it walks every stored pair.
    private func refreshCardDryRuns() {
        let service = service, rules = rules
        cardDryRunGeneration += 1
        let generation = cardDryRunGeneration
        Task {
            let runs = try? await service.dryRuns(of: rules)
            // An older walk that finishes last must not win.
            if let runs, generation == cardDryRunGeneration { self.cardDryRuns = runs }
        }
    }

    func select(_ rule: RuleEngine.Rule) {
        selectedID = rule.id
        draft = rule
        lastApplied = nil
        refreshDryRun()
    }

    /// The dry run follows the DRAFT, not the stored rule: §6 says a rule
    /// reports before it writes, and a report of what is already saved
    /// would answer the wrong question while someone is editing.
    ///
    /// The run walks the whole candidate queue, so it runs off the main
    /// actor — it used to run on it, once per keystroke in the matcher
    /// field. Typing waits for a pause (`settle`), a pause that ends
    /// during a walk waits for that walk (`startDryRunWalk`), and only an
    /// answer for the draft still on screen lands.
    func refreshDryRun(settle: Duration = .zero) {
        dryRunTask?.cancel()
        guard draft ?? selected != nil else {
            dryRun = nil
            return
        }
        dryRunTask = Task {
            if settle > .zero { try? await Task.sleep(for: settle) }
            // Also for an immediate request: one replaced in the same turn
            // must not walk, or the one replacing it finds a walk running
            // and queues a second for the same draft.
            guard !Task.isCancelled else { return }
            startDryRunWalk()
        }
    }

    /// A walk is running, and an edit arrived during it.
    private var walking = false
    private var walkIsStale = false

    /// One walk at a time. The walk is a synchronous pass over the whole
    /// candidate queue and cannot be stopped part-way, so cancelling the
    /// task that awaited it left it running: slow typing piled up
    /// concurrent walks whose answers were then thrown away. Now an edit
    /// during a walk only marks it stale, and when it finishes one more
    /// walk runs for the newest draft. A finished walk whose rule is no
    /// longer the one on screen is dropped.
    private func startDryRunWalk() {
        guard !walking else {
            walkIsStale = true
            return
        }
        guard let subject = draft ?? selected else {
            dryRun = nil
            return
        }
        walking = true
        walkIsStale = false
        let service = service, walk = walkDryRun
        Task {
            let run = try? await walk(service, subject)
            walking = false
            if walkIsStale {
                startDryRunWalk()
            } else if subject == draft ?? selected {
                dryRun = run
            }
            // Otherwise the subject changed without marking this walk
            // stale — cleared, or an edit still settling — and whatever
            // changed it has already asked for its own answer.
        }
    }

    // MARK: - Editing

    func addRule() async {
        // A new rule starts inert: an empty keyEquals matches nothing, so
        // it cannot do anything until it has been given a key AND an
        // action. Better than defaulting to something that fires.
        let made = RuleEngine.Rule(id: UUID(), matcher: .keyEquals(key: ""), actions: [])
        do {
            try await write { try await $0.saveAnalysisRule(made) }
            await reload()
            select(made)
        } catch {
            loadError = "\(error)"
        }
    }

    /// Start a rule from a candidate. If a rule already covers the string
    /// this **opens that rule** rather than adding a rival — spec 14 §4,
    /// and the entire path from one-off triage to automation.
    @discardableResult
    func makeRule(from candidate: TagCandidate) async -> Bool {
        await makeRule(key: candidate.key, value: candidate.value)
    }

    @discardableResult
    func makeRule(key: String?, value: String) async -> Bool {
        do {
            if let covering = try await service.ruleCovering(key: key, value: value) {
                await reload()
                select(covering)
                return false
            }
            let made = RuleEngine.Rule(
                id: UUID(),
                matcher: LibraryDatabase.matcher(forKey: key, value: value),
                actions: [])
            try await write { try await $0.saveAnalysisRule(made) }
            await reload()
            select(made)
            return true
        } catch {
            loadError = "\(error)"
            return false
        }
    }

    func updateDraft(_ transform: (inout RuleEngine.Rule) -> Void) {
        guard var draft else { return }
        transform(&draft)
        self.draft = draft
        refreshDryRun(settle: .milliseconds(150))
    }

    func saveDraft() async {
        guard let draft else { return }
        do {
            try await write { try await $0.saveAnalysisRule(draft) }
            await reload()
        } catch {
            loadError = "\(error)"
        }
    }

    func revertDraft() {
        draft = selected
        refreshDryRun()
    }

    func delete(_ rule: RuleEngine.Rule) async {
        do {
            try await write { try await $0.deleteAnalysisRule(id: rule.id) }
            if selectedID == rule.id {
                selectedID = nil
                draft = nil
            }
            await reload()
        } catch {
            loadError = "\(error)"
        }
    }

    func move(_ rule: RuleEngine.Rule, up: Bool) async {
        do {
            try await write { try await $0.moveAnalysisRule(id: rule.id, up: up) }
            await reload()
        } catch {
            loadError = "\(error)"
        }
    }

    // MARK: - Applying

    /// Apply the SAVED rule, never the draft: §6's promise is that
    /// nothing is written until Apply, and applying an unsaved edit would
    /// write something the rule list does not show.
    func applySelected() {
        guard let selected, !isApplying else { return }
        isApplying = true
        let service = service
        Task {
            let outcome = await writes.run { try await service.applyAnalysisRule(selected) }
            isApplying = false
            switch outcome {
            case .success(let applied):
                // Only on the pane of the rule that was applied: choosing
                // another meanwhile cleared the result, and this used to
                // write it back under the other rule.
                if selectedID == selected.id { lastApplied = applied }
                await reload()
            case .failure(let error):
                loadError = "\(error)"
            }
        }
    }
}
