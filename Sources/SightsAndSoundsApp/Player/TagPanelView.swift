import SwiftUI
import SightsAndSoundsKit

/// The tag editing panel, top of the player's right rail — the tagging
/// surface, kept out of the player's own responsibilities.
///
/// It is also where the playing item's tags are *shown*: the info strip
/// under the video used to draw a second set of pills, in a second style,
/// from the same data. One name, one place — and here they carry their
/// category's hue, which is what makes a wall of pills readable.
///
/// Checkbox categories render as checkbox lists (Alt+1…9 toggles the
/// first one); everything else is pills + autocomplete.
struct TagPanelView: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Tags").modifier(Theme.sectionLabel())
                Spacer()
                Text(appliedCount == 0 ? "" : "\(appliedCount) applied")
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.Text.disabled)
                ZoneBadge(zone: .tags)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // An empty vocabulary used to render the panel as a
                    // bare strip that read as "nothing happened" — say
                    // why instead.
                    if model.panelVocabulary.isEmpty {
                        Text("No tag categories in this library yet — create them from the browse toolbar's Categories button.")
                            .font(Theme.ui(12))
                            .foregroundStyle(Theme.Text.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(model.panelVocabulary) { entry in
                        if let label = entry.category.sectionLabel {
                            if label.isEmpty {
                                Divider().overlay(Theme.Border.standard)
                            } else {
                                Text(label).modifier(Theme.sectionLabel())
                            }
                        }
                        switch entry.category.displayStyle {
                        case .checkboxes, .radio:
                            CheckboxCategoryView(
                                entry: entry,
                                isAltTarget: entry.id == model.checkboxCategory?.id,
                                single: entry.category.displayStyle == .radio)
                        case .search:
                            PillCategoryView(
                                entry: entry,
                                // Focus is the FIRST visible category, not
                                // a flag a category carries — which is one
                                // setting and one whole class of conflict
                                // fewer.
                                takesFocus: entry.id == model.focusCategoryID)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { model.zone = .tags }
    }

    private var appliedCount: Int {
        model.itemTags.reduce(0) { $0 + $1.tags.count }
    }
}

/// A category's own hue, for its heading and its pills.
private struct CategoryHeading: View {
    let category: TagCategory

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Theme.categoryHue(category.colorIndex))
                .frame(width: 6, height: 6)
            Text(category.name)
                .font(Theme.ui(12, .semibold))
                .foregroundStyle(Theme.Text.primary)
        }
    }
}

private struct CheckboxCategoryView: View {
    @Environment(PlayerModel.self) private var model
    let entry: CategoryTags
    let isAltTarget: Bool
    /// A radio category shows the same list; picking replaces rather
    /// than adds, which `assignTag` already enforces for single-select.
    var single = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            CategoryHeading(category: entry.category)
            ForEach(Array(entry.tags.enumerated()), id: \.element.id) { index, tag in
                let on = model.hasTag(tag.id)
                Button {
                    model.toggleTag(tag.id)
                } label: {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: single ? 7 : Theme.Radius.chip)
                            .fill(on ? hue : .clear)
                            .stroke(on ? hue : Theme.Border.subtleButtonHover, lineWidth: 1)
                            .frame(width: 13, height: 13)
                            .overlay {
                                if on {
                                    Image(systemName: "checkmark")
                                        .font(Theme.ui(8, .bold))
                                        .foregroundStyle(Theme.Text.onAmber)
                                }
                            }
                        Text(tag.name)
                            .font(Theme.ui(12))
                            .foregroundStyle(on ? Theme.Text.primary : Theme.Text.tertiary)
                        if isAltTarget, index < 9 {
                            Text("⌥\(index + 1)")
                                .font(Theme.mono(9))
                                .foregroundStyle(Theme.Text.disabled)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var hue: Color { Theme.categoryHue(entry.category.colorIndex) }
}

private struct PillCategoryView: View {
    @Environment(PlayerModel.self) private var model
    let entry: CategoryTags
    var takesFocus = false
    @State private var draft = ""
    /// Which suggestion the arrows have landed on. Nil means none — and
    /// nil is exactly what makes Enter create rather than apply.
    @State private var highlighted: Int?
    @State private var creating = false
    @FocusState private var fieldFocused: Bool

    private var applied: [Tag] {
        model.itemTags.first { $0.id == entry.id }?.tags ?? []
    }

    private var query: String { draft.trimmingCharacters(in: .whitespaces) }

    /// A suggested tag, and the alias that put it there when the tag's
    /// own name did not match. Carried rather than recomputed at draw
    /// time so the row can say WHY it is being offered — "Soundboard
    /// (SBD)" answers a question a bare "Soundboard" leaves open.
    private struct Suggestion: Identifiable {
        let tag: Tag
        let matchedAlias: String?
        var id: UUID { tag.id }
    }

    private var suggestions: [Suggestion] {
        guard !query.isEmpty else { return [] }
        let appliedIDs = Set(applied.map(\.id))
        return entry.tags
            .compactMap { tag -> Suggestion? in
                guard !appliedIDs.contains(tag.id) else { return nil }
                // The name winning means no alias is shown, even if one
                // would also have matched: the parenthetical exists to
                // explain a row you would not otherwise expect.
                if tag.name.localizedCaseInsensitiveContains(query) {
                    return Suggestion(tag: tag, matchedAlias: nil)
                }
                // An alias IS a name: typing SBD must offer Soundboard.
                guard let alias = (model.panelAliases[tag.id] ?? [])
                    .first(where: { $0.localizedCaseInsensitiveContains(query) })
                else { return nil }
                return Suggestion(tag: tag, matchedAlias: alias)
            }
            .prefix(AppSettingsStore.shared.current.tagSuggestionLimit)
            .map { $0 }
    }

    /// A tag named exactly what was typed, selected on sight so Enter
    /// applies it instead of offering to create a duplicate.
    private var exactMatchIndex: Int? {
        suggestions.firstIndex {
            $0.tag.name.localizedCaseInsensitiveCompare(query) == .orderedSame
                || ($0.matchedAlias?.localizedCaseInsensitiveCompare(query) == .orderedSame)
        }
    }

    /// What Enter acts on: the arrowed-to row, else the exact match.
    private var activeIndex: Int? { highlighted ?? exactMatchIndex }

    /// Nothing selected and something typed — Enter will make a new tag,
    /// and the field says so rather than letting you find out.
    private var willCreate: Bool { !query.isEmpty && activeIndex == nil }

    private var hue: Color { Theme.categoryHue(entry.category.colorIndex) }

    /// Walk the suggestions. Coming off either end clears the selection
    /// rather than wrapping, because "nothing selected" is a real state
    /// here — it is the one where Enter creates.
    private func move(_ delta: Int) -> KeyPress.Result {
        guard !suggestions.isEmpty else { return .ignored }
        switch (highlighted, delta) {
        case (nil, 1): highlighted = 0
        case (nil, -1): highlighted = suggestions.count - 1
        case (let current?, _):
            let next = current + delta
            highlighted = suggestions.indices.contains(next) ? next : nil
        default: break
        }
        return .handled
    }

    /// Enter: apply what is selected, or create when nothing is.
    private func commit() {
        guard !query.isEmpty else { return }
        if let index = activeIndex, suggestions.indices.contains(index) {
            apply(suggestions[index].tag)
        } else {
            creating = true
        }
    }

    private func apply(_ tag: Tag) {
        model.toggleTag(tag.id)
        draft = ""
        highlighted = nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CategoryHeading(category: entry.category)

            if !applied.isEmpty {
                FlowRow(spacing: 4) {
                    ForEach(applied) { tag in
                        HStack(spacing: 4) {
                            Text(tag.name)
                                .font(Theme.ui(11.5))
                                .foregroundStyle(hue)
                            Button {
                                model.toggleTag(tag.id)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(Theme.ui(8, .semibold))
                                    .foregroundStyle(hue.opacity(0.7))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 3)
                        .padding(.horizontal, 9)
                        .background {
                            Capsule().fill(hue.opacity(0.13))
                        }
                        .overlay {
                            Capsule().stroke(hue.opacity(0.35), lineWidth: 1)
                        }
                    }
                }
            }

            HStack(spacing: 6) {
                TextField("Add \(entry.category.name)…", text: $draft)
                    .textFieldStyle(.plain)
                    .font(Theme.ui(12))
                    .focused($fieldFocused)
                    .onSubmit(commit)
                    .onChange(of: draft) { _, _ in
                        // A new query invalidates the old highlight.
                        highlighted = nil
                    }
                    .onChange(of: fieldFocused) { _, focused in
                        if focused { model.zone = .tags }
                    }
                    // Arrows before the field sees them: a single-line
                    // field does nothing with up and down, and shifted
                    // arrows still walk the playlist.
                    .onKeyPress(.upArrow) { move(-1) }
                    .onKeyPress(.downArrow) { move(1) }
                if willCreate {
                    Text("(New Tag)")
                        .font(Theme.mono(9.5))
                        .foregroundStyle(Theme.Accent.amber)
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 9)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .fill(Theme.Surface.well)
                    .stroke(
                        fieldFocused ? Theme.Border.activeControl : Theme.Border.standard,
                        lineWidth: 1))

            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                let active = index == activeIndex
                Button {
                    apply(suggestion.tag)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus")
                            .font(Theme.ui(9))
                            .foregroundStyle(hue)
                        Text(suggestion.tag.name)
                            .font(Theme.ui(11.5, active ? .medium : .regular))
                            .foregroundStyle(active ? Theme.Text.primary : Theme.Text.secondary)
                        // Why this row is here, when the name alone does
                        // not explain it.
                        if let alias = suggestion.matchedAlias {
                            Text("(\(alias))")
                                .font(Theme.mono(9.5))
                                .foregroundStyle(Theme.Text.disabled)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 2)
                    .padding(.horizontal, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(active ? hue.opacity(0.16) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .task(id: model.item?.id) {
            if takesFocus { fieldFocused = true }
        }
        .sheet(isPresented: $creating) {
            NewTagSheet(categoryID: entry.category.id, initialName: query) { tag in
                model.toggleTag(tag.id)
                draft = ""
                highlighted = nil
            }
            .environment(model)
        }
    }
}
