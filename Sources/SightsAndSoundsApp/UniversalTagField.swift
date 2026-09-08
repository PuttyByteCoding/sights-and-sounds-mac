import SwiftUI
import SightsAndSoundsKit

/// One pre-folded row per tag, for the search fields. Folding (case +
/// diacritics + punctuation) is the expensive half of matching, and
/// computing it per keystroke across thousands of tags — several times
/// per render — is what made the Universal field slow. Built once by
/// whichever model owns the vocabulary, filtered cheaply everywhere.
struct TagSearchEntry: Identifiable {
    let tag: Tag
    let categoryID: UUID
    let categoryName: String
    let colorIndex: Int
    let foldedName: String
    let foldedAliases: [(alias: String, folded: String)]
    var id: UUID { tag.id }

    /// The one fold every comparison goes through — names, aliases and
    /// typed terms alike.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
    }

    /// The index for a vocabulary, aliases keyed by tag id.
    static func index(
        vocabulary: [(category: TagCategory, tags: [Tag])], aliases: [UUID: [String]]
    ) -> [TagSearchEntry] {
        vocabulary.flatMap { entry in
            entry.tags.map { tag in
                TagSearchEntry(
                    tag: tag,
                    categoryID: entry.category.id,
                    categoryName: entry.category.name,
                    colorIndex: entry.category.colorIndex,
                    foldedName: fold(tag.name),
                    foldedAliases: (aliases[tag.id] ?? []).map { ($0, fold($0)) })
            }
        }
    }
}

/// One field that searches EVERY category — for when you know the tag
/// but not which category it lives in, or it does not exist yet. Picking
/// a hit hands the tag to `onApply`; Enter with nothing picked opens the
/// New Tag sheet, whose category picker decides where the tag lands, and
/// the created tag goes to `onCreated`.
///
/// Shared by the player's tag panel and the Tag Analysis rail: one
/// matching rule (every space-separated term must hit a name or an
/// alias), one exact-match-selects-itself rule, one sheet. The caller
/// owns the index, the applied set and what "apply" means.
struct UniversalTagField: View {
    let index: [TagSearchEntry]
    /// Tags already on the item — never offered.
    let appliedIDs: Set<UUID>
    /// The session's recent applies, newest first, for ↑ on an empty
    /// query. Empty disables the gesture.
    var recentTagIDs: [UUID] = []
    let categories: [TagCategory]
    let library: LibraryDatabase
    let libraryID: UUID
    /// The caller's focus walk, keyed by `focusID` — which is what puts
    /// the field IN a Tab order beside other fields.
    var focus: FocusState<UUID?>.Binding
    let focusID: UUID
    /// The displayed item: a change resets the field's transient state,
    /// and takes the keyboard when `takesFocus` is set.
    var itemID: UUID?
    var takesFocus = false
    var onFocus: () -> Void = {}
    let onApply: (Tag) -> Void
    let onCreated: (Tag) -> Void

    @State private var draft = ""
    @State private var highlighted: Int?
    @State private var creating = false
    @State private var showingHistory = false

    private var focused: Bool { focus.wrappedValue == focusID }

    private var query: String { draft.trimmingCharacters(in: .whitespaces) }

    private struct Hit: Identifiable {
        let tag: Tag
        let categoryName: String
        let categoryHue: Color
        let matchedAlias: String?
        var id: UUID { tag.id }
    }

    private var historyActive: Bool { showingHistory && query.isEmpty }

    private var hits: [Hit] {
        // Empty query + ↑: the session's recent applies, every category.
        if query.isEmpty {
            guard showingHistory else { return [] }
            return recentTagIDs.compactMap { id in
                guard !appliedIDs.contains(id),
                      let row = index.first(where: { $0.tag.id == id })
                else { return nil }
                return Hit(
                    tag: row.tag, categoryName: row.categoryName,
                    categoryHue: Theme.categoryHue(row.colorIndex),
                    matchedAlias: nil)
            }
        }
        // Folded terms against the pre-folded index, lazily, cut at the
        // limit — never a full pass once enough hits exist.
        let foldedTerms = query.split(separator: " ").map { TagSearchEntry.fold(String($0)) }
        return index
            .lazy
            .compactMap { row -> Hit? in
                guard !appliedIDs.contains(row.tag.id) else { return nil }
                if foldedTerms.allSatisfy({ row.foldedName.contains($0) }) {
                    return Hit(
                        tag: row.tag, categoryName: row.categoryName,
                        categoryHue: Theme.categoryHue(row.colorIndex),
                        matchedAlias: nil)
                }
                guard let alias = row.foldedAliases.first(where: { candidate in
                    foldedTerms.allSatisfy { candidate.folded.contains($0) }
                })
                else { return nil }
                return Hit(
                    tag: row.tag, categoryName: row.categoryName,
                    categoryHue: Theme.categoryHue(row.colorIndex),
                    matchedAlias: alias.alias)
            }
            .prefix(AppSettingsStore.shared.current.tagSuggestionLimit)
            .map { $0 }
    }

    /// A tag named exactly what was typed — through the same fold as the
    /// matching — selected on sight so Enter applies it instead of
    /// offering to create a near-duplicate.
    private var exactMatchIndex: Int? {
        let folded = TagSearchEntry.fold(query)
        return hits.firstIndex {
            TagSearchEntry.fold($0.tag.name) == folded
                || $0.matchedAlias.map { TagSearchEntry.fold($0) == folded } == true
        }
    }

    private var activeIndex: Int? { highlighted ?? exactMatchIndex }
    private var willCreate: Bool { !query.isEmpty && activeIndex == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if historyActive {
                ForEach(Array(hits.enumerated()).reversed(), id: \.element.id) { index, hit in
                    hitRow(index, hit)
                }
            }
            HStack(spacing: 6) {
                Text("⌕").font(Theme.ui(12)).foregroundStyle(Theme.Text.quaternary)
                TextField("Find or create a tag in any category…", text: $draft)
                    .textFieldStyle(.plain)
                    .font(Theme.ui(12))
                    .focused(focus, equals: focusID)
                    .onSubmit(commit)
                    .onChange(of: draft) { _, _ in
                        highlighted = nil
                        showingHistory = false
                    }
                    .onChange(of: focus.wrappedValue) { _, now in
                        if now == focusID { onFocus() }
                    }
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
                        focused ? Theme.Border.activeControl : Theme.Border.standard,
                        lineWidth: 1))

            if !historyActive {
                ForEach(Array(hits.enumerated()), id: \.element.id) { index, hit in
                    hitRow(index, hit)
                }
            }
        }
        .task(id: itemID) {
            if takesFocus { focus.wrappedValue = focusID }
        }
        .onChange(of: itemID) { _, _ in
            showingHistory = false
            highlighted = nil
        }
        .sheet(isPresented: $creating, onDismiss: {
            // The sheet is a detour — the keyboard comes back here.
            focus.wrappedValue = focusID
        }) {
            if let first = categories.first?.id {
                TagSheet(
                    mode: .create(categoryID: first, name: query),
                    library: library,
                    libraryID: libraryID,
                    categories: categories
                ) { tag in
                    onCreated(tag)
                    draft = ""
                    highlighted = nil
                }
            }
        }
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        if query.isEmpty, !showingHistory, delta == -1, !recentTagIDs.isEmpty {
            showingHistory = true
            highlighted = hits.isEmpty ? nil : 0
            return .handled
        }
        let delta = historyActive ? -delta : delta
        guard !hits.isEmpty else { return .ignored }
        switch (highlighted, delta) {
        case (nil, 1): highlighted = 0
        case (nil, -1): highlighted = hits.count - 1
        case (let current?, _):
            let next = current + delta
            highlighted = hits.indices.contains(next) ? next : nil
        default: break
        }
        return .handled
    }

    @ViewBuilder
    private func hitRow(_ index: Int, _ hit: Hit) -> some View {
        let active = index == activeIndex
        Button {
            apply(hit.tag)
        } label: {
            HStack(spacing: 6) {
                Circle().fill(hit.categoryHue).frame(width: 6, height: 6)
                Text(hit.tag.name)
                    .font(Theme.ui(12))
                    .foregroundStyle(Theme.Text.primary)
                if let alias = hit.matchedAlias {
                    Text("(\(alias))")
                        .font(Theme.ui(11))
                        .foregroundStyle(Theme.Text.quaternary)
                }
                Spacer(minLength: 6)
                Text(hit.categoryName)
                    .font(Theme.ui(10))
                    .foregroundStyle(Theme.Text.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.chip)
                    .fill(active ? Theme.Surface.selectedRow : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Enter: apply what is selected, or create when nothing is.
    private func commit() {
        if let index = activeIndex, hits.indices.contains(index) {
            apply(hits[index].tag)
            return
        }
        guard !query.isEmpty else { return }
        creating = true
    }

    private func apply(_ tag: Tag) {
        onApply(tag)
        draft = ""
        highlighted = nil
        showingHistory = false
    }
}
