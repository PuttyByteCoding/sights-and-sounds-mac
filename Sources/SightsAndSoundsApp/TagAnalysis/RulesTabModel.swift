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

    let library: LibraryDatabase

    private(set) var rules: [RuleEngine.Rule] = []
    private(set) var dryRun: RuleDryRun?
    /// Per-card dry runs — the comp's "412 pairs · 380 items" lines.
    private(set) var cardDryRuns: [UUID: RuleDryRun] = [:]
    private(set) var lastApplied: RuleApplication?
    private(set) var loadError: String?

    var selectedID: UUID?

    /// The edit in progress. Held apart from `rules` so an argument
    /// half-typed into the matcher field is not saved on every keystroke
    /// — and so Revert has something to go back to.
    var draft: RuleEngine.Rule?

    init(library: LibraryDatabase) {
        self.library = library
    }

    var selected: RuleEngine.Rule? {
        rules.first { $0.id == selectedID }
    }

    var isDirty: Bool {
        guard let draft, let selected else { return draft != nil }
        return draft != selected
    }

    // MARK: - Loading

    func reload() {
        do {
            rules = try library.analysisRules()
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

    /// One queue computation for all cards — off the main actor, since
    /// it walks every stored pair.
    private func refreshCardDryRuns() {
        let library = library, rules = rules
        Task {
            let runs = try? await Task.detached(priority: .utility) {
                try library.dryRuns(for: rules)
            }.value
            if let runs { self.cardDryRuns = runs }
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
    func refreshDryRun() {
        guard let subject = draft ?? selected else {
            dryRun = nil
            return
        }
        let library = library
        Task {
            dryRun = try? library.dryRun(subject)
        }
    }

    // MARK: - Editing

    func addRule() {
        // A new rule starts inert: an empty keyEquals matches nothing, so
        // it cannot do anything until it has been given a key AND an
        // action. Better than defaulting to something that fires.
        let made = RuleEngine.Rule(id: UUID(), matcher: .keyEquals(key: ""), actions: [])
        do {
            try library.saveAnalysisRule(made)
            reload()
            select(made)
        } catch {
            loadError = "\(error)"
        }
    }

    /// Start a rule from a candidate. If a rule already covers the string
    /// this **opens that rule** rather than adding a rival — spec 14 §4,
    /// and the entire path from one-off triage to automation.
    @discardableResult
    func makeRule(from candidate: TagCandidate) -> Bool {
        makeRule(key: candidate.key, value: candidate.value)
    }

    @discardableResult
    func makeRule(key: String?, value: String) -> Bool {
        do {
            if let covering = try library.ruleCovering(key: key, value: value) {
                reload()
                select(covering)
                return false
            }
            let made = RuleEngine.Rule(
                id: UUID(),
                matcher: LibraryDatabase.matcher(forKey: key, value: value),
                actions: [])
            try library.saveAnalysisRule(made)
            reload()
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
        refreshDryRun()
    }

    func saveDraft() {
        guard let draft else { return }
        do {
            try library.saveAnalysisRule(draft)
            reload()
        } catch {
            loadError = "\(error)"
        }
    }

    func revertDraft() {
        draft = selected
        refreshDryRun()
    }

    func delete(_ rule: RuleEngine.Rule) {
        do {
            try library.deleteAnalysisRule(rule.id)
            if selectedID == rule.id {
                selectedID = nil
                draft = nil
            }
            reload()
        } catch {
            loadError = "\(error)"
        }
    }

    func move(_ rule: RuleEngine.Rule, up: Bool) {
        do {
            try library.moveAnalysisRule(rule.id, up: up)
            reload()
        } catch {
            loadError = "\(error)"
        }
    }

    // MARK: - Applying

    /// Apply the SAVED rule, never the draft: §6's promise is that
    /// nothing is written until Apply, and applying an unsaved edit would
    /// write something the rule list does not show.
    func applySelected() {
        guard let selected else { return }
        do {
            lastApplied = try library.applyAnalysisRule(selected)
            reload()
        } catch {
            loadError = "\(error)"
        }
    }
}
