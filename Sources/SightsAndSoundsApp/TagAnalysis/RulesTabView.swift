import SwiftUI
import SightsAndSoundsKit

/// Tag analysis — the Rules tab.
///
/// **Order is the engine** (spec 14 §5): rules run top to bottom and
/// actions fold in list order, both documented as significant in
/// `AnalysisRule`'s header. So both are reorderable and **numbered on
/// screen** — an unordered list would misrepresent what the engine does.
struct RulesTabView: View {
    let model: RulesTabModel

    var body: some View {
        HSplitView {
            list.frame(minWidth: 380, idealWidth: 460)
            editor.frame(minWidth: 340, idealWidth: 400, maxWidth: 560)
        }
        .task { model.reload() }
    }

    // MARK: - The ordered list

    private var list: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Rules run top to bottom, and actions fold in list order — both orders are significant.")
                    .font(Theme.ui(Theme.TypeScale.secondary))
                    .foregroundStyle(Theme.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("+ Rule") { model.addRule() }
                    .buttonStyle(SecondaryButtonStyle(compact: true))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.Border.standard).frame(height: 1)
            }

            if let error = model.loadError {
                ContentUnavailableView(
                    "Could Not Read the Rules",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error))
            } else if model.rules.isEmpty {
                VStack(spacing: 6) {
                    Text("No rules yet")
                        .font(Theme.ui(Theme.TypeScale.dialogTitle, .semibold))
                        .foregroundStyle(Theme.Text.secondary)
                    Text("Decide a candidate twice and it is a rule waiting to be written.")
                        .font(Theme.ui(Theme.TypeScale.body))
                        .foregroundStyle(Theme.Text.quaternary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(Array(model.rules.enumerated()), id: \.element.id) { index, rule in
                            RuleCard(
                                rule: rule, order: index + 1,
                                isSelected: rule.id == model.selectedID,
                                isFirst: index == 0,
                                isLast: index == model.rules.count - 1,
                                onSelect: { model.select(rule) },
                                onMoveUp: { model.move(rule, up: true) },
                                onMoveDown: { model.move(rule, up: false) },
                                onRemove: { model.delete(rule) })
                        }
                    }
                    .padding(14)
                }
            }
        }
        .background(Theme.Surface.content)
    }

    // MARK: - The editor

    @ViewBuilder
    private var editor: some View {
        ScrollView {
            if let draft = model.draft {
                VStack(alignment: .leading, spacing: 16) {
                    matcherSection(draft)
                    actionsSection(draft)
                    dryRunSection
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Select a rule to edit its matcher and actions.")
                    .font(Theme.ui(Theme.TypeScale.body))
                    .foregroundStyle(Theme.Text.quaternary)
                    .multilineTextAlignment(.center)
                    .padding(28)
            }
        }
        .background(Theme.Surface.sidebar)
    }

    private func matcherSection(_ draft: RuleEngine.Rule) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Match").modifier(Theme.sectionLabel())

            ForEach(MatcherKind.allCases, id: \.self) { kind in
                Button {
                    model.updateDraft { $0 = RuleEngine.Rule(
                        id: $0.id, matcher: kind.matcher(argument: draft.matcher.argument),
                        actions: $0.actions) }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(kind == MatcherKind(draft.matcher) ? "◉" : "○")
                            .font(Theme.ui(11))
                            .foregroundStyle(
                                kind == MatcherKind(draft.matcher)
                                    ? Theme.Accent.amber : Theme.Text.quaternary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(kind.rawValue)
                                .font(Theme.mono(11.5))
                                .foregroundStyle(Theme.Text.primary)
                            Text(kind.explanation)
                                .font(Theme.ui(Theme.TypeScale.secondary))
                                .foregroundStyle(Theme.Text.quaternary)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            TextField(
                MatcherKind(draft.matcher)?.placeholder ?? "",
                text: Binding(
                    get: { draft.matcher.argument },
                    set: { text in
                        model.updateDraft { rule in
                            guard let kind = MatcherKind(rule.matcher) else { return }
                            rule = RuleEngine.Rule(
                                id: rule.id, matcher: kind.matcher(argument: text),
                                actions: rule.actions)
                        }
                    }))
                .textFieldStyle(.plain)
                .font(Theme.mono(12))
                .foregroundStyle(Theme.Text.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.control)
                        .fill(Theme.Surface.well)
                        .stroke(Theme.Border.standard, lineWidth: 1))

            if case .unknown(let type) = draft.matcher {
                // Degrade, never throw: a rule authored against a newer
                // build is shown as-is and left alone rather than being
                // destroyed by being opened.
                Text("This rule uses “\(type)”, which this build does not recognise. It never matches, and editing it here would overwrite it.")
                    .font(Theme.ui(Theme.TypeScale.secondary))
                    .foregroundStyle(Theme.Status.warnText)
            }
        }
    }

    private func actionsSection(_ draft: RuleEngine.Rule) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Actions, in order").modifier(Theme.sectionLabel())
                Spacer()
                Text("folds top to bottom")
                    .font(Theme.ui(Theme.TypeScale.secondary))
                    .foregroundStyle(Theme.Text.quaternary)
            }

            if draft.actions.isEmpty {
                Text("no actions yet")
                    .font(Theme.ui(Theme.TypeScale.body))
                    .foregroundStyle(Theme.Status.orange)
            } else {
                ForEach(Array(draft.actions.enumerated()), id: \.offset) { index, action in
                    HStack(spacing: 8) {
                        Text("\(index + 1)")
                            .font(Theme.mono(10))
                            .foregroundStyle(Theme.Text.quaternary)
                            .frame(width: 14, alignment: .trailing)
                        ActionEditor(
                            action: action,
                            onChange: { updated in
                                model.updateDraft { $0 = $0.with(actions: replacing($0.actions, index, updated)) }
                            })
                        Spacer(minLength: 0)
                        Button("↑") { model.updateDraft { $0 = $0.with(actions: swapping($0.actions, index, index - 1)) } }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.Text.tertiary)
                            .disabled(index == 0)
                        Button("×") { model.updateDraft { $0 = $0.with(actions: removing($0.actions, index)) } }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.Text.tertiary)
                    }
                }
            }

            // The closed action vocabulary, as dashed chips. `hidePrefix`
            // is here because it IS an ordinary rule action — that is the
            // whole reason a hidden root is a rule row rather than a
            // separate synced setting.
            FlowRow(spacing: 6) {
                ForEach(ActionKind.allCases, id: \.self) { kind in
                    Button {
                        model.updateDraft { $0 = $0.with(actions: $0.actions + [kind.blank]) }
                    } label: {
                        Text("+ \(kind.rawValue)")
                            .font(Theme.mono(10.5))
                            .foregroundStyle(Theme.Text.tertiary)
                            .padding(.vertical, 3)
                            .padding(.horizontal, 7)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.Radius.chip)
                                    .strokeBorder(
                                        Theme.Border.subtleButton,
                                        style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var dryRunSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Dry run").modifier(Theme.sectionLabel())
            Text(dryRunSentence)
                .font(Theme.ui(Theme.TypeScale.body))
                .foregroundStyle(Theme.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if let applied = model.lastApplied {
                Text("Rule applied · \(applied.itemsUpdated) items updated, revertible from the write-back log")
                    .font(Theme.ui(Theme.TypeScale.secondary))
                    .foregroundStyle(Theme.Status.greenBright)
                if !applied.unknownCategories.isEmpty {
                    Text("No category named \(applied.unknownCategories.joined(separator: ", ")) — create it in Categories & Fields, then apply again.")
                        .font(Theme.ui(Theme.TypeScale.secondary))
                        .foregroundStyle(Theme.Status.warnText)
                }
            }

            HStack(spacing: 8) {
                Button("Save changes") { model.saveDraft() }
                    .buttonStyle(SecondaryButtonStyle(compact: true))
                    .disabled(!model.isDirty)
                Button("Revert") { model.revertDraft() }
                    .buttonStyle(SecondaryButtonStyle(compact: true))
                    .disabled(!model.isDirty)
                Spacer()
                Button("Apply this rule") { model.applySelected() }
                    .buttonStyle(PrimaryButtonStyle())
                    // Applying the SAVED rule, so an unsaved edit must be
                    // saved first rather than silently written.
                    .disabled(model.isDirty || model.draft?.actions.isEmpty ?? true)
            }
        }
    }

    private var dryRunSentence: String {
        guard let draft = model.draft else { return "" }
        guard !draft.actions.isEmpty else {
            return "Add at least one action to see what this rule would do."
        }
        guard let run = model.dryRun else { return "" }
        // The spec's sentence names metadata pairs. It is only the whole
        // truth when every match IS a metadata pair — a valueStartsWith
        // matcher fires on path segments and on-screen lines too — so the
        // noun follows the matches rather than the other way round.
        let noun = run.metadataMatches == run.matchedCandidates ? "metadata pairs" : "strings"
        return "Matches \(run.matchedCandidates) \(noun) across \(run.affectedItems) items. "
            + "\(run.actionCount) actions fold in order; nothing is written until you apply."
    }
}

// MARK: - Rule card

private struct RuleCard: View {
    let rule: RuleEngine.Rule
    let order: Int
    let isSelected: Bool
    let isFirst: Bool
    let isLast: Bool
    let onSelect: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("\(order)")
                    .font(Theme.mono(11, .semibold))
                    .foregroundStyle(Theme.Text.quaternary)
                    .frame(minWidth: 16, alignment: .trailing)

                chip(rule.matcher.explanation, Theme.Status.blueBright)
                Text("→").font(Theme.ui(11)).foregroundStyle(Theme.Text.quaternary)

                if rule.actions.isEmpty {
                    chip("no actions yet", Theme.Status.orange)
                } else {
                    FlowRow(spacing: 4) {
                        ForEach(Array(rule.actions.enumerated()), id: \.offset) { _, action in
                            chip(action.typeName, Theme.Status.greenBright)
                        }
                    }
                }
                Spacer(minLength: 4)

                Button("↑", action: onMoveUp).buttonStyle(.plain)
                    .foregroundStyle(Theme.Text.tertiary).disabled(isFirst)
                Button("↓", action: onMoveDown).buttonStyle(.plain)
                    .foregroundStyle(Theme.Text.tertiary).disabled(isLast)
                Button("×", action: onRemove).buttonStyle(.plain)
                    .foregroundStyle(Theme.Text.tertiary)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .fill(isSelected ? Theme.Surface.selectedRow : Theme.Surface.raised)
                .stroke(
                    isSelected ? Theme.Border.activeCard : Theme.Border.standard, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }

    private func chip(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(Theme.mono(10.5))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.vertical, 2)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.chip).fill(color.opacity(0.13)))
    }
}

// MARK: - One action's argument

private struct ActionEditor: View {
    let action: RuleAction
    let onChange: (RuleAction) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(action.typeName)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.Status.greenBright)
            if let argument = ActionKind(action)?.argument(of: action) {
                TextField(
                    ActionKind(action)?.placeholder ?? "",
                    text: Binding(
                        get: { argument },
                        set: { text in
                            guard let kind = ActionKind(action) else { return }
                            onChange(kind.withArgument(text))
                        }))
                    .textFieldStyle(.plain)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.Text.primary)
                    .frame(maxWidth: 180)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.chip)
                            .fill(Theme.Surface.well)
                            .stroke(Theme.Border.standard, lineWidth: 1))
            }
        }
    }
}

// MARK: - Action-list edits

// Written out rather than mutated in place: `RuleEngine.Rule` keeps its
// action list immutable, so every edit is a new list.

private func replacing(_ actions: [RuleAction], _ index: Int, _ action: RuleAction) -> [RuleAction] {
    var copy = actions
    guard copy.indices.contains(index) else { return copy }
    copy[index] = action
    return copy
}

private func swapping(_ actions: [RuleAction], _ a: Int, _ b: Int) -> [RuleAction] {
    var copy = actions
    guard copy.indices.contains(a), copy.indices.contains(b) else { return copy }
    copy.swapAt(a, b)
    return copy
}

private func removing(_ actions: [RuleAction], _ index: Int) -> [RuleAction] {
    var copy = actions
    guard copy.indices.contains(index) else { return copy }
    copy.remove(at: index)
    return copy
}
