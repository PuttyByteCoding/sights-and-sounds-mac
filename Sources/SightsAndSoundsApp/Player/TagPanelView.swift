import SwiftUI
import UniformTypeIdentifiers
import SightsAndSoundsKit

/// What a dragged panel row carries: the row's id, as plain binary
/// data. Not a plain string — every row holds a text field, and AppKit
/// fields accept dropped text natively, so a string payload released
/// over a field was pasted into it instead of reaching the row's drop
/// handler. And not an app-declared content type either: one declared
/// at runtime is not one the drop targets can match, so no row ever
/// lit as a target. `public.data` is a system type that text fields do
/// not claim and every target recognises.
struct PanelRowDrag: Transferable, Equatable {
    let id: UUID

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(contentType: .data) { payload in
            Data(payload.id.uuidString.utf8)
        } importing: { data in
            guard let id = String(data: data, encoding: .utf8).flatMap(UUID.init(uuidString:))
            else { throw CocoaError(.coderInvalidValue) }
            return PanelRowDrag(id: id)
        }
    }
}

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
    /// Which category's Add field holds the keyboard. Panel-owned so Tab
    /// can WALK it: each field advances to the next search category, and
    /// a per-field Bool could not know who is next.
    @FocusState private var focusedCategory: UUID?
    /// Where a dragged category would land — the amber line under the
    /// pointer. Nil when nothing is in flight.
    @State private var dropTargetID: UUID?
    @State private var dropAtEnd = false
    /// The Universal field's place among the categories — mirrored from
    /// settings so a drag re-renders immediately and survives relaunch.
    @State private var universalPosition
        = AppSettingsStore.shared.current.universalTagFieldPosition
    /// The Tag Analysis Results field's place — same rule, own setting.
    @State private var resultsPosition
        = AppSettingsStore.shared.current.analysisResultsFieldPosition
    /// The On-screen Text field's place — same rule, own setting.
    @State private var onScreenPosition
        = AppSettingsStore.shared.current.onScreenTextFieldPosition

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
                    if clampedUniversalPosition == 0 {
                        universalBlock
                    }
                    if clampedResultsPosition == 0 {
                        resultsBlock
                    }
                    if clampedOnScreenPosition == 0 {
                        onScreenBlock
                    }
                    ForEach(Array(model.panelVocabulary.enumerated()), id: \.element.id) { index, entry in
                        if let label = entry.category.sectionLabel {
                            if label.isEmpty {
                                Divider().overlay(Theme.Border.standard)
                            } else {
                                Text(label).modifier(Theme.sectionLabel())
                            }
                        }
                        Group {
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
                                    // The Universal field outranks the
                                    // first category when it is ordered
                                    // first.
                                    takesFocus: entry.id == model.focusCategoryID
                                        && clampedUniversalPosition != 0,
                                    focus: $focusedCategory,
                                    onAdvance: { forward in advance(from: entry.id, forward: forward) })
                            }
                        }
                        .landingLine(when: dropTargetID == entry.category.id)
                        // Dropping a dragged heading on a category slots
                        // it in BEFORE that category.
                        .dropDestination(for: PanelRowDrag.self) { dropped, _ in
                            dropTargetID = nil
                            guard let id = dropped.first?.id else { return false }
                            if !setPseudoFieldPosition(id, to: index) {
                                model.moveCategory(id, before: entry.category.id)
                            }
                            return true
                        } isTargeted: { inside in
                            dropTargetID = inside ? entry.category.id : (
                                dropTargetID == entry.category.id ? nil : dropTargetID)
                        }
                        // The Universal field renders AFTER the category
                        // it is positioned behind.
                        if clampedUniversalPosition == index + 1 {
                            universalBlock
                        }
                        if clampedResultsPosition == index + 1 {
                            resultsBlock
                        }
                        if clampedOnScreenPosition == index + 1 {
                            onScreenBlock
                        }
                    }
                    // …and the space under the list is "make it last".
                    Rectangle()
                        .fill(.clear)
                        .frame(height: 40)
                        .contentShape(Rectangle())
                        .landingLine(when: dropAtEnd)
                        .dropDestination(for: PanelRowDrag.self) { dropped, _ in
                            dropAtEnd = false
                            guard let id = dropped.first?.id else { return false }
                            if !setPseudoFieldPosition(id, to: model.panelVocabulary.count) {
                                model.moveCategory(id, before: nil)
                            }
                            return true
                        } isTargeted: { inside in
                            dropAtEnd = inside
                        }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { model.zone = .tags }
        // The focus lives here as FocusState; the model mirrors it so
        // the player's key handler — where Tab actually arrives — can
        // walk it. Two onChanges, one in each direction, and the guards
        // stop them ping-ponging.
        .onChange(of: focusedCategory) { _, now in
            if model.tagFieldCategoryID != now { model.tagFieldCategoryID = now }
        }
        .onChange(of: model.tagFieldCategoryID) { _, now in
            if focusedCategory != now { focusedCategory = now }
        }
    }

    private var appliedCount: Int {
        model.itemTags.reduce(0) { $0 + $1.tags.count }
    }

    /// Clamped so a category deletion cannot strand the field past the
    /// end of the list.
    private var clampedUniversalPosition: Int {
        min(max(0, universalPosition), model.panelVocabulary.count)
    }

    private func setUniversalPosition(_ position: Int) {
        universalPosition = position
        AppSettingsStore.shared.update { $0.universalTagFieldPosition = position }
    }

    private var clampedResultsPosition: Int {
        min(max(0, resultsPosition), model.panelVocabulary.count)
    }

    private func setResultsPosition(_ position: Int) {
        resultsPosition = position
        AppSettingsStore.shared.update { $0.analysisResultsFieldPosition = position }
    }

    private var clampedOnScreenPosition: Int {
        min(max(0, onScreenPosition), model.panelVocabulary.count)
    }

    private func setOnScreenPosition(_ position: Int) {
        onScreenPosition = position
        AppSettingsStore.shared.update { $0.onScreenTextFieldPosition = position }
    }

    /// A dragged heading's id, if it is one of the pseudo-fields.
    private func setPseudoFieldPosition(_ id: UUID, to position: Int) -> Bool {
        if id == PlayerModel.universalFieldFocusID { setUniversalPosition(position); return true }
        if id == PlayerModel.analysisResultsFieldFocusID { setResultsPosition(position); return true }
        if id == PlayerModel.onScreenTextFieldFocusID { setOnScreenPosition(position); return true }
        return false
    }

    /// The Universal search, as a reorderable row like any category:
    /// labeled heading, far-right ≡ grip, and the same landing line.
    @ViewBuilder
    private var universalBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.Accent.amber)
                    .frame(width: 6, height: 6)
                Text("Universal")
                    .font(Theme.ui(12, .semibold))
                    .foregroundStyle(Theme.Text.primary)
                Spacer(minLength: 6)
                Text("≡")
                    .font(Theme.ui(12))
                    .foregroundStyle(Theme.Text.disabled)
                    .help("Drag to reorder — the Universal field sits among the categories")
                    .draggable(PanelRowDrag(id: PlayerModel.universalFieldFocusID)) {
                        DragPreview(name: "Universal")
                    }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            GlobalTagField(
                takesFocus: clampedUniversalPosition == 0,
                focus: $focusedCategory)
        }
        .landingLine(when: dropTargetID == PlayerModel.universalFieldFocusID)
        .dropDestination(for: PanelRowDrag.self) { dropped, _ in
            dropTargetID = nil
            guard let id = dropped.first?.id, id != PlayerModel.universalFieldFocusID
            else { return false }
            // The other pseudo-field dropped here takes this slot; a
            // category dropped here takes it and pushes the field down —
            // insert before the category the field currently precedes.
            if setPseudoFieldPosition(id, to: clampedUniversalPosition) { return true }
            let following = clampedUniversalPosition < model.panelVocabulary.count
                ? model.panelVocabulary[clampedUniversalPosition].category.id : nil
            model.moveCategory(id, before: following)
            return true
        } isTargeted: { inside in
            dropTargetID = inside
                ? PlayerModel.universalFieldFocusID
                : (dropTargetID == PlayerModel.universalFieldFocusID ? nil : dropTargetID)
        }
    }

    /// The Tag Analysis Results row, reorderable like the Universal one:
    /// heading, ≡ grip, the same landing line, the field underneath.
    @ViewBuilder
    private var resultsBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.Accent.amber)
                    .frame(width: 6, height: 6)
                Text("Tag Analysis Results")
                    .font(Theme.ui(12, .semibold))
                    .foregroundStyle(Theme.Text.primary)
                Spacer(minLength: 6)
                Text("≡")
                    .font(Theme.ui(12))
                    .foregroundStyle(Theme.Text.disabled)
                    .help("Drag to reorder — the field sits among the categories")
                    .draggable(PanelRowDrag(id: PlayerModel.analysisResultsFieldFocusID)) {
                        DragPreview(name: "Tag Analysis Results")
                    }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            AnalysisResultsField(
                session: model.analysisSession,
                appliedIDs: Set(model.itemTags.flatMap(\.tags).map(\.id)),
                categories: model.panelVocabulary.map(\.category),
                focus: $focusedCategory,
                focusID: PlayerModel.analysisResultsFieldFocusID,
                itemID: model.item?.id,
                onApply: { model.applyTag($0.id) })
        }
        .landingLine(when: dropTargetID == PlayerModel.analysisResultsFieldFocusID)
        .dropDestination(for: PanelRowDrag.self) { dropped, _ in
            dropTargetID = nil
            guard let id = dropped.first?.id, id != PlayerModel.analysisResultsFieldFocusID
            else { return false }
            if setPseudoFieldPosition(id, to: clampedResultsPosition) { return true }
            let following = clampedResultsPosition < model.panelVocabulary.count
                ? model.panelVocabulary[clampedResultsPosition].category.id : nil
            model.moveCategory(id, before: following)
            return true
        } isTargeted: { inside in
            dropTargetID = inside
                ? PlayerModel.analysisResultsFieldFocusID
                : (dropTargetID == PlayerModel.analysisResultsFieldFocusID ? nil : dropTargetID)
        }
    }

    /// The On-screen Text row, reorderable like the other two.
    @ViewBuilder
    private var onScreenBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.Accent.amber)
                    .frame(width: 6, height: 6)
                Text("On-screen Text")
                    .font(Theme.ui(12, .semibold))
                    .foregroundStyle(Theme.Text.primary)
                Spacer(minLength: 6)
                Text("≡")
                    .font(Theme.ui(12))
                    .foregroundStyle(Theme.Text.disabled)
                    .help("Drag to reorder — the field sits among the categories")
                    .draggable(PanelRowDrag(id: PlayerModel.onScreenTextFieldFocusID)) {
                        DragPreview(name: "On-screen Text")
                    }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            OnScreenTextField(
                fileURL: model.fileURL,
                isAudio: model.isAudio,
                currentSeconds: model.currentSeconds,
                index: model.tagSearchIndex,
                categories: model.panelVocabulary.map(\.category),
                library: model.library,
                libraryID: model.libraryID,
                focus: $focusedCategory,
                focusID: PlayerModel.onScreenTextFieldFocusID,
                itemID: model.item?.id,
                onApply: { model.applyTag($0.id) },
                onCreated: { tag in
                    model.refreshTagging()
                    model.applyTag(tag.id)
                })
        }
        .landingLine(when: dropTargetID == PlayerModel.onScreenTextFieldFocusID)
        .dropDestination(for: PanelRowDrag.self) { dropped, _ in
            dropTargetID = nil
            guard let id = dropped.first?.id, id != PlayerModel.onScreenTextFieldFocusID
            else { return false }
            if setPseudoFieldPosition(id, to: clampedOnScreenPosition) { return true }
            let following = clampedOnScreenPosition < model.panelVocabulary.count
                ? model.panelVocabulary[clampedOnScreenPosition].category.id : nil
            model.moveCategory(id, before: following)
            return true
        } isTargeted: { inside in
            dropTargetID = inside
                ? PlayerModel.onScreenTextFieldFocusID
                : (dropTargetID == PlayerModel.onScreenTextFieldFocusID ? nil : dropTargetID)
        }
    }

    /// The Tab order lives on the model (search categories only, in
    /// panel order, wrapping) so the player's key handler and this panel
    /// walk the same list — Tab arrives at the HANDLER while a field is
    /// typing, never at the field.
    private func advance(from id: UUID, forward: Bool) {
        model.tagFieldCategoryID = id
        model.advanceTagField(reverse: !forward)
        focusedCategory = model.tagFieldCategoryID
    }
}

/// A category's own hue, for its heading and its pills.
private struct CategoryHeading: View {
    let category: TagCategory
    /// Set by the panel: the heading grows a ≡ handle that drags the
    /// whole category. On the HANDLE, not the block — a drag that
    /// starts anywhere would fight text selection and the pills.
    var draggable = false

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Theme.categoryHue(category.colorIndex))
                .frame(width: 6, height: 6)
            Text(category.name)
                .font(Theme.ui(12, .semibold))
                .foregroundStyle(Theme.Text.primary)
            if draggable {
                Spacer(minLength: 6)
                // Far right, where every list puts its grip.
                Text("≡")
                    .font(Theme.ui(12))
                    .foregroundStyle(Theme.Text.disabled)
                    .help("Drag to reorder categories")
                    .draggable(PanelRowDrag(id: category.id)) {
                        DragPreview(name: category.name)
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CheckboxCategoryView: View {
    @Environment(PlayerModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let entry: CategoryTags
    let isAltTarget: Bool
    /// A radio category shows the same list; picking replaces rather
    /// than adds, which `assignTag` already enforces for single-select.
    var single = false
    @State private var editing: Tag?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            CategoryHeading(category: entry.category, draggable: true)
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
                .contextMenu {
                    Button("Edit Tag…") { editing = tag }
                    Button("Show Items with This Tag") {
                        openTagPlayerWindow(
                            tag: tag, library: model.library,
                            libraryID: model.libraryID, openWindow: openWindow)
                    }
                }
            }
        }
        .sheet(item: $editing) { tag in
            TagSheet(
                mode: .edit(tag),
                library: model.library,
                libraryID: model.libraryID,
                categories: model.panelVocabulary.map(\.category)
            ) { _ in model.refreshTagging() }
        }
    }

    private var hue: Color { Theme.categoryHue(entry.category.colorIndex) }
}

private struct PillCategoryView: View {
    @Environment(PlayerModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let entry: CategoryTags
    var takesFocus = false
    var focus: FocusState<UUID?>.Binding
    var onAdvance: (Bool) -> Void
    @State private var draft = ""
    /// Which suggestion the arrows have landed on. Nil means none — and
    /// nil is exactly what makes Enter create rather than apply.
    @State private var highlighted: Int?
    @State private var creating = false
    /// Empty query + ↑ shows the session's recently applied tags (this
    /// category's) instead of autocomplete. Typing anything returns to
    /// the ordinary suggestions.
    @State private var showingHistory = false
    /// Empty query + ↓ lists the whole category — every tag not yet on
    /// the item, name order — so the field answers "what is there to
    /// pick?" without a letter typed. Typing narrows it as usual.
    @State private var browsingAll = false
    /// The tag whose editor is open, from a right-click on any tag this
    /// category draws — applied pill or suggestion alike.
    @State private var editing: Tag?
    private var fieldFocused: Bool { focus.wrappedValue == entry.id }

    /// The sheet takes the keyboard; closing it must hand the keyboard
    /// BACK to the field the operator was typing in — creating a tag is
    /// a detour, not a destination.
    private func restoreFieldFocus() {
        focus.wrappedValue = entry.id
        model.tagFieldCategoryID = entry.id
    }

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

    /// History renders ABOVE the field (newest touching the box) where
    /// autocomplete renders below — up-arrow reaches upward.
    private var historyActive: Bool { showingHistory && query.isEmpty }

    private var suggestions: [Suggestion] {
        // History mode: the session's recent applies from THIS category,
        // newest first, walkable and pickable exactly like autocomplete.
        if query.isEmpty {
            let appliedIDs = Set(applied.map(\.id))
            if showingHistory {
                return model.recentlyAppliedTagIDs.compactMap { id in
                    guard !appliedIDs.contains(id),
                          let tag = entry.tags.first(where: { $0.id == id })
                    else { return nil }
                    return Suggestion(tag: tag, matchedAlias: nil)
                }
            }
            // Browse mode: the category's tags, capped like autocomplete
            // so a thousand-tag category stays a list, not a wall.
            guard browsingAll else { return [] }
            return entry.tags
                .filter { !appliedIDs.contains($0.id) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .prefix(AppSettingsStore.shared.current.tagSuggestionLimit)
                .map { Suggestion(tag: $0, matchedAlias: nil) }
        }
        let appliedIDs = Set(applied.map(\.id))
        // Space-separated terms, folded once, matched against the
        // model's PRE-FOLDED index — folding live per keystroke across a
        // large category was the slow half of matching.
        let foldedTerms = query.split(separator: " ").map { PlayerModel.searchFold(String($0)) }
        return model.tagSearchIndex
            .lazy
            .filter { $0.categoryID == entry.category.id }
            .compactMap { row -> Suggestion? in
                guard !appliedIDs.contains(row.tag.id) else { return nil }
                // The name winning means no alias is shown, even if one
                // would also have matched: the parenthetical exists to
                // explain a row you would not otherwise expect.
                if foldedTerms.allSatisfy({ row.foldedName.contains($0) }) {
                    return Suggestion(tag: row.tag, matchedAlias: nil)
                }
                // An alias IS a name: typing SBD must offer Soundboard.
                guard let alias = row.foldedAliases.first(where: { candidate in
                    foldedTerms.allSatisfy { candidate.folded.contains($0) }
                })
                else { return nil }
                return Suggestion(tag: row.tag, matchedAlias: alias.alias)
            }
            .prefix(AppSettingsStore.shared.current.tagSuggestionLimit)
            .map { $0 }
    }

    /// Every term must appear somewhere in the text — case-, diacritic-
    /// AND punctuation-insensitively: "oneil" hits "O'Neil", "acdc" hits
    /// "AC/DC", "motorhead" hits "Motörhead". All-must-match rather than
    /// any: adding a second term is how the operator NARROWS a long
    /// list, so it must never widen one.
    static func matchesAllTerms(_ text: String, terms: [String]) -> Bool {
        let folded = searchFold(text)
        return terms.allSatisfy { folded.contains(searchFold($0)) }
    }

    /// The one fold both sides of every comparison go through — the
    /// contains match above and the exact-equality that pre-selects a
    /// row for Enter. Two folds is how "Tim oneil" ends up matching for
    /// display but creating a duplicate on commit.
    static func searchFold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
    }

    /// A tag named exactly what was typed — through the same fold as the
    /// matching, so "tim oneil" IS "Tim O'Neil" — selected on sight so
    /// Enter applies it instead of offering to create a near-duplicate.
    private var exactMatchIndex: Int? {
        let folded = PillCategoryView.searchFold(query)
        return suggestions.firstIndex {
            PillCategoryView.searchFold($0.tag.name) == folded
                || $0.matchedAlias.map { PillCategoryView.searchFold($0) == folded } == true
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
    /// On an empty field, the FIRST arrow picks a list — ↑ the history,
    /// ↓ the whole category — and every arrow after that walks that list
    /// and only that list, clamped at its ends. Leaving is Esc or typing;
    /// stepping off the top of one list must never open the other.
    private func move(_ delta: Int) -> KeyPress.Result {
        if query.isEmpty, !showingHistory, !browsingAll {
            if delta == -1 {
                showingHistory = true
            } else {
                browsingAll = true
            }
            highlighted = suggestions.isEmpty ? nil : 0
            return .handled
        }
        guard !suggestions.isEmpty else { return .handled }
        // History climbs UPWARD from the box: ↑ moves to older (higher
        // index, drawn higher), ↓ back toward the field.
        let delta = historyActive ? -delta : delta
        let current = highlighted ?? (delta > 0 ? -1 : suggestions.count)
        highlighted = min(max(0, current + delta), suggestions.count - 1)
        return .handled
    }

    @ViewBuilder
    private func suggestionRow(_ index: Int, _ suggestion: Suggestion) -> some View {
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
                .contextMenu {
                    Button("Edit Tag…") { editing = suggestion.tag }
                    Button("Show Items with This Tag") {
                        openTagPlayerWindow(
                            tag: suggestion.tag, library: model.library,
                            libraryID: model.libraryID, openWindow: openWindow)
                    }
                }
    }
    /// Enter: apply what is selected, or create when nothing is. A
    /// history pick applies too — the empty-query guard only blocks
    /// CREATING from nothing.
    private func commit() {
        if let index = activeIndex, suggestions.indices.contains(index) {
            apply(suggestions[index].tag)
            return
        }
        guard !query.isEmpty else { return }
        creating = true
    }

    private func apply(_ tag: Tag) {
        model.toggleTag(tag.id)
        draft = ""
        highlighted = nil
        showingHistory = false
        browsingAll = false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CategoryHeading(category: entry.category, draggable: true)

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
                        .contextMenu {
                            Button("Edit Tag…") { editing = tag }
                            Button("Show Items with This Tag") {
                        openTagPlayerWindow(
                            tag: tag, library: model.library,
                            libraryID: model.libraryID, openWindow: openWindow)
                    }
                        }
                    }
                }
            }

            if historyActive {
                // Reversed so index 0 — the LATEST apply — is the row
                // directly above the box, older ones climbing upward.
                ForEach(Array(suggestions.enumerated()).reversed(), id: \.element.id) { index, suggestion in
                    suggestionRow(index, suggestion)
                }
            }
            HStack(spacing: 6) {
                TextField("Add \(entry.category.name)…", text: $draft)
                    .textFieldStyle(.plain)
                    .font(Theme.ui(12))
                    .focused(focus, equals: entry.id)
                    .onSubmit(commit)
                    // Tab hops to the next category's field, ⇧Tab back —
                    // handled before the field editor eats it, so tagging
                    // a show is type · Enter · Tab · type without the
                    // mouse. Shifted arrows still walk the playlist.
                    .onKeyPress(keys: [.tab]) { press in
                        onAdvance(!press.modifiers.contains(.shift))
                        return .handled
                    }
                    .onChange(of: draft) { _, _ in
                        // A new query invalidates the old highlight, and
                        // typing leaves history mode.
                        highlighted = nil
                        showingHistory = false
                        browsingAll = false
                    }
                    .onChange(of: focus.wrappedValue) { _, now in
                        if now == entry.id { model.zone = .tags }
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

            // Autocomplete below; history above (rendered before the
            // field, newest last so it sits directly on the box).
            if !historyActive {
                ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                    suggestionRow(index, suggestion)
                }
            }
        }
        .task(id: model.item?.id) {
            if takesFocus { focus.wrappedValue = entry.id }
        }
        .onChange(of: model.item?.id) { _, _ in
            // A new video is a fresh judgment — an open history overlay
            // from the last one must not hang over its field.
            showingHistory = false
            browsingAll = false
            highlighted = nil
        }
        .sheet(item: $editing, onDismiss: restoreFieldFocus) { tag in
            TagSheet(
                mode: .edit(tag),
                library: model.library,
                libraryID: model.libraryID,
                categories: model.panelVocabulary.map(\.category)
            ) { _ in model.refreshTagging() }
        }
        .sheet(isPresented: $creating, onDismiss: restoreFieldFocus) {
            TagSheet(
                mode: .create(categoryID: entry.category.id, name: query),
                library: model.library,
                libraryID: model.libraryID,
                categories: model.panelVocabulary.map(\.category)
            ) { tag in
                model.refreshTagging()
                model.toggleTag(tag.id)
                draft = ""
                highlighted = nil
            }
        }
    }
}

/// The landing line: where a dragged row goes when released — drawn
/// ABOVE the hovered block, because dropping inserts before it. An
/// OVERLAY, deliberately: inserting a view into the stack moved the
/// hovered block under a stationary pointer, which un-targeted it,
/// which removed the line, which moved it back — a stutter that also
/// dropped the target from under the release. The overlay adds no
/// height; it sits in the gap above the block.
private struct LandingLine: ViewModifier {
    let shown: Bool

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if shown {
                Capsule()
                    .fill(Theme.Accent.amber)
                    .frame(height: 2.5)
                    .offset(y: -8)
                    .allowsHitTesting(false)
                    .zIndex(1)
            }
        }
    }
}

extension View {
    fileprivate func landingLine(when shown: Bool) -> some View {
        modifier(LandingLine(shown: shown))
    }
}

/// The image under the pointer while a row is dragged: the row's name
/// on a plate, so it reads as the row and not as a stray glyph.
private struct DragPreview: View {
    let name: String

    var body: some View {
        HStack(spacing: 6) {
            Text("≡").font(Theme.ui(12)).foregroundStyle(Theme.Text.disabled)
            Text(name).font(Theme.ui(12, .semibold)).foregroundStyle(Theme.Text.primary)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control)
                .fill(Theme.Surface.raised)
                .stroke(Theme.Accent.amber, lineWidth: 1))
    }
}

// MARK: - The global tag finder

/// The panel's Universal field — `UniversalTagField` bound to the
/// player: its index and applied set, its session history for ↑, its
/// focus walk, and apply-means-toggle-on-the-playing-item. The per-
/// category fields keep their jobs (their suggestions are scoped and
/// their Enter creates INTO that category with no dialog detour); this
/// is the panel-wide complement, same matching rule.
private struct GlobalTagField: View {
    @Environment(PlayerModel.self) private var model
    /// First in the panel order — takes the keyboard when an item loads.
    var takesFocus = false
    /// The panel's shared focus, keyed by the universal sentinel — which
    /// is what puts this field IN the Tab walk with the categories.
    var focus: FocusState<UUID?>.Binding

    var body: some View {
        UniversalTagField(
            index: model.tagSearchIndex,
            appliedIDs: Set(model.itemTags.flatMap(\.tags).map(\.id)),
            recentTagIDs: model.recentlyAppliedTagIDs,
            // What the companion found leads the list — only while a
            // companion is open, since no scan runs otherwise.
            analysisTagIDs: model.analysisSession.flatMap { session in
                session.companionIsOpen
                    ? AnalysisResultsField.candidates(
                        analysis: session.analysis,
                        appliedIDs: Set(model.itemTags.flatMap(\.tags).map(\.id)),
                        categories: model.panelVocabulary.map(\.category), query: "")
                        .map(\.tag.id)
                    : nil
            } ?? [],
            categories: model.panelVocabulary.map(\.category),
            library: model.library,
            libraryID: model.libraryID,
            focus: focus,
            focusID: PlayerModel.universalFieldFocusID,
            itemID: model.item?.id,
            takesFocus: takesFocus,
            onFocus: { model.zone = .tags },
            onApply: { model.toggleTag($0.id) },
            onCreated: { tag in
                model.refreshTagging()
                model.toggleTag(tag.id)
            })
    }
}
