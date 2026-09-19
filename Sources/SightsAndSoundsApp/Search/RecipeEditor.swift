import SwiftUI
import SightsAndSoundsKit

/// The recipe editor's two halves, shared by Settings › Search String
/// and the player's Search panel (spec 17, decisions 7 and 9): the
/// parts as rows with an Add menu, and the rules the same way. Each
/// half is a list plus its Add control — a ViewBuilder result, so it
/// sits inside a Form section or a plain stack alike — and owns the
/// drop state of its own drag-to-reorder.
struct RecipeParts: View {
    @Binding var recipe: SearchRecipe
    let categories: [TagCategory]
    var compact = false
    @State private var drop: ReorderSpot?

    var body: some View {
        if recipe.parts.isEmpty {
            Text("No parts yet. Add one below.")
                .font(compact ? Theme.ui(11) : .callout)
                .foregroundStyle(.secondary)
        }
        ForEach($recipe.parts) { $part in
            PartRow(
                part: $part, categories: categories,
                isFirst: recipe.parts.first?.id == part.id,
                isLast: recipe.parts.last?.id == part.id,
                compact: compact,
                onMove: { delta in move(part.id, by: delta) },
                onRemove: { recipe.parts.removeAll { $0.id == part.id } })
            .reorderTarget(.before(part.id), current: $drop) { dragged in
                recipe.parts = recipe.parts.moving(dragged, before: part.id)
            }
        }
        Menu("Add Part") {
            Button("Text") { recipe.parts.append(SearchPart(kind: .literal(""))) }
            Button("File name") {
                recipe.parts.append(SearchPart(
                    kind: .fileName(includesExtension: false, splitsPieces: true),
                    format: SearchFormat(quoting: .multiWord)))
            }
            Button("Tags") {
                recipe.parts.append(SearchPart(
                    kind: .tags(categoryID: categories.first?.id, joiner: " "),
                    format: SearchFormat(quoting: .multiWord)))
            }
        }
        .fixedSize()
        .reorderTarget(.end, current: $drop) { dragged in
            recipe.parts = recipe.parts.moving(dragged, before: nil)
        }
    }

    private func move(_ id: UUID, by delta: Int) {
        var parts = recipe.parts
        guard let index = parts.firstIndex(where: { $0.id == id }) else { return }
        let target = index + delta
        guard parts.indices.contains(target) else { return }
        parts.swapAt(index, target)
        recipe.parts = parts
    }
}

struct RecipeRules: View {
    @Binding var recipe: SearchRecipe
    var compact = false
    /// The item to preview against. Set, every rule shows beneath it
    /// the string as it stands once that rule has run — what the rule
    /// did, in the string's own terms, rather than in the abstract.
    var preview: SearchSubject?
    @State private var drop: ReorderSpot?

    var body: some View {
        let steps = preview.map { SearchStringBuilder.stringsAfterEachRule(recipe: recipe, subject: $0) } ?? []
        if recipe.rules.isEmpty {
            Text("No rules yet. Add one below.")
                .font(compact ? Theme.ui(11) : .callout)
                .foregroundStyle(.secondary)
        }
        ForEach($recipe.rules) { $rule in
            VStack(alignment: .leading, spacing: 3) {
                RuleRow(
                    rule: $rule,
                    isFirst: recipe.rules.first?.id == rule.id,
                    isLast: recipe.rules.last?.id == rule.id,
                    compact: compact,
                    onMove: { delta in move(rule.id, by: delta) },
                    onRemove: { recipe.rules.removeAll { $0.id == rule.id } })
                if let index = recipe.rules.firstIndex(where: { $0.id == rule.id }), steps.indices.contains(index) {
                    HStack(alignment: .top, spacing: 4) {
                        Text("→")
                            .font(Theme.mono(compact ? 10 : 10.5))
                            .foregroundStyle(Theme.Text.disabled)
                        Text(steps[index].isEmpty ? "(nothing)" : steps[index])
                            .font(Theme.mono(compact ? 10 : 10.5))
                            .foregroundStyle(steps[index].isEmpty ? Theme.Text.disabled : Theme.Text.tertiary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, compact ? 20 : 22)
                    .help("The string after this rule and the ones above it")
                }
            }
            .reorderTarget(.before(rule.id), current: $drop) { dragged in
                recipe.rules = recipe.rules.moving(dragged, before: rule.id)
            }
        }
        Menu("Add Rule") {
            Button("Exclude a value") { recipe.rules.append(SearchRule(kind: .exclude(""))) }
            Button("Replace text") { recipe.rules.append(SearchRule(kind: .replace(from: "-", to: " "))) }
            Button("Split at a separator") {
                recipe.rules.append(SearchRule(kind: .split(separator: "_", titleCaseWords: true, keep: .all)))
            }
        }
        .fixedSize()
        .reorderTarget(.end, current: $drop) { dragged in
            recipe.rules = recipe.rules.moving(dragged, before: nil)
        }
    }

    private func move(_ id: UUID, by delta: Int) {
        var rules = recipe.rules
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        let target = index + delta
        guard rules.indices.contains(target) else { return }
        rules.swapAt(index, target)
        recipe.rules = rules
    }
}

/// One part as a row: its kind's controls, then case and quoting for
/// the kinds that take them, then move and remove.
struct PartRow: View {
    @Binding var part: SearchPart
    let categories: [TagCategory]
    let isFirst: Bool
    let isLast: Bool
    /// Two lines instead of one — the player's rail is a third the
    /// width of the Settings window.
    var compact = false
    let onMove: (Int) -> Void
    let onRemove: () -> Void

    var body: some View {
        if compact {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    ReorderHandle(id: part.id, name: kindName)
                    Text(kindName)
                        .font(Theme.ui(10.5, .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .leading)
                    source
                    Spacer(minLength: 0)
                    moveAndRemove
                }
                if !part.isLiteral {
                    HStack(spacing: 6) {
                        Spacer().frame(width: 20)
                        formatPickers
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.vertical, 3)
        } else {
            wide
        }
    }

    private var wide: some View {
        HStack(spacing: 8) {
            ReorderHandle(id: part.id, name: kindName)
            Text(kindName)
                .font(Theme.ui(11, .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            source
            if !part.isLiteral { formatPickers }
            Spacer(minLength: 0)
            moveAndRemove
        }
    }

    /// The kind's own control: the text, the file-name toggles, or the
    /// category and joiner.
    @ViewBuilder
    private var source: some View {
        switch part.kind {
            case .literal:
                TextField("Text, used as typed", text: literalText)
                    .textFieldStyle(.roundedBorder)
            case .fileName:
                Toggle("Extension", isOn: includesExtension).toggleStyle(.checkbox)
                Toggle("Split at _", isOn: splitsPieces).toggleStyle(.checkbox)
            case .tags:
                Picker("", selection: categoryID) {
                    Text("All categories").tag(UUID?.none)
                    ForEach(categories) { Text($0.name).tag(UUID?.some($0.id)) }
                }
                .labelsHidden()
                .frame(maxWidth: 160)
                TextField("joiner", text: joiner)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 48)
                    .help("Between several tags of the category")
            }
    }

    private var moveAndRemove: some View {
        HStack(spacing: 4) {
            Button { onMove(-1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .disabled(isFirst)
            Button { onMove(1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless)
                .disabled(isLast)
            Button(action: onRemove) { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
        }
    }

    private var formatPickers: some View {
        Group {
            Picker("", selection: $part.format.letterCase) {
                ForEach(SearchLetterCase.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .labelsHidden()
            .frame(maxWidth: 110)
            Picker("", selection: $part.format.quoting) {
                ForEach(SearchQuoting.allCases, id: \.self) { Text("Quote: \($0.displayName)").tag($0) }
            }
            .labelsHidden()
            .frame(maxWidth: 150)
        }
    }

    private var kindName: String {
        switch part.kind {
        case .literal: "Text"
        case .fileName: "File name"
        case .tags: "Tags"
        }
    }

    private var literalText: Binding<String> {
        Binding(
            get: { if case .literal(let text) = part.kind { text } else { "" } },
            set: { part.kind = .literal($0) })
    }

    private var includesExtension: Binding<Bool> {
        Binding(
            get: { if case .fileName(let ext, _) = part.kind { ext } else { false } },
            set: { on in
                if case .fileName(_, let split) = part.kind { part.kind = .fileName(includesExtension: on, splitsPieces: split) }
            })
    }

    private var splitsPieces: Binding<Bool> {
        Binding(
            get: { if case .fileName(_, let split) = part.kind { split } else { false } },
            set: { on in
                if case .fileName(let ext, _) = part.kind { part.kind = .fileName(includesExtension: ext, splitsPieces: on) }
            })
    }

    private var categoryID: Binding<UUID?> {
        Binding(
            get: { if case .tags(let id, _) = part.kind { id } else { nil } },
            set: { id in
                if case .tags(_, let joiner) = part.kind { part.kind = .tags(categoryID: id, joiner: joiner) }
            })
    }

    private var joiner: Binding<String> {
        Binding(
            get: { if case .tags(_, let joiner) = part.kind { joiner } else { " " } },
            set: { text in
                if case .tags(let id, _) = part.kind { part.kind = .tags(categoryID: id, joiner: text) }
            })
    }
}

/// One rule as a row: Exclude with its value, or Replace with its two
/// sides, then move and remove.
struct RuleRow: View {
    @Binding var rule: SearchRule
    let isFirst: Bool
    let isLast: Bool
    /// Narrower fields for the player's rail.
    var compact = false
    let onMove: (Int) -> Void
    let onRemove: () -> Void

    var body: some View {
        switch rule.kind {
        case .exclude:
            HStack(spacing: compact ? 6 : 8) {
                ReorderHandle(id: rule.id, name: kindName)
                kindLabel
                TextField(compact ? "Text to remove" : "Text to remove wherever it appears — a prefix like sdg", text: excludeText)
                    .textFieldStyle(.roundedBorder)
                Picker("", selection: excludeKeep) {
                    ForEach(SearchExcludeKeep.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: 104)
                .help("Remove every occurrence, or all but the first or the last")
                Spacer(minLength: 0)
                moveAndRemove
            }
        case .replace:
            // Two lines: the two sides read as a pair, and neither field
            // is squeezed to a few characters beside the other.
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: compact ? 6 : 8) {
                    ReorderHandle(id: rule.id, name: kindName)
                    kindLabel
                    TextField("Text to replace", text: replaceFrom)
                        .textFieldStyle(.roundedBorder)
                    Spacer(minLength: 0)
                    moveAndRemove
                }
                HStack(spacing: compact ? 6 : 8) {
                    Spacer().frame(width: compact ? 20 : 22)
                    Text("with")
                        .font(Theme.ui(compact ? 10.5 : 11, .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: compact ? 56 : 64, alignment: .leading)
                    TextField("Replacement — empty removes the text", text: replaceTo)
                        .textFieldStyle(.roundedBorder)
                    Spacer(minLength: 0)
                    // The width the move and remove buttons take above,
                    // so the two fields line up.
                    moveAndRemove.hidden()
                }
            }
            .padding(.vertical, compact ? 3 : 0)
        case .split:
            HStack(spacing: compact ? 6 : 8) {
                ReorderHandle(id: rule.id, name: kindName)
                kindLabel
                Text("at")
                    .font(Theme.ui(compact ? 10.5 : 11))
                    .foregroundStyle(.secondary)
                TextField("_", text: splitSeparator)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 52)
                    .help("The separator each value breaks at")
                Toggle(compact ? "Capitals" : "And at capitals", isOn: splitTitleCaseWords)
                    .toggleStyle(.checkbox)
                    .font(Theme.ui(compact ? 10.5 : 11))
                    .help("Also break a run at the capitals inside it — OnStage becomes On Stage")
                Picker("", selection: splitKeep) {
                    ForEach(SearchSplitKeep.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: 104)
                .help("Every piece, or only the first or the last one with something in it")
                Spacer(minLength: 0)
                moveAndRemove
            }
        }
    }

    private var kindLabel: some View {
        Text(kindName)
            .font(Theme.ui(compact ? 10.5 : 11, .semibold))
            .foregroundStyle(.secondary)
            .frame(width: compact ? 56 : 64, alignment: .leading)
    }

    private var moveAndRemove: some View {
        HStack(spacing: 4) {
            Button { onMove(-1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .disabled(isFirst)
            Button { onMove(1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless)
                .disabled(isLast)
            Button(action: onRemove) { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
        }
    }

    private var kindName: String {
        switch rule.kind {
        case .exclude: "Exclude"
        case .replace: "Replace"
        case .split: "Split"
        }
    }

    private var splitSeparator: Binding<String> {
        Binding(
            get: { if case .split(let separator, _, _) = rule.kind { separator } else { "" } },
            set: { separator in
                if case .split(_, let words, let keep) = rule.kind {
                    rule.kind = .split(separator: separator, titleCaseWords: words, keep: keep)
                }
            })
    }

    private var splitTitleCaseWords: Binding<Bool> {
        Binding(
            get: { if case .split(_, let words, _) = rule.kind { words } else { false } },
            set: { words in
                if case .split(let separator, _, let keep) = rule.kind {
                    rule.kind = .split(separator: separator, titleCaseWords: words, keep: keep)
                }
            })
    }

    private var splitKeep: Binding<SearchSplitKeep> {
        Binding(
            get: { if case .split(_, _, let keep) = rule.kind { keep } else { .all } },
            set: { keep in
                if case .split(let separator, let words, _) = rule.kind {
                    rule.kind = .split(separator: separator, titleCaseWords: words, keep: keep)
                }
            })
    }

    private var excludeText: Binding<String> {
        Binding(
            get: { if case .exclude(let text, _) = rule.kind { text } else { "" } },
            set: { text in
                if case .exclude(_, let keep) = rule.kind { rule.kind = .exclude(text, keep: keep) }
            })
    }

    private var excludeKeep: Binding<SearchExcludeKeep> {
        Binding(
            get: { if case .exclude(_, let keep) = rule.kind { keep } else { .none } },
            set: { keep in
                if case .exclude(let text, _) = rule.kind { rule.kind = .exclude(text, keep: keep) }
            })
    }

    private var replaceFrom: Binding<String> {
        Binding(
            get: { if case .replace(let from, _) = rule.kind { from } else { "" } },
            set: { from in if case .replace(_, let to) = rule.kind { rule.kind = .replace(from: from, to: to) } })
    }

    private var replaceTo: Binding<String> {
        Binding(
            get: { if case .replace(_, let to) = rule.kind { to } else { "" } },
            set: { to in if case .replace(let from, _) = rule.kind { rule.kind = .replace(from: from, to: to) } })
    }
}

// MARK: - Drag to reorder

/// Where a dragged row would land: before one row, or last.
enum ReorderSpot: Equatable {
    case before(UUID)
    case end
}

/// The ≡ at the left of a part or rule row: drag it, and the row
/// follows. The payload is the row's id, the same transferable the tag
/// panel's rows use.
struct ReorderHandle: View {
    let id: UUID
    let name: String

    var body: some View {
        Text("≡")
            .font(Theme.ui(13))
            .foregroundStyle(.secondary)
            .frame(width: 14)
            .help("Drag to reorder")
            .draggable(PanelRowDrag(id: id)) {
                Text(name)
                    .font(Theme.ui(11.5, .semibold))
                    .padding(.vertical, 4)
                    .padding(.horizontal, 10)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.control)
                            .fill(Theme.Surface.raised)
                            .stroke(Theme.Border.activeCard, lineWidth: 1))
            }
    }
}

extension View {
    /// One landing spot: the row shows an amber line along its top while
    /// a drag hovers, and takes the drop as "put the dragged row here".
    func reorderTarget(
        _ spot: ReorderSpot, current: Binding<ReorderSpot?>, onDrop: @escaping (UUID) -> Void
    ) -> some View {
        self
            .overlay(alignment: .top) {
                if current.wrappedValue == spot {
                    Rectangle().fill(Theme.Accent.amber).frame(height: 2)
                }
            }
            .dropDestination(for: PanelRowDrag.self) { dropped, _ in
                current.wrappedValue = nil
                guard let dragged = dropped.first else { return false }
                onDrop(dragged.id)
                return true
            } isTargeted: { inside in
                if inside {
                    current.wrappedValue = spot
                } else if current.wrappedValue == spot {
                    current.wrappedValue = nil
                }
            }
    }
}
