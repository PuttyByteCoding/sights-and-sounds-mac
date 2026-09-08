# Player "Tag Analysis Results" Field Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A reorderable "Tag Analysis Results" field in the player's tag panel that lists the tags the companion found for the shown video and applies one on Enter, with a spinner while the analysis runs.

**Architecture:** A new `AnalysisResultsField` view reads the player's `TagAnalysisSession` (analysis, in-flight flag, companion open flag) and applies through `PlayerModel.applyTag`. Its row list comes from a pure, tested function. The panel places it like the Universal row, with its own persisted position and a second focus sentinel in the Tab walk, whose order is a pure, tested function too.

**Tech Stack:** Swift 6, SwiftUI, Observation, Swift Testing. macOS 15+.

**Spec:** `docs/superpowers/specs/2026-09-08-tag-analysis-companion-design.md` §"The player: Tag Analysis Results field" (delivery item 3). Branch `feature/player-analysis-results-field`, stacked on `feature/tag-analysis-companion`.

## Global Constraints

- Worktree `/Users/mark/Code/sights-and-sounds-claude`; never the main checkout. Zero-warning build, full `swift test`, both `scripts/check-*.sh`, and a bundle launch before pushing.
- Copy verbatim: heading "Tag Analysis Results"; placeholder "Open Tag Analysis to see results"; list text "Scanning…" and "Nothing found for this video."
- Settings decode tolerantly (`decodeIfPresent` with defaults) like every other field.
- Tests never write `AppSettingsStore.shared`; pure functions take positions as parameters.

---

### Task 1: The field's position setting

**Files:**
- Modify: `Sources/SightsAndSoundsKit/Settings/AppSettings.swift` (beside `universalTagFieldPosition`: declaration ~line 75, init parameter ~105, assignment ~127, decode ~174)
- Test: `Tests/SightsAndSoundsKitTests/SettingsTests.swift` (append a suite)

**Interfaces:**
- Produces: `AppSettings.analysisResultsFieldPosition: Int` (default 1, clamped ≥ 0).

- [ ] **Step 1: Write the failing tests** — append to `SettingsTests.swift`:

```swift
/// The Tag Analysis Results field's place among the tag panel's
/// categories — the Universal field's rule, one slot later by default.
@Suite struct AnalysisResultsFieldPositionTests {
    @Test func theDefaultSitsAfterTheUniversalField() {
        #expect(AppSettings().analysisResultsFieldPosition == 1)
    }

    @Test func aSettingsFileWrittenBeforeThisSettingStillLoads() throws {
        let decoded = try JSONDecoder().decode(
            AppSettings.self, from: Data(#"{"loopVideos": false}"#.utf8))
        #expect(decoded.analysisResultsFieldPosition == 1)
    }

    @Test func aNegativeValueIsClampedToFirst() throws {
        let decoded = try JSONDecoder().decode(
            AppSettings.self, from: Data(#"{"analysisResultsFieldPosition": -3}"#.utf8))
        #expect(decoded.analysisResultsFieldPosition == 0)
    }
}
```

- [ ] **Step 2: Run** `swift build --build-tests 2>&1 | grep error: | head -2` — expect `has no member 'analysisResultsFieldPosition'`.

- [ ] **Step 3: Add the field.** After `public var universalTagFieldPosition: Int`:

```swift
    /// Where the tag panel's Tag Analysis Results field sits among the
    /// categories, the Universal field's rule: an index into the
    /// category list, 0 = first, past the end = last. Both pseudo-fields
    /// at one index render Universal first.
    public var analysisResultsFieldPosition: Int
```
Init parameter after `universalTagFieldPosition: Int = 0`: `analysisResultsFieldPosition: Int = 1` and the assignment `self.analysisResultsFieldPosition = analysisResultsFieldPosition`. Decode, after the `universalTagFieldPosition = ...` statement:

```swift
        analysisResultsFieldPosition = max(0, try container.decodeIfPresent(
            Int.self, forKey: .analysisResultsFieldPosition)
            ?? defaults.analysisResultsFieldPosition)
```

- [ ] **Step 4: Run** `swift test --filter AnalysisResultsFieldPositionTests 2>&1 | grep "Test run with"` — 3 pass.

- [ ] **Step 5: Commit** `Settings: a position for the Tag Analysis Results field`.

---

### Task 2: The Tab walk knows a second pseudo-field

**Files:**
- Modify: `Sources/SightsAndSoundsApp/Player/PlayerModel.swift` (`universalFieldFocusID` ~line 417, `advanceTagField` ~465)
- Test: `Tests/SightsAndSoundsAppTests/TagFieldOrderTests.swift`

**Interfaces:**
- Produces: `PlayerModel.analysisResultsFieldFocusID: UUID`; `PlayerModel.tagFieldOrder(searchCategoryIDs:universalPosition:resultsPosition:) -> [UUID]` (static, pure); `advanceTagField` walks it.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/SightsAndSoundsAppTests/TagFieldOrderTests.swift
import Foundation
import Testing

@testable import SightsAndSoundsApp

/// The tag panel's Tab walk: the search categories in panel order, with
/// the Universal and Tag Analysis Results fields inserted at their
/// positions. Universal first when both land on one index.
@Suite struct TagFieldOrderTests {
    private let a = UUID(), b = UUID(), c = UUID()
    private let universal = PlayerModel.universalFieldFocusID
    private let results = PlayerModel.analysisResultsFieldFocusID

    @Test func defaultsPutUniversalFirstThenResults() {
        let order = PlayerModel.tagFieldOrder(
            searchCategoryIDs: [a, b, c], universalPosition: 0, resultsPosition: 1)
        #expect(order == [universal, a, results, b, c])
    }

    @Test func bothAtOneIndexKeepUniversalFirst() {
        let order = PlayerModel.tagFieldOrder(
            searchCategoryIDs: [a, b], universalPosition: 1, resultsPosition: 1)
        #expect(order == [a, universal, results, b])
    }

    @Test func resultsBeforeUniversalWhenPositionedSo() {
        let order = PlayerModel.tagFieldOrder(
            searchCategoryIDs: [a, b], universalPosition: 2, resultsPosition: 0)
        #expect(order == [results, a, b, universal])
    }

    @Test func positionsPastTheEndMeanLast() {
        let order = PlayerModel.tagFieldOrder(
            searchCategoryIDs: [a], universalPosition: 9, resultsPosition: 9)
        #expect(order == [a, universal, results])
    }

    @Test func noCategoriesStillWalksTheTwoFields() {
        let order = PlayerModel.tagFieldOrder(
            searchCategoryIDs: [], universalPosition: 0, resultsPosition: 1)
        #expect(order == [universal, results])
    }
}
```

- [ ] **Step 2: Run** `swift build --build-tests 2>&1 | grep error: | head -2` — expect missing `analysisResultsFieldFocusID` / `tagFieldOrder`.

- [ ] **Step 3: Implement.** After `static let universalFieldFocusID = ...`:

```swift
    /// The Tag Analysis Results field's slot in the focus walk — the
    /// second fixed sentinel beside the category IDs.
    static let analysisResultsFieldFocusID = UUID(
        uuidString: "22222222-2222-2222-2222-222222222222")!

    /// The panel's Tab order: the search categories in panel order with
    /// the two pseudo-fields inserted at their positions. Positions are
    /// indexes into the category list; past the end means last; both at
    /// one index render — and walk — Universal first.
    static func tagFieldOrder(
        searchCategoryIDs: [UUID], universalPosition: Int, resultsPosition: Int
    ) -> [UUID] {
        var fields = searchCategoryIDs
        let universal = min(max(0, universalPosition), fields.count)
        let results = min(max(0, resultsPosition), fields.count)
        if results >= universal {
            fields.insert(analysisResultsFieldFocusID, at: results)
            fields.insert(universalFieldFocusID, at: universal)
        } else {
            fields.insert(universalFieldFocusID, at: universal)
            fields.insert(analysisResultsFieldFocusID, at: results)
        }
        return fields
    }
```

Replace the body of `advanceTagField(reverse:)` up to the `guard !fields.isEmpty` line with:

```swift
        let settings = AppSettingsStore.shared.current
        let fields = Self.tagFieldOrder(
            searchCategoryIDs: panelVocabulary
                .filter { $0.category.displayStyle == .search }
                .map(\.id),
            universalPosition: settings.universalTagFieldPosition,
            resultsPosition: settings.analysisResultsFieldPosition)
```
(keep the rest of the function unchanged).

- [ ] **Step 4: Run** `swift test --filter TagFieldOrderTests 2>&1 | grep "Test run with"` — 5 pass.

- [ ] **Step 5: Commit** `Player: the tag panel's Tab walk knows the Tag Analysis Results field`.

---

### Task 3: The field and its pure row list

**Files:**
- Create: `Sources/SightsAndSoundsApp/Player/AnalysisResultsField.swift`
- Test: `Tests/SightsAndSoundsAppTests/AnalysisResultsFieldTests.swift`

**Interfaces:**
- Consumes: `TagAnalysisSession` (`analysis`, `isAnalyzing`, `companionIsOpen`), `TagSearchEntry.fold`, `Theme.categoryHue`.
- Produces:
  ```swift
  struct AnalysisResultsField: View {
      struct Candidate: Identifiable, Equatable { let tag: Tag; let categoryID: UUID; let categoryName: String; var id: UUID { tag.id } }
      static func candidates(analysis: ItemAnalysis, appliedIDs: Set<UUID>, categories: [TagCategory], query: String) -> [Candidate]
      init(session: TagAnalysisSession?, appliedIDs: Set<UUID>, categories: [TagCategory], focus: FocusState<UUID?>.Binding, focusID: UUID, itemID: UUID?, onApply: @escaping (Tag) -> Void)
  }
  ```

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/SightsAndSoundsAppTests/AnalysisResultsFieldTests.swift
import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// The rows the Tag Analysis Results field offers: the companion's
/// existing-tag findings, one per tag, minus what the video already
/// wears, in category order, narrowed by the typed terms.
@Suite struct AnalysisResultsFieldTests {
    private let band = TagCategory(name: "Band")
    private let taper = TagCategory(name: "Taper")

    private func finding(_ tag: Tag, in category: TagCategory, matched: String? = nil,
                         applied: Bool = false) -> ExistingTagFinding {
        ExistingTagFinding(
            tag: tag, categoryName: category.name, matchedText: matched ?? tag.name,
            foundIn: "somewhere", alreadyApplied: applied)
    }

    private func analysis(_ findings: [ExistingTagFinding]) -> ItemAnalysis {
        ItemAnalysis(
            suggested: [], existing: findings, unmapped: [], md5s: [], matchedSchemas: [],
            readerReports: [], truncated: false, provenance: [])
    }

    @Test func oneRowPerTagInCategoryOrderMinusApplied() {
        let mike = Tag(tagCategoryID: taper.id, name: "Mike Jones")
        let phish = Tag(tagCategoryID: band.id, name: "Phish")
        let worn = Tag(tagCategoryID: band.id, name: "Worn Already")
        let rows = AnalysisResultsField.candidates(
            analysis: analysis([
                finding(mike, in: taper), finding(mike, in: taper),  // twice: two strings
                finding(phish, in: band), finding(worn, in: band, applied: true),
            ]),
            appliedIDs: [worn.id], categories: [band, taper], query: "")
        #expect(rows.map(\.tag.name) == ["Phish", "Mike Jones"])
        #expect(rows.map(\.categoryName) == ["Band", "Taper"])
    }

    @Test func termsNarrowByNameOrTheAliasThatMatched() {
        let sbd = Tag(tagCategoryID: band.id, name: "Soundboard")
        let aud = Tag(tagCategoryID: band.id, name: "Audience")
        let all = analysis([finding(sbd, in: band, matched: "SBD"), finding(aud, in: band)])
        #expect(AnalysisResultsField.candidates(
            analysis: all, appliedIDs: [], categories: [band], query: "sbd").map(\.tag.name)
            == ["Soundboard"])
        #expect(AnalysisResultsField.candidates(
            analysis: all, appliedIDs: [], categories: [band], query: "aud ien").map(\.tag.name)
            == ["Audience"])
        #expect(AnalysisResultsField.candidates(
            analysis: all, appliedIDs: [], categories: [band], query: "zzz").isEmpty)
    }

    @Test func aTagWhoseCategoryIsUnknownGoesLast() {
        let orphan = Tag(tagCategoryID: UUID(), name: "Orphan")
        let phish = Tag(tagCategoryID: band.id, name: "Phish")
        let rows = AnalysisResultsField.candidates(
            analysis: analysis([finding(orphan, in: taper), finding(phish, in: band)]),
            appliedIDs: [], categories: [band], query: "")
        #expect(rows.map(\.tag.name) == ["Phish", "Orphan"])
    }
}
```

`ExistingTagFinding` needs a public memberwise init; if `ItemAnalysis.swift` lacks one, add inside the struct:
```swift
    public init(tag: Tag, categoryName: String, matchedText: String, foundIn: String, alreadyApplied: Bool) {
        self.tag = tag; self.categoryName = categoryName; self.matchedText = matchedText
        self.foundIn = foundIn; self.alreadyApplied = alreadyApplied
    }
```

- [ ] **Step 2: Run** `swift build --build-tests 2>&1 | grep error: | head -2` — expect `cannot find 'AnalysisResultsField'`.

- [ ] **Step 3: Create the field**

```swift
// Sources/SightsAndSoundsApp/Player/AnalysisResultsField.swift
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
```

- [ ] **Step 4: Run** `swift test --filter AnalysisResultsFieldTests 2>&1 | grep -E "Test run with|✘"` — 3 pass.

- [ ] **Step 5: Commit** `Player: the Tag Analysis Results field, with its tested row list`.

---

### Task 4: The panel places the field

**Files:**
- Modify: `Sources/SightsAndSoundsApp/Player/TagPanelView.swift` (state ~line 24-27; body's Universal placement ~52-54 and ~146-149; drop destinations ~119-128 and ~137-147; `clampedUniversalPosition`/`setUniversalPosition` ~157-165; `universalBlock` ~170-215)

- [ ] **Step 1: State and placement.** After the `universalPosition` state add:

```swift
    /// The Tag Analysis Results field's place — same rule, own setting.
    @State private var resultsPosition
        = AppSettingsStore.shared.current.analysisResultsFieldPosition
```

After `private var clampedUniversalPosition` / `setUniversalPosition` add:

```swift
    private var clampedResultsPosition: Int {
        min(max(0, resultsPosition), model.panelVocabulary.count)
    }

    private func setResultsPosition(_ position: Int) {
        resultsPosition = position
        AppSettingsStore.shared.update { $0.analysisResultsFieldPosition = position }
    }

    /// A dragged heading's id, if it is one of the two pseudo-fields.
    private func setPseudoFieldPosition(_ id: UUID, to position: Int) -> Bool {
        if id == PlayerModel.universalFieldFocusID { setUniversalPosition(position); return true }
        if id == PlayerModel.analysisResultsFieldFocusID { setResultsPosition(position); return true }
        return false
    }
```

In the body, where `if clampedUniversalPosition == 0 { universalBlock }` appears, add directly after it:
```swift
                    if clampedResultsPosition == 0 {
                        resultsBlock
                    }
```
and where `if clampedUniversalPosition == index + 1 { universalBlock }` appears, add after it:
```swift
                        if clampedResultsPosition == index + 1 {
                            resultsBlock
                        }
```

- [ ] **Step 2: Drops.** In the category `.dropDestination` (the one calling `setUniversalPosition(index)`), replace
```swift
                            if id == PlayerModel.universalFieldFocusID {
                                setUniversalPosition(index)
                            } else {
                                model.moveCategory(id, before: entry.category.id)
                            }
```
with
```swift
                            if !setPseudoFieldPosition(id, to: index) {
                                model.moveCategory(id, before: entry.category.id)
                            }
```
and in the end-of-list drop replace
```swift
                            if id == PlayerModel.universalFieldFocusID {
                                setUniversalPosition(model.panelVocabulary.count)
                            } else {
                                model.moveCategory(id, before: nil)
                            }
```
with
```swift
                            if !setPseudoFieldPosition(id, to: model.panelVocabulary.count) {
                                model.moveCategory(id, before: nil)
                            }
```

In `universalBlock`'s own `.dropDestination`, replace the guard and body:
```swift
            guard let id = dropped.first.flatMap(UUID.init(uuidString:)),
                  id != PlayerModel.universalFieldFocusID
            else { return false }
            // The other pseudo-field dropped here takes this slot; a
            // category dropped here takes it and pushes the field down.
            if id == PlayerModel.analysisResultsFieldFocusID {
                setResultsPosition(clampedUniversalPosition)
                return true
            }
            let following = clampedUniversalPosition < model.panelVocabulary.count
                ? model.panelVocabulary[clampedUniversalPosition].category.id : nil
            model.moveCategory(id, before: following)
            return true
```

- [ ] **Step 3: The results row.** After `universalBlock`'s closing brace add:

```swift
    /// The Tag Analysis Results row, reorderable like the Universal one:
    /// heading, ≡ grip, the same landing line, the field underneath.
    @ViewBuilder
    private var resultsBlock: some View {
        if dropTargetID == PlayerModel.analysisResultsFieldFocusID {
            DropInsertionLine()
        }
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
                    .draggable(PlayerModel.analysisResultsFieldFocusID.uuidString)
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
        .dropDestination(for: String.self) { dropped, _ in
            dropTargetID = nil
            guard let id = dropped.first.flatMap(UUID.init(uuidString:)),
                  id != PlayerModel.analysisResultsFieldFocusID
            else { return false }
            if id == PlayerModel.universalFieldFocusID {
                setUniversalPosition(clampedResultsPosition)
                return true
            }
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
```

- [ ] **Step 4: Build** — zero warnings. Then the focus-walk `onChange` pair at the bottom of `TagPanelView.body` already mirrors `model.tagFieldCategoryID`, so numpad 8 and Tab reach the new field through the sentinel; nothing else to wire.

- [ ] **Step 5: Commit** `Player: the Tag Analysis Results row in the tag panel, reorderable`.

---

### Task 5: Spec line, verification, PR

- [ ] **Step 1: `docs/design/03-player.md`** — find the line that describes the Universal field in the tag panel (`grep -n -i universal docs/design/03-player.md`) and add after that paragraph:

```
The **Tag Analysis Results** row sits beside the Universal one, reorderable the same way
(`analysisResultsFieldPosition`): ↓ lists the tags the companion found for this video that it
does not yet wear, typing narrows, Enter applies through the player. Dimmed —
`Open Tag Analysis to see results` — while no companion is open; a spinner while it scans.
```
If no Universal paragraph exists, add this as a bullet under the tag panel's layout section.

- [ ] **Step 2: Verify** — zero-warning build, `swift test` all pass, both guards clean, bundle launch alive then quit. Record outputs.

- [ ] **Step 3: Commit, push** `git push -u origin feature/player-analysis-results-field`.

- [ ] **Step 4: PR** via `github-putty`, base `feature/tag-analysis-companion` (stacked — say so in the body; retarget to `dev` once #219 merges). Sections Why / What / Verification / After merging. Report the URL and stop.
