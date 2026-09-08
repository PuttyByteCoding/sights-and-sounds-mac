import AVFoundation
import SwiftUI
import SightsAndSoundsKit

/// The tag panel's row for the text on screen RIGHT NOW: ↓ reads the
/// frame at the playhead through the same Vision recognizer the OCR
/// sweep uses, lists the lines, and Enter turns the picked line into a
/// tag — an existing tag whose name or alias folds equal applies at
/// once; anything else opens the New Tag sheet seeded with the line.
/// Nothing is stored: this is a look, not a sweep. Kept separate from
/// the Tag Analysis Results field on purpose while their combination
/// is decided.
struct OnScreenTextField: View {
    let fileURL: URL?
    let isAudio: Bool
    let currentSeconds: Double
    let index: [TagSearchEntry]
    let categories: [TagCategory]
    let library: LibraryDatabase
    let libraryID: UUID
    var focus: FocusState<UUID?>.Binding
    let focusID: UUID
    var itemID: UUID?
    let onApply: (Tag) -> Void
    let onCreated: (Tag) -> Void

    @State private var draft = ""
    /// The arrowed-to line, by its text, so a list that reshapes under
    /// Enter still picks the line that was lit.
    @State private var highlightedLine: String?
    /// nil until a read has been asked for; the read's lines after.
    @State private var lines: [String]?
    @State private var reading = false
    @State private var readError: String?
    @State private var creating: String?

    /// Trimmed, empty dropped, duplicates (case-insensitively) dropped
    /// keeping the first, reading order kept, narrowed so every
    /// space-separated term hits. Pure, so it is tested.
    static func rows(lines: [String], query: String) -> [String] {
        let terms = query.split(separator: " ").map { TagSearchEntry.fold(String($0)) }
        var seen = Set<String>()
        return lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            .filter { line in
                let folded = TagSearchEntry.fold(line)
                return terms.allSatisfy { folded.contains($0) }
            }
    }

    /// The tag a line IS, through the one fold: a name or an alias that
    /// folds equal. Nil means Enter creates.
    static func resolve(_ line: String, in index: [TagSearchEntry]) -> Tag? {
        let folded = TagSearchEntry.fold(line.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !folded.isEmpty else { return nil }
        return index.first {
            $0.foldedName == folded || $0.foldedAliases.contains { $0.folded == folded }
        }?.tag
    }

    private var available: Bool { !isAudio && fileURL != nil }
    private var query: String { draft.trimmingCharacters(in: .whitespaces) }
    private var focused: Bool { focus.wrappedValue == focusID }
    private var rows: [String] { Self.rows(lines: lines ?? [], query: query) }
    private var listOpen: Bool { lines != nil || reading || readError != nil }

    private var exactMatch: String? {
        let folded = TagSearchEntry.fold(query)
        return rows.first { TagSearchEntry.fold($0) == folded }
    }

    private var activeLine: String? {
        highlightedLine.flatMap { line in rows.first { $0 == line } }
            ?? exactMatch
            ?? (query.isEmpty ? nil : rows.first)
    }
    private var highlightedIndex: Int? {
        highlightedLine.flatMap { line in rows.firstIndex { $0 == line } }
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
                    .onChange(of: draft) { _, _ in highlightedLine = nil }
                    .onKeyPress(.upArrow) { move(-1) }
                    .onKeyPress(.downArrow) { move(1) }
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
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, line in
                        rowView(index, line)
                    }
                }
            }
        }
        .onChange(of: itemID) { _, _ in clear() }
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

    private func clear() {
        draft = ""
        highlightedLine = nil
        lines = nil
        readError = nil
        reading = false
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        guard available else { return .ignored }
        if lines == nil, !reading, delta == 1 {
            read()
            return .handled
        }
        guard !rows.isEmpty else { return .handled }
        let current = highlightedIndex ?? (delta > 0 ? -1 : rows.count)
        highlightedLine = rows[min(max(0, current + delta), rows.count - 1)]
        return .handled
    }

    /// The frame at the playhead, read off the main actor. A tight seek:
    /// the timestamp IS the content, and a frame a second off is a frame
    /// the text is not on.
    private func read() {
        guard let fileURL else { return }
        reading = true
        readError = nil
        highlightedLine = nil
        let seconds = currentSeconds
        let settings = AppSettingsStore.shared.current.ocr
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<[String], Error> in
                do {
                    return .success(try await OcrJob.readLines(
                        fileURL: fileURL, atSeconds: seconds, settings: settings))
                } catch {
                    return .failure(error)
                }
            }.value
            switch outcome {
            case .success(let found):
                lines = found
                highlightedLine = rows.first
            case .failure(let error):
                lines = []
                readError = "Could not read the frame: \(error)"
            }
            reading = false
        }
    }

    private func rowView(_ index: Int, _ line: String) -> some View {
        let active = line == activeLine
        let known = Self.resolve(line, in: self.index)
        return Button {
            pick(line)
        } label: {
            HStack(spacing: 6) {
                Text(line)
                    .font(Theme.ui(12))
                    .foregroundStyle(Theme.Text.primary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(known.map { _ in "apply" } ?? "new tag")
                    .font(Theme.mono(9.5))
                    .foregroundStyle(known == nil ? Theme.Accent.amber : Theme.Text.tertiary)
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
        guard let line = activeLine else { return }
        pick(line)
    }

    private func pick(_ line: String) {
        if let tag = Self.resolve(line, in: index) {
            onApply(tag)
            // The list stays: the next line may be a tag too.
            draft = ""
            highlightedLine = nil
        } else {
            creating = line
        }
    }
}
