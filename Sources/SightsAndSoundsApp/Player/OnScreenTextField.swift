import AVFoundation
import SwiftUI
import SightsAndSoundsKit

/// The tag panel's row for the text on screen RIGHT NOW: ↓ reads the
/// frame at the playhead through the Kit's recognizer, runs the Tag
/// Analysis existing-tag pass over what it read, and lists two things —
/// the tags the text names, then the raw lines. Enter on a tag applies
/// it; Enter on a line opens the New Tag sheet seeded with it, to clean
/// up and create. Nothing is stored: this is a look, not a sweep.
struct OnScreenTextField: View {
    let fileURL: URL?
    let isAudio: Bool
    let currentSeconds: Double
    /// Tags already on the item — a found tag that is on already is not
    /// offered again.
    let appliedIDs: Set<UUID>
    let categories: [TagCategory]
    let library: LibraryDatabase
    let libraryID: UUID
    var focus: FocusState<UUID?>.Binding
    let focusID: UUID
    var itemID: UUID?
    var onListChange: (Bool) -> Void = { _ in }
    let onApply: (Tag) -> Void
    let onCreated: (Tag) -> Void

    @State private var draft = ""
    /// The arrowed-to row, by what it is, so a list that reshapes under
    /// Enter still acts on the row that was lit.
    @State private var highlighted: Row?
    /// nil until a read has been asked for.
    @State private var read: Read?
    @State private var reading = false
    @State private var readError: String?
    @State private var creating: String?

    struct Read: Equatable {
        var findings: [ExistingTagFinding]
        var lines: [String]
    }

    /// One row of the list: a tag the text names, or a line of the text.
    enum Row: Hashable {
        case tag(Tag, categoryName: String)
        case line(String)

        var label: String {
            switch self {
            case .tag(let tag, _): tag.name
            case .line(let line): line
            }
        }

        var isTag: Bool {
            if case .tag = self { return true }
            return false
        }

        // Identity is the tag, or the line's text.
        static func == (lhs: Row, rhs: Row) -> Bool {
            switch (lhs, rhs) {
            case (.tag(let a, _), .tag(let b, _)): a.id == b.id
            case (.line(let a), .line(let b)): a == b
            default: false
            }
        }

        func hash(into hasher: inout Hasher) {
            switch self {
            case .tag(let tag, _):
                hasher.combine(0)
                hasher.combine(tag.id)
            case .line(let line):
                hasher.combine(1)
                hasher.combine(line)
            }
        }
    }

    /// The list: found tags first (minus the applied), then the lines —
    /// trimmed, empty dropped, duplicates (case-insensitively) dropped
    /// keeping the first, reading order kept — both narrowed so every
    /// space-separated term hits. Pure, so it is tested.
    static func rows(
        findings: [ExistingTagFinding], lines: [String], query: String,
        appliedIDs: Set<UUID> = []
    ) -> [Row] {
        let terms = query.split(separator: " ").map { TagSearchEntry.fold(String($0)) }
        func matches(_ text: String) -> Bool {
            let folded = TagSearchEntry.fold(text)
            return terms.allSatisfy { folded.contains($0) }
        }
        var seenTags = Set<UUID>()
        let tags: [Row] = findings.compactMap { finding in
            guard !appliedIDs.contains(finding.tag.id),
                  seenTags.insert(finding.tag.id).inserted,
                  matches(finding.tag.name) || matches(finding.matchedText)
            else { return nil }
            return .tag(finding.tag, categoryName: finding.categoryName)
        }
        var seenLines = Set<String>()
        let text: [Row] = lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seenLines.insert($0.lowercased()).inserted && matches($0) }
            .map { .line($0) }
        return tags + text
    }

    private var available: Bool { !isAudio && fileURL != nil }
    private var query: String { draft.trimmingCharacters(in: .whitespaces) }
    private var focused: Bool { focus.wrappedValue == focusID }
    private var rows: [Row] {
        guard let read else { return [] }
        return Self.rows(
            findings: read.findings, lines: read.lines, query: query, appliedIDs: appliedIDs)
    }
    private var listOpen: Bool { read != nil || reading || readError != nil }

    /// What Enter acts on: the arrowed-to row if it is still listed,
    /// else the first row of a typed query.
    private var activeRow: Row? {
        highlighted.flatMap { row in rows.contains(row) ? row : nil }
            ?? (query.isEmpty ? nil : rows.first)
    }
    private var highlightedIndex: Int? {
        highlighted.flatMap { row in rows.firstIndex(of: row) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("⌕").font(Theme.ui(12)).foregroundStyle(Theme.Text.quaternary)
                TextField(
                    available ? "On-screen Text — ↓ reads the frame" : "No video frame to read",
                    text: $draft)
                    .textFieldStyle(.plain)
                    .font(Theme.ui(12))
                    .disabled(!available)
                    .focused(focus, equals: focusID)
                    .onSubmit(commit)
                    .onChange(of: draft) { _, _ in highlighted = nil }
                    .onKeyPress(.upArrow) { move(-1) }
                    .onKeyPress(.downArrow) { move(1) }
                    .onKeyPress(.return) {
                        guard activeRow != nil else { return .ignored }
                        commit()
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        guard listOpen else { return .ignored }
                        clear()
                        return .handled
                    }
                if reading {
                    ProgressView().controlSize(.mini)
                        .help("Reading the text on this frame")
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

            if listOpen {
                if reading {
                    note("Reading the frame…")
                } else if let readError {
                    note(readError)
                } else if rows.isEmpty {
                    note("No text on this frame.")
                } else {
                    let tags = rows.filter(\.isTag), lines = rows.filter { !$0.isTag }
                    if !tags.isEmpty {
                        sectionLabel("Tags in the text")
                        ForEach(tags, id: \.self) { rowView($0) }
                    }
                    if !lines.isEmpty {
                        sectionLabel("Text on screen — Enter makes a tag")
                        ForEach(lines, id: \.self) { rowView($0) }
                    }
                }
            }
        }
        .onChange(of: itemID) { _, _ in clear() }
        .onChange(of: listOpen) { _, open in onListChange(open) }
        .sheet(item: Binding(
            get: { creating.map { Seed(text: $0) } },
            set: { creating = $0?.text }
        ), onDismiss: { focus.wrappedValue = focusID }) { seed in
            if let first = categories.first?.id {
                TagSheet(
                    mode: .create(categoryID: first, name: seed.text),
                    library: library, libraryID: libraryID, categories: categories
                ) { tag in
                    onCreated(tag)
                    clear()
                }
            }
        }
    }

    private struct Seed: Identifiable {
        let text: String
        var id: String { text }
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

    private func clear() {
        draft = ""
        highlighted = nil
        read = nil
        readError = nil
        reading = false
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        guard available else { return .ignored }
        if read == nil, !reading, delta == 1 {
            readFrame()
            return .handled
        }
        guard !rows.isEmpty else { return .handled }
        let current = highlightedIndex ?? (delta > 0 ? -1 : rows.count)
        highlighted = rows[min(max(0, current + delta), rows.count - 1)]
        return .handled
    }

    /// The frame at the playhead, read off the main actor, then the
    /// existing-tag pass over the lines it held.
    private func readFrame() {
        guard let fileURL else { return }
        reading = true
        readError = nil
        highlighted = nil
        let seconds = currentSeconds
        let settings = AppSettingsStore.shared.current.ocr
        let library = library
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<Read, Error> in
                do {
                    let lines = try await OcrJob.readLines(
                        fileURL: fileURL, atSeconds: seconds, settings: settings)
                    let findings = try library.existingTags(inLines: lines)
                    return .success(Read(findings: findings, lines: lines))
                } catch {
                    return .failure(error)
                }
            }.value
            switch outcome {
            case .success(let found):
                read = found
                highlighted = rows.first
            case .failure(let error):
                read = Read(findings: [], lines: [])
                readError = "Could not read the frame: \(error)"
            }
            reading = false
        }
    }

    private func rowView(_ row: Row) -> some View {
        let active = row == activeRow
        return Button {
            pick(row)
        } label: {
            HStack(spacing: 6) {
                if case .tag(_, let categoryName) = row {
                    Circle()
                        .fill(categories.first { $0.name == categoryName }
                            .map { Theme.categoryHue($0.colorIndex) } ?? Theme.Text.tertiary)
                        .frame(width: 6, height: 6)
                }
                Text(row.label)
                    .font(Theme.ui(12))
                    .foregroundStyle(Theme.Text.primary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if case .tag(_, let categoryName) = row {
                    Text(categoryName)
                        .font(Theme.ui(10))
                        .foregroundStyle(Theme.Text.tertiary)
                } else {
                    Text("new tag")
                        .font(Theme.mono(9.5))
                        .foregroundStyle(Theme.Accent.amber)
                }
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
        guard let row = activeRow else { return }
        pick(row)
    }

    private func pick(_ row: Row) {
        switch row {
        case .tag(let tag, _):
            onApply(tag)
            // The list stays: the next tag may be wanted too.
            draft = ""
            highlighted = nil
        case .line(let line):
            creating = line
        }
    }
}
