import SwiftUI
import SightsAndSoundsKit

/// The tag panel's row for what the Tag Analysis companion found: the
/// existing tags named in this video's evidence that the video does not
/// yet wear. ↓ on an empty field lists them all; typing narrows; Enter
/// applies through the player, so the panel and the up-arrow history
/// follow on the same call. Dimmed with a hint while no companion is
/// open — no scan runs then, by decision — and a spinner while one is.
struct AnalysisResultsField: View {
    let session: TagAnalysisSession?
    let appliedIDs: Set<UUID>
    let categories: [TagCategory]
    var focus: FocusState<UUID?>.Binding
    let focusID: UUID
    var itemID: UUID?
    let onApply: (Tag) -> Void

    @State private var draft = ""
    @State private var highlighted: Int?
    @State private var browsing = false

    struct Candidate: Identifiable, Equatable {
        let tag: Tag
        let categoryID: UUID
        let categoryName: String
        var id: UUID { tag.id }
    }

    /// One row per found tag, minus the applied, in category order then
    /// name, narrowed so every space-separated term hits the name or
    /// the alias that matched. Pure, so it is tested without a window.
    static func candidates(
        analysis: ItemAnalysis, appliedIDs: Set<UUID>, categories: [TagCategory], query: String
    ) -> [Candidate] {
        let rank = Dictionary(
            uniqueKeysWithValues: categories.enumerated().map { ($1.id, $0) })
        let terms = query.split(separator: " ").map { TagSearchEntry.fold(String($0)) }
        var seen = Set<UUID>()
        var rows: [(Candidate, [String])] = []
        for finding in analysis.existing where !appliedIDs.contains(finding.tag.id) {
            guard seen.insert(finding.tag.id).inserted else { continue }
            rows.append((
                Candidate(
                    tag: finding.tag, categoryID: finding.tag.tagCategoryID,
                    categoryName: finding.categoryName),
                [TagSearchEntry.fold(finding.tag.name), TagSearchEntry.fold(finding.matchedText)]))
        }
        return rows
            .filter { _, folded in
                terms.allSatisfy { term in folded.contains { $0.contains(term) } }
            }
            .map(\.0)
            .sorted {
                (rank[$0.categoryID] ?? Int.max, $0.tag.name)
                    < (rank[$1.categoryID] ?? Int.max, $1.tag.name)
            }
    }

    private var available: Bool { session?.companionIsOpen == true }
    private var query: String { draft.trimmingCharacters(in: .whitespaces) }
    private var focused: Bool { focus.wrappedValue == focusID }
    private var listOpen: Bool { browsing || !query.isEmpty }

    private var rows: [Candidate] {
        guard let session, available else { return [] }
        return Self.candidates(
            analysis: session.analysis, appliedIDs: appliedIDs,
            categories: categories, query: query)
    }

    /// How many the analysis found for this item that are not yet on it
    /// — the whole list, whatever is typed. Shown at the field's edge so
    /// the answer to "anything here?" needs no keystroke.
    private var foundCount: Int {
        guard let session, available else { return 0 }
        return Self.candidates(
            analysis: session.analysis, appliedIDs: appliedIDs,
            categories: categories, query: "").count
    }

    private var exactMatchIndex: Int? {
        let folded = TagSearchEntry.fold(query)
        return rows.firstIndex { TagSearchEntry.fold($0.tag.name) == folded }
    }

    /// Enter acts on the arrowed-to row, else the exact match, else the
    /// first hit of a typed query. Nothing typed and nothing arrowed is
    /// nothing to apply.
    private var activeIndex: Int? {
        highlighted ?? exactMatchIndex ?? (query.isEmpty || rows.isEmpty ? nil : 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("⌕").font(Theme.ui(12)).foregroundStyle(Theme.Text.quaternary)
                TextField(
                    available ? "Tag Analysis Results — ↓ lists them" : "Open Tag Analysis to see results",
                    text: $draft)
                    .textFieldStyle(.plain)
                    .font(Theme.ui(12))
                    .disabled(!available)
                    .focused(focus, equals: focusID)
                    .onSubmit(commit)
                    .onChange(of: draft) { _, _ in
                        highlighted = nil
                        browsing = false
                    }
                    .onKeyPress(.upArrow) { move(-1) }
                    .onKeyPress(.downArrow) { move(1) }
                if session?.isAnalyzing == true {
                    ProgressView().controlSize(.mini)
                        .help("Tag Analysis is scanning this video")
                } else if available {
                    Text("\(foundCount)")
                        .font(Theme.mono(10))
                        .foregroundStyle(foundCount == 0 ? Theme.Text.zeroCount : Theme.Accent.amber)
                        .help(foundCount == 1
                            ? "1 tag found for this video, not yet applied"
                            : "\(foundCount) tags found for this video, not yet applied")
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
            .opacity(available ? 1 : 0.55)

            if listOpen, available {
                if rows.isEmpty {
                    Text(session?.isAnalyzing == true ? "Scanning…" : "Nothing found for this video.")
                        .font(Theme.ui(11))
                        .foregroundStyle(Theme.Text.disabled)
                        .padding(.horizontal, 8)
                } else {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        rowView(index, row)
                    }
                }
            }
        }
        .onChange(of: itemID) { _, _ in
            draft = ""
            highlighted = nil
            browsing = false
        }
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        guard available else { return .ignored }
        if query.isEmpty, !browsing, delta == 1 {
            browsing = true
            highlighted = rows.isEmpty ? nil : 0
            return .handled
        }
        guard !rows.isEmpty else { return .ignored }
        switch (highlighted, delta) {
        case (nil, 1): highlighted = 0
        case (nil, -1): highlighted = rows.count - 1
        case (let current?, _):
            let next = current + delta
            highlighted = rows.indices.contains(next) ? next : nil
        default: break
        }
        return .handled
    }

    private func rowView(_ index: Int, _ row: Candidate) -> some View {
        let active = index == activeIndex
        let hue = categories.first { $0.id == row.categoryID }
            .map { Theme.categoryHue($0.colorIndex) } ?? Theme.Text.tertiary
        return Button {
            apply(row.tag)
        } label: {
            HStack(spacing: 6) {
                Circle().fill(hue).frame(width: 6, height: 6)
                Text(row.tag.name)
                    .font(Theme.ui(12))
                    .foregroundStyle(Theme.Text.primary)
                Spacer(minLength: 6)
                Text(row.categoryName)
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

    private func commit() {
        guard let index = activeIndex, rows.indices.contains(index) else { return }
        apply(rows[index].tag)
    }

    private func apply(_ tag: Tag) {
        onApply(tag)
        draft = ""
        highlighted = nil
        // Stay in browse mode: the list drops the applied tag and the
        // next Enter takes the next one — that is the whole workflow.
        browsing = true
    }
}
