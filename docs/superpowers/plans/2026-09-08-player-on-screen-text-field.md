# Player "On-screen Text" Field Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A reorderable "On-screen Text" field in the player's tag panel: ↓ reads the text on the current frame, lists the lines, and Enter applies a matching tag or creates one from the line.

**Architecture:** A new `OnScreenTextField` view grabs the frame at the playhead through the Kit's Vision recognizer (`OcrJob.recognizeText`, made public), off the main actor, with a spinner while it runs. Its row list and its tag resolution are pure, tested functions. The panel's pseudo-field mechanism (from the results-field PR) gains a third sentinel and position; `tagFieldOrder` becomes a general insertion so three fields at any positions order correctly.

**Tech Stack:** Swift 6, SwiftUI, AVFoundation, Vision (via the Kit), Swift Testing. macOS 15+.

**Spec:** `docs/superpowers/specs/2026-09-08-tag-analysis-companion-design.md` §"The player: On-screen Text field" (delivery item 4). Branch `feature/player-on-screen-text-field`, stacked on `feature/player-analysis-results-field` (it reuses the Tab-order function and the panel placement that PR introduced; the spec's "off dev" is superseded by that reuse).

## Global Constraints

- Worktree only; zero-warning build; full `swift test`; both guard scripts; a bundle launch before pushing.
- Copy verbatim: heading "On-screen Text"; placeholders "On-screen Text — ↓ reads the frame" (available) and "No video frame to read" (unavailable); list text "Reading the frame…", "No text on this frame."
- Nothing is stored: the read is a look, not a sweep.
- Tests never write `AppSettingsStore.shared`.

---

### Task 1: Position setting and the recognizer made public

**Files:**
- Modify: `Sources/SightsAndSoundsKit/Settings/AppSettings.swift` (beside `analysisResultsFieldPosition`)
- Modify: `Sources/SightsAndSoundsKit/Operations/OcrJob.swift` (`static func recognizeText` ~line 166: add `public`)
- Test: `Tests/SightsAndSoundsKitTests/SettingsTests.swift` (append)

- [ ] **Step 1: Failing tests** — append:

```swift
/// The On-screen Text field's place among the tag panel's categories —
/// the same rule as the other two pseudo-fields, one slot later.
@Suite struct OnScreenTextFieldPositionTests {
    @Test func theDefaultSitsAfterTheResultsField() {
        #expect(AppSettings().onScreenTextFieldPosition == 2)
    }

    @Test func aSettingsFileWrittenBeforeThisSettingStillLoads() throws {
        let decoded = try JSONDecoder().decode(
            AppSettings.self, from: Data(#"{"loopVideos": false}"#.utf8))
        #expect(decoded.onScreenTextFieldPosition == 2)
    }

    @Test func aNegativeValueIsClampedToFirst() throws {
        let decoded = try JSONDecoder().decode(
            AppSettings.self, from: Data(#"{"onScreenTextFieldPosition": -1}"#.utf8))
        #expect(decoded.onScreenTextFieldPosition == 0)
    }
}
```

- [ ] **Step 2: Run** `swift build --build-tests 2>&1 | grep error: | head -1` — missing member.

- [ ] **Step 3: Implement.** After `public var analysisResultsFieldPosition: Int`:
```swift
    /// Where the tag panel's On-screen Text field sits among the
    /// categories — the same rule as the other two pseudo-fields.
    public var onScreenTextFieldPosition: Int
```
Init parameter `onScreenTextFieldPosition: Int = 2` after `analysisResultsFieldPosition: Int = 1`, the assignment, and the decode:
```swift
        onScreenTextFieldPosition = max(0, try container.decodeIfPresent(
            Int.self, forKey: .onScreenTextFieldPosition)
            ?? defaults.onScreenTextFieldPosition)
```
In `OcrJob.swift`, change `    static func recognizeText(` to `    public static func recognizeText(`.

- [ ] **Step 4: Run** `swift test --filter OnScreenTextFieldPositionTests` — 3 pass.
- [ ] **Step 5: Commit** `Settings: a position for the On-screen Text field; the recognizer goes public`.

---

### Task 2: A third sentinel and a general Tab order

**Files:**
- Modify: `Sources/SightsAndSoundsApp/Player/PlayerModel.swift` (`analysisResultsFieldFocusID`, `tagFieldOrder`, `advanceTagField`)
- Modify: `Tests/SightsAndSoundsAppTests/TagFieldOrderTests.swift`

**Interfaces:**
- Produces: `PlayerModel.onScreenTextFieldFocusID`; `tagFieldOrder(searchCategoryIDs:universalPosition:resultsPosition:onScreenPosition:) -> [UUID]`.

- [ ] **Step 1: Rewrite the tests** (replace the file):

```swift
import Foundation
import Testing

@testable import SightsAndSoundsApp

/// The tag panel's Tab walk: the search categories in panel order, with
/// the Universal, Tag Analysis Results and On-screen Text fields
/// inserted at their positions. Ties keep that declared order.
@Suite @MainActor struct TagFieldOrderTests {
    private let a = UUID(), b = UUID(), c = UUID()
    private let universal = PlayerModel.universalFieldFocusID
    private let results = PlayerModel.analysisResultsFieldFocusID
    private let onScreen = PlayerModel.onScreenTextFieldFocusID

    private func order(_ ids: [UUID], _ u: Int, _ r: Int, _ o: Int) -> [UUID] {
        PlayerModel.tagFieldOrder(
            searchCategoryIDs: ids, universalPosition: u, resultsPosition: r, onScreenPosition: o)
    }

    @Test func defaultsPutTheThreeFieldsFirstThenTheCategories() {
        #expect(order([a, b, c], 0, 1, 2) == [universal, a, results, b, onScreen, c])
    }

    @Test func aThreeWayTieKeepsTheDeclaredOrder() {
        #expect(order([a, b], 1, 1, 1) == [a, universal, results, onScreen, b])
    }

    @Test func anyPermutationLandsWhereItsPositionSays() {
        #expect(order([a, b], 2, 0, 1) == [results, a, onScreen, b, universal])
    }

    @Test func positionsPastTheEndMeanLast() {
        #expect(order([a], 9, 9, 9) == [a, universal, results, onScreen])
    }

    @Test func noCategoriesStillWalksTheThreeFields() {
        #expect(order([], 0, 1, 2) == [universal, results, onScreen])
    }
}
```

- [ ] **Step 2: Run** the build — missing `onScreenTextFieldFocusID` / parameter.

- [ ] **Step 3: Implement.** After `analysisResultsFieldFocusID`:
```swift
    /// The On-screen Text field's slot in the focus walk.
    static let onScreenTextFieldFocusID = UUID(
        uuidString: "33333333-3333-3333-3333-333333333333")!
```
Replace `tagFieldOrder` entirely:
```swift
    /// The panel's Tab order: the search categories in panel order with
    /// the pseudo-fields inserted at their positions. Positions are
    /// indexes into the category list; past the end means last. Fields
    /// sorted by position (ties in declared order: Universal, Results,
    /// On-screen) and inserted in that order, each shifted by how many
    /// went in before it — so every field lands where its position says
    /// relative to the categories, whatever the others chose.
    static func tagFieldOrder(
        searchCategoryIDs: [UUID], universalPosition: Int, resultsPosition: Int,
        onScreenPosition: Int
    ) -> [UUID] {
        var fields = searchCategoryIDs
        let count = fields.count
        let pseudo: [(id: UUID, position: Int)] = [
            (universalFieldFocusID, min(max(0, universalPosition), count)),
            (analysisResultsFieldFocusID, min(max(0, resultsPosition), count)),
            (onScreenTextFieldFocusID, min(max(0, onScreenPosition), count)),
        ]
        let ordered = pseudo.enumerated().sorted {
            ($0.element.position, $0.offset) < ($1.element.position, $1.offset)
        }
        for (inserted, entry) in ordered.enumerated() {
            fields.insert(entry.element.id, at: entry.element.position + inserted)
        }
        return fields
    }
```
In `advanceTagField`, add `onScreenPosition: settings.onScreenTextFieldPosition` to the call.

- [ ] **Step 4: Run** `swift test --filter TagFieldOrderTests` — 5 pass.
- [ ] **Step 5: Commit** `Player: the Tab walk orders three pseudo-fields`.

---

### Task 3: The field, its rows and its resolution

**Files:**
- Create: `Sources/SightsAndSoundsApp/Player/OnScreenTextField.swift`
- Test: `Tests/SightsAndSoundsAppTests/OnScreenTextFieldTests.swift`

**Interfaces:**
- Consumes: `OcrJob.recognizeText(generator:at:settings:)`, `TagSearchEntry`, `TagSheet`, `Theme`.
- Produces:
  ```swift
  struct OnScreenTextField: View {
      static func rows(lines: [String], query: String) -> [String]
      static func resolve(_ line: String, in index: [TagSearchEntry]) -> Tag?
      init(fileURL: URL?, isAudio: Bool, currentSeconds: Double, index: [TagSearchEntry], categories: [TagCategory], library: LibraryDatabase, libraryID: UUID, focus: FocusState<UUID?>.Binding, focusID: UUID, itemID: UUID?, onApply: @escaping (Tag) -> Void, onCreated: @escaping (Tag) -> Void)
  }
  ```

- [ ] **Step 1: Failing tests**

```swift
// Tests/SightsAndSoundsAppTests/OnScreenTextFieldTests.swift
import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// What the On-screen Text field lists and what Enter resolves to.
@Suite @MainActor struct OnScreenTextFieldTests {
    @Test func linesAreTrimmedDedupedAndKeptInReadingOrder() {
        let rows = OnScreenTextField.rows(
            lines: ["  Phish  ", "Live at", "phish", "", "Live at", "Red Rocks"], query: "")
        #expect(rows == ["Phish", "Live at", "Red Rocks"])
    }

    @Test func termsNarrowTheLines() {
        let lines = ["Phish", "Live at Red Rocks", "AUD source"]
        #expect(OnScreenTextField.rows(lines: lines, query: "red rock") == ["Live at Red Rocks"])
        #expect(OnScreenTextField.rows(lines: lines, query: "zzz").isEmpty)
    }

    @Test func aLineResolvesToATagByNameOrAliasThroughTheFold() {
        let band = TagCategory(name: "Band")
        let phish = SightsAndSoundsKit.Tag(tagCategoryID: band.id, name: "Phish")
        let sbd = SightsAndSoundsKit.Tag(tagCategoryID: band.id, name: "Soundboard")
        let index = TagSearchEntry.index(
            vocabulary: [(band, [phish, sbd])], aliases: [sbd.id: ["SBD"]])
        #expect(OnScreenTextField.resolve("PHISH", in: index)?.id == phish.id)
        #expect(OnScreenTextField.resolve("sbd", in: index)?.id == sbd.id)
        #expect(OnScreenTextField.resolve("Phishy", in: index) == nil)
    }
}
```

- [ ] **Step 2: Run** the build — `cannot find 'OnScreenTextField'`.

- [ ] **Step 3: Create the field**

```swift
// Sources/SightsAndSoundsApp/Player/OnScreenTextField.swift
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
    @State private var highlighted: Int?
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

    private var exactMatchIndex: Int? {
        let folded = TagSearchEntry.fold(query)
        return rows.firstIndex { TagSearchEntry.fold($0) == folded }
    }

    private var activeIndex: Int? {
        highlighted ?? exactMatchIndex ?? (query.isEmpty || rows.isEmpty ? nil : 0)
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
        highlighted = nil
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

    /// The frame at the playhead, read off the main actor. A tight seek:
    /// the timestamp IS the content, and a frame a second off is a frame
    /// the text is not on.
    private func read() {
        guard let fileURL else { return }
        reading = true
        readError = nil
        highlighted = nil
        let seconds = currentSeconds
        let settings = AppSettingsStore.shared.current.ocr
        Task {
            let text = await Task.detached(priority: .userInitiated) { () -> String? in
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: fileURL))
                generator.appliesPreferredTrackTransform = true
                generator.requestedTimeToleranceBefore = .zero
                generator.requestedTimeToleranceAfter = .zero
                return await OcrJob.recognizeText(
                    generator: generator, at: seconds, settings: settings)
            }.value
            lines = text.map { $0.components(separatedBy: "\n") } ?? []
            reading = false
            highlighted = rows.isEmpty ? nil : 0
        }
    }

    private func rowView(_ index: Int, _ line: String) -> some View {
        let active = index == activeIndex
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
        guard let index = activeIndex, rows.indices.contains(index) else { return }
        pick(rows[index])
    }

    private func pick(_ line: String) {
        if let tag = Self.resolve(line, in: index) {
            onApply(tag)
            // The list stays: the next line may be a tag too.
            draft = ""
            highlighted = nil
        } else {
            creating = line
        }
    }
}
```

- [ ] **Step 4: Run** `swift test --filter OnScreenTextFieldTests` — 3 pass.
- [ ] **Step 5: Commit** `Player: the On-screen Text field, with its tested rows and resolution`.

---

### Task 4: The panel places the field

**Files:**
- Modify: `Sources/SightsAndSoundsApp/Player/TagPanelView.swift`

- [ ] **Step 1:** State after `resultsPosition`:
```swift
    /// The On-screen Text field's place — same rule, own setting.
    @State private var onScreenPosition
        = AppSettingsStore.shared.current.onScreenTextFieldPosition
```
Placement: after each `if clampedResultsPosition == 0 { resultsBlock }` and `if clampedResultsPosition == index + 1 { resultsBlock }` add the same test for `clampedOnScreenPosition` rendering `onScreenBlock`.

Helpers after `setResultsPosition`:
```swift
    private var clampedOnScreenPosition: Int {
        min(max(0, onScreenPosition), model.panelVocabulary.count)
    }

    private func setOnScreenPosition(_ position: Int) {
        onScreenPosition = position
        AppSettingsStore.shared.update { $0.onScreenTextFieldPosition = position }
    }
```
Extend `setPseudoFieldPosition` with:
```swift
        if id == PlayerModel.onScreenTextFieldFocusID { setOnScreenPosition(position); return true }
```

- [ ] **Step 2: Drops on the pseudo rows.** In `universalBlock`'s and `resultsBlock`'s `.dropDestination`, replace the `if id == <other pseudo> { set…; return true }` line with `if setPseudoFieldPosition(id, to: <this row's clamped position>) { return true }` (guarding the row's own id first as now). Add `onScreenBlock` after `resultsBlock`, a copy of `resultsBlock` with: the sentinel `onScreenTextFieldFocusID`, heading "On-screen Text", `clampedOnScreenPosition`, and the field:
```swift
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
```

- [ ] **Step 3: Build** — zero warnings. **Commit** `Player: the On-screen Text row in the tag panel, reorderable`.

---

### Task 5: Spec, verification, PR

- [ ] **Step 1:** `docs/design/03-player.md`: extend the pseudo-fields paragraph (added by the results-field PR) with: `**On-screen Text** (\`onScreenTextFieldPosition\`): ↓ reads the frame at the playhead with Vision and lists its lines; Enter applies the tag a line names, or opens New Tag seeded with it. \`No video frame to read\` for audio.`
- [ ] **Step 2:** Verify: zero-warning build, `swift test`, both guards, bundle launch. Record outputs.
- [ ] **Step 3:** Commit, `git push -u origin feature/player-on-screen-text-field`.
- [ ] **Step 4:** PR via `github-putty`, base `feature/player-analysis-results-field` (stacked on #220; say so). Report the URL and stop.
