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

/// The frame the Universal field can read on ⇧↓: the playing file and
/// the playhead. nil for audio or an offline file.
struct ScreenFrame: Equatable {
    let fileURL: URL
    let seconds: Double
}

/// One field that searches EVERY category — for when you know the tag
/// but not which category it lives in, or it does not exist yet. Picking
/// a hit hands the tag to `onApply`; Enter with nothing picked opens the
/// New Tag sheet, whose category picker decides where the tag lands, and
/// the created tag goes to `onCreated`.
///
/// Three lists live on the arrows of an empty field. ↑: the session's
/// recent applies. ↓: what the Tag Analysis companion found. ⇧↓: the
/// text on screen RIGHT NOW — the frame at the playhead read by Vision,
/// the Tag Analysis existing-tag pass run over it, the tags it names
/// listed first and the raw lines under them; Enter on a tag applies it,
/// Enter on a line opens New Tag seeded with it to clean up and create.
/// Typing searches the whole vocabulary with the analysis's matches
/// first. Esc closes whichever list is up and leaves the field empty.
struct UniversalTagField: View {
    let index: [TagSearchEntry]
    /// Tags already on the item — never offered.
    let appliedIDs: Set<UUID>
    /// The session's recent applies, newest first, for ↑ on an empty
    /// query. Empty disables the gesture.
    var recentTagIDs: [UUID] = []
    /// What the Tag Analysis companion found for this item, in its
    /// order — the ↓ list, and ranked first while typing. Empty when no
    /// companion is open.
    var analysisTagIDs: [UUID] = []
    /// What ⇧↓ reads. nil disables the gesture (audio, offline).
    var screenFrame: ScreenFrame?
    /// A bump asks for a screen read as if ⇧↓ were pressed — numpad 2.
    var screenReadRequests = 0
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
    /// The list opened or closed — history, analysis, screen, or a typed
    /// query. The player uses it to let Esc close the list instead of
    /// leaving.
    var onListChange: (Bool) -> Void = { _ in }
    let onApply: (Tag) -> Void
    let onCreated: (Tag) -> Void

    @State private var draft = ""
    /// The arrowed-to row, by what it IS rather than by position: the
    /// list can reshape between a draw and the Enter that acts on it, and
    /// a position would then name a different row from the one lit.
    @State private var highlighted: RowID?
    /// The New Tag sheet's seed: the typed query, or a screen line.
    @State private var creating: String?
    @State private var showingHistory = false
    /// Empty query + ↓: what Tag Analysis found.
    @State private var browsingAll = false
    /// Empty query + ⇧↓: what is on screen, once read.
    @State private var screen: ScreenRead?
    @State private var readingScreen = false
    @State private var screenError: String?

    private var focused: Bool { focus.wrappedValue == focusID }
    private var query: String { draft.trimmingCharacters(in: .whitespaces) }

    enum RowID: Hashable {
        case tag(UUID)
        case line(String)
    }

    struct ScreenRead: Equatable {
        var findings: [ExistingTagFinding]
        var lines: [String]
    }

    struct Hit: Identifiable {
        let tag: Tag
        let categoryName: String
        let categoryHue: Color
        let matchedAlias: String?
        var fromAnalysis = false
        var fromScreen = false
        var id: UUID { tag.id }
    }

    /// Analysis rows first, then the rest with those tags dropped, the
    /// whole list capped. Pure, so it is tested.
    static func merged(analysis: [Hit], rest: [Hit], limit: Int) -> [Hit] {
        let leading = Array(analysis.prefix(limit))
        let seen = Set(leading.map(\.id))
        return leading + rest.lazy.filter { !seen.contains($0.id) }.prefix(max(0, limit - leading.count))
    }

    /// The screen read as rows: the tags the text names (minus the
    /// applied, once each), then the lines — trimmed, empty dropped,
    /// duplicates (case-insensitively) dropped keeping the first,
    /// reading order kept — both narrowed so every space-separated term
    /// hits. Pure, so it is tested.
    static func screenRows(
        findings: [ExistingTagFinding], lines: [String], query: String,
        appliedIDs: Set<UUID> = []
    ) -> (tags: [ExistingTagFinding], lines: [String]) {
        let terms = query.split(separator: " ").map { TagSearchEntry.fold(String($0)) }
        func matches(_ text: String) -> Bool {
            let folded = TagSearchEntry.fold(text)
            return terms.allSatisfy { folded.contains($0) }
        }
        var seenTags = Set<UUID>()
        let tags = findings.filter { finding in
            !appliedIDs.contains(finding.tag.id)
                && seenTags.insert(finding.tag.id).inserted
                && (matches(finding.tag.name) || matches(finding.matchedText))
        }
        var seenLines = Set<String>()
        let text = lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seenLines.insert($0.lowercased()).inserted && matches($0) }
        return (tags, text)
    }

    private func hit(_ row: TagSearchEntry, alias: String? = nil, fromAnalysis: Bool = false) -> Hit {
        Hit(
            tag: row.tag, categoryName: row.categoryName,
            categoryHue: Theme.categoryHue(row.colorIndex),
            matchedAlias: alias, fromAnalysis: fromAnalysis)
    }

    private var entriesByID: [UUID: TagSearchEntry] {
        Dictionary(uniqueKeysWithValues: index.map { ($0.tag.id, $0) })
    }

    /// The analysis's tags as rows, in its order, minus the applied.
    private var analysisHits: [Hit] {
        guard !analysisTagIDs.isEmpty else { return [] }
        let byID = entriesByID
        return analysisTagIDs.compactMap { id in
            guard !appliedIDs.contains(id), let row = byID[id] else { return nil }
            return hit(row, fromAnalysis: true)
        }
    }

    private var historyActive: Bool { showingHistory && query.isEmpty }
    private var screenActive: Bool { screen != nil || readingScreen || screenError != nil }
    private var listOpen: Bool { showingHistory || browsingAll || screenActive || !query.isEmpty }

    /// The screen read under the query: tag rows and line rows.
    private var screenParts: (tags: [Hit], lines: [String]) {
        guard let screen else { return ([], []) }
        let rows = Self.screenRows(
            findings: screen.findings, lines: screen.lines, query: query, appliedIDs: appliedIDs)
        let byID = entriesByID
        let tags = rows.tags.compactMap { finding -> Hit? in
            guard let row = byID[finding.tag.id] else { return nil }
            var made = hit(row)
            made.fromScreen = true
            return made
        }
        return (tags, rows.lines)
    }

    private var screenLines: [String] { screenActive ? screenParts.lines : [] }

    /// Esc: back to an empty, focused field — whichever list was up.
    private func closeList() {
        draft = ""
        showingHistory = false
        browsingAll = false
        screen = nil
        screenError = nil
        readingScreen = false
        highlighted = nil
    }

    private var hits: [Hit] {
        let limit = AppSettingsStore.shared.current.tagSuggestionLimit
        if screenActive {
            return Array(screenParts.tags.prefix(limit))
        }
        // Empty query + ↑: the session's recent applies, every category.
        if query.isEmpty {
            if showingHistory {
                return recentTagIDs.compactMap { id in
                    guard !appliedIDs.contains(id),
                          let row = index.first(where: { $0.tag.id == id })
                    else { return nil }
                    return hit(row)
                }
            }
            // ↓ lists what Tag Analysis found, and only that: the
            // vocabulary is for typing into. Nothing found says so.
            guard browsingAll else { return [] }
            return Array(analysisHits.prefix(limit))
        }
        // Folded terms against the pre-folded index, lazily, cut at the
        // limit — never a full pass once enough hits exist.
        let foldedTerms = query.split(separator: " ").map { TagSearchEntry.fold(String($0)) }
        func match(_ row: TagSearchEntry, fromAnalysis: Bool) -> Hit? {
            if foldedTerms.allSatisfy({ row.foldedName.contains($0) }) {
                return hit(row, fromAnalysis: fromAnalysis)
            }
            guard let alias = row.foldedAliases.first(where: { candidate in
                foldedTerms.allSatisfy { candidate.folded.contains($0) }
            })
            else { return nil }
            return hit(row, alias: alias.alias, fromAnalysis: fromAnalysis)
        }
        // The analysis's matches lead — the tags the evidence names are
        // the likeliest answer to whatever is being typed.
        let byID = entriesByID
        let leading = analysisTagIDs.compactMap { id -> Hit? in
            guard !appliedIDs.contains(id), let row = byID[id] else { return nil }
            return match(row, fromAnalysis: true)
        }
        let rest = index
            .lazy
            .compactMap { row -> Hit? in
                guard !appliedIDs.contains(row.tag.id) else { return nil }
                return match(row, fromAnalysis: false)
            }
            .prefix(limit)
        return Self.merged(analysis: leading, rest: Array(rest), limit: limit)
    }

    /// Every row in walk order: tags, then screen lines.
    private var rowIDs: [RowID] {
        hits.map { .tag($0.id) } + screenLines.map { .line($0) }
    }

    /// A tag named exactly what was typed — through the same fold as the
    /// matching — selected on sight so Enter applies it instead of
    /// offering to create a near-duplicate.
    private var exactMatch: Hit? {
        let folded = TagSearchEntry.fold(query)
        return hits.first {
            TagSearchEntry.fold($0.tag.name) == folded
                || $0.matchedAlias.map { TagSearchEntry.fold($0) == folded } == true
        }
    }

    /// What Enter acts on: the arrowed-to row if it is still listed,
    /// else the exact match.
    private var activeRow: RowID? {
        if let highlighted, rowIDs.contains(highlighted) { return highlighted }
        return exactMatch.map { .tag($0.id) }
    }
    private var highlightedIndex: Int? {
        highlighted.flatMap { row in rowIDs.firstIndex(of: row) }
    }
    private var willCreate: Bool { !query.isEmpty && activeRow == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if historyActive {
                ForEach(Array(hits.enumerated()).reversed(), id: \.element.id) { _, hit in
                    hitRow(hit)
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
                        browsingAll = false
                    }
                    .onChange(of: focus.wrappedValue) { _, now in
                        if now == focusID { onFocus() }
                    }
                    .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                        if press.key == .downArrow, press.modifiers.contains(.shift) {
                            return readScreen()
                        }
                        return move(press.key == .downArrow ? 1 : -1)
                    }
                    .onKeyPress(.escape) {
                        guard listOpen else { return .ignored }
                        closeList()
                        return .handled
                    }
                    // Return beside the arrows, not only as the field's
                    // submit: after an arrow the AppKit field editor can be
                    // out of editing, and the first Return then only woke
                    // it — Enter had to be pressed twice. Nothing to act on
                    // falls through to the submit path (create).
                    .onKeyPress(.return) {
                        guard activeRow != nil else { return .ignored }
                        commit()
                        return .handled
                    }
                if readingScreen {
                    ProgressView().controlSize(.mini)
                        .help("Reading the text on this frame")
                } else if willCreate {
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
                if screenActive {
                    screenList
                } else {
                    if browsingAll, query.isEmpty, hits.isEmpty {
                        note("No Tags from Tag Analysis")
                    }
                    ForEach(hits) { hitRow($0) }
                }
            }
        }
        .task(id: itemID) {
            if takesFocus { focus.wrappedValue = focusID }
        }
        .onChange(of: listOpen) { _, open in onListChange(open) }
        .onChange(of: itemID) { _, _ in closeList() }
        .onChange(of: screenReadRequests) { _, _ in _ = readScreen() }
        .sheet(item: Binding(
            get: { creating.map { Seed(text: $0) } },
            set: { creating = $0?.text }
        ), onDismiss: {
            // The sheet is a detour — the keyboard comes back here.
            focus.wrappedValue = focusID
        }) { seed in
            if let first = categories.first?.id {
                TagSheet(
                    mode: .create(categoryID: first, name: seed.text),
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

    private struct Seed: Identifiable {
        let text: String
        var id: String { text }
    }

    @ViewBuilder
    private var screenList: some View {
        if readingScreen {
            note("Reading the frame…")
        } else if let screenError {
            note(screenError)
        } else if hits.isEmpty, screenLines.isEmpty {
            note("No text on this frame.")
        } else {
            if !hits.isEmpty {
                sectionLabel("Tags in the text")
                ForEach(hits) { hitRow($0) }
            }
            if !screenLines.isEmpty {
                sectionLabel("Text on screen — Enter makes a tag")
                ForEach(screenLines, id: \.self) { lineRow($0) }
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Theme.ui(11))
            .foregroundStyle(Theme.Text.disabled)
            .padding(.horizontal, 8)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(Theme.ui(9.5, .semibold))
            .foregroundStyle(Theme.Text.quaternary)
            .padding(.horizontal, 8)
            .padding(.top, 2)
    }

    /// On an empty field, the FIRST arrow picks a list — ↑ the history,
    /// ↓ the analysis — and every arrow after that walks the list that
    /// is up and only that list, clamped at its ends. Leaving is Esc or
    /// typing; stepping off the top of one list must never open another.
    private func move(_ delta: Int) -> KeyPress.Result {
        if query.isEmpty, !showingHistory, !browsingAll, !screenActive {
            if delta == -1, !recentTagIDs.isEmpty {
                showingHistory = true
            } else if delta == 1 {
                browsingAll = true
            } else {
                return .ignored
            }
            highlighted = rowIDs.first
            return .handled
        }
        let rows = rowIDs
        guard !rows.isEmpty else { return .handled }
        // History climbs UPWARD from the box: ↑ moves to older (higher
        // index, drawn higher), ↓ back toward the field.
        let delta = historyActive ? -delta : delta
        let current = highlightedIndex ?? (delta > 0 ? -1 : rows.count)
        highlighted = rows[min(max(0, current + delta), rows.count - 1)]
        return .handled
    }

    /// ⇧↓ (and numpad 2): the frame at the playhead, read off the main
    /// actor, then the existing-tag pass over the lines it held. The
    /// other lists close; this one replaces them.
    private func readScreen() -> KeyPress.Result {
        guard let screenFrame, !readingScreen else { return .handled }
        draft = ""
        showingHistory = false
        browsingAll = false
        highlighted = nil
        screen = nil
        screenError = nil
        readingScreen = true
        let settings = AppSettingsStore.shared.current.ocr
        let library = library
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<ScreenRead, Error> in
                do {
                    let lines = try await OcrJob.readLines(
                        fileURL: screenFrame.fileURL, atSeconds: screenFrame.seconds, settings: settings)
                    let findings = try library.existingTags(inLines: lines)
                    return .success(ScreenRead(findings: findings, lines: lines))
                } catch {
                    return .failure(error)
                }
            }.value
            switch outcome {
            case .success(let read):
                screen = read
                highlighted = rowIDs.first
            case .failure(let error):
                screen = ScreenRead(findings: [], lines: [])
                screenError = "Could not read the frame: \(error)"
            }
            readingScreen = false
        }
        return .handled
    }

    private func hitRow(_ hit: Hit) -> some View {
        let active = activeRow == .tag(hit.id)
        return Button {
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
                if hit.fromAnalysis {
                    Text("analysis")
                        .font(Theme.mono(9))
                        .foregroundStyle(Theme.Accent.amber)
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

    private func lineRow(_ line: String) -> some View {
        let active = activeRow == .line(line)
        return Button {
            creating = line
        } label: {
            HStack(spacing: 6) {
                Text(line)
                    .font(Theme.ui(12))
                    .foregroundStyle(Theme.Text.primary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text("new tag")
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.Accent.amber)
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

    /// Enter: apply the active tag, make a tag of the active line, or
    /// create from what was typed.
    private func commit() {
        switch activeRow {
        case .tag(let id):
            if let hit = hits.first(where: { $0.id == id }) { apply(hit.tag) }
        case .line(let line):
            creating = line
        case nil:
            guard !query.isEmpty else { return }
            creating = query
        }
    }

    private func apply(_ tag: Tag) {
        onApply(tag)
        draft = ""
        highlighted = nil
        showingHistory = false
        browsingAll = false
        // A screen read stays: the next line may name a tag too.
    }
}
