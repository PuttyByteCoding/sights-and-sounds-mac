# Tag Analysis Companion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Tag Analysis window stops owning a player and a queue and follows one player window through a shared session; accepting applies at once.

**Architecture:** A `TagAnalysisSession` object (registered in `AppModel` by id) is written by the player (current item, position, open flag, an apply hook) and by the companion (analysis, in-flight flag, open flag). `TagAnalysisModel` observes the session instead of walking its own queue. The aux window request carries the session id.

**Tech Stack:** Swift 6, SwiftUI, Observation, GRDB (via the Kit), Swift Testing. macOS 15+.

**Spec:** `docs/superpowers/specs/2026-09-08-tag-analysis-companion-design.md` (this plan covers its Delivery item 2; items 3 and 4 get their own plans after this merges).

## Global Constraints

- Work in the worktree `/Users/mark/Code/sights-and-sounds-claude` on branch `feature/tag-analysis-companion` (already carries the spec). Never touch `/Users/mark/Code/sights-and-sounds-mac`.
- Build with zero warnings: `swift build 2>&1 | grep -E "warning:|error:|Build complete"`.
- Tests: `swift test` (Kit + App targets). Guards: `scripts/check-no-private-data.sh`, `scripts/check-terminology.sh`. Launch check: `./scripts/make-app-bundle.sh && open dist/SightsAndSounds.app`, then `pkill -f sights-and-sounds-claude/dist`.
- Commit messages: `Area: what changed`, body says why/what/how verified, ends with the Co-Authored-By and Claude-Session trailers used on this branch. Never `--no-verify`.
- Test data stays synthetic (names like `a.mp4`, `Taper`, `Mike Jones`).
- Copy is verbatim from the spec: "The player this window follows has closed.", "Apply", "Apply Existing", "tags applied", "videos visited".

---

### Task 1: TagAnalysisSession and the app registry

**Files:**
- Create: `Sources/SightsAndSoundsApp/TagAnalysis/TagAnalysisSession.swift`
- Modify: `Sources/SightsAndSoundsApp/SightsAndSoundsApp.swift` (class `AppModel`, after `var loadError`)
- Test: `Tests/SightsAndSoundsAppTests/TagAnalysisSessionTests.swift`

**Interfaces:**
- Produces:
  ```swift
  @Observable @MainActor final class TagAnalysisSession {
      let id: UUID; let libraryID: UUID; let library: LibraryDatabase
      private(set) var itemID: UUID?
      private(set) var position: (index: Int, count: Int)?
      private(set) var playerIsOpen: Bool
      var apply: (Tag) -> Void
      var step: (Int) -> Void
      private(set) var analysis: ItemAnalysis
      private(set) var isAnalyzing: Bool
      private(set) var companionIsOpen: Bool
      init(libraryID: UUID, library: LibraryDatabase)
      // player side
      func playerDidShow(itemID: UUID?, position: (index: Int, count: Int)?)
      func playerDidClose()
      // companion side
      func companionDidOpen()
      func companionWillReload()
      func companionDidReload(_ analysis: ItemAnalysis)
      func companionDidClose()
      var isFinished: Bool   // both sides closed
  }
  extension AppModel {
      var analysisSessions: [UUID: TagAnalysisSession]
      func registerAnalysisSession(_ session: TagAnalysisSession)
      func analysisSession(for id: UUID) -> TagAnalysisSession?
      func releaseAnalysisSessionIfFinished(_ id: UUID)
  }
  ```

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/SightsAndSoundsAppTests/TagAnalysisSessionTests.swift
import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// The handshake between a player and its companion: what each side
/// writes, and when the session is finished with.
@Suite @MainActor struct TagAnalysisSessionTests {

    private func makeSession() throws -> TagAnalysisSession {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Session")
        return TagAnalysisSession(libraryID: UUID(), library: library)
    }

    @Test func aFreshSessionHasAnOpenPlayerAndNoCompanion() throws {
        let session = try makeSession()
        #expect(session.playerIsOpen)
        #expect(!session.companionIsOpen)
        #expect(session.itemID == nil)
        #expect(session.analysis == .empty)
        #expect(!session.isAnalyzing)
        #expect(!session.isFinished)
    }

    @Test func thePlayerWritesTheItemAndPosition() throws {
        let session = try makeSession()
        let id = UUID()
        session.playerDidShow(itemID: id, position: (index: 2, count: 41))
        #expect(session.itemID == id)
        #expect(session.position?.index == 2)
        #expect(session.position?.count == 41)
    }

    @Test func theCompanionWritesTheAnalysisAndTheInFlightFlag() throws {
        let session = try makeSession()
        session.companionDidOpen()
        #expect(session.companionIsOpen)
        session.companionWillReload()
        #expect(session.isAnalyzing)
        let analysis = ItemAnalysis(
            suggested: [], existing: [], unmapped: [], md5s: [], matchedSchemas: [],
            readerReports: [], truncated: true, provenance: [])
        session.companionDidReload(analysis)
        #expect(!session.isAnalyzing)
        #expect(session.analysis.truncated)
    }

    @Test func closingTheCompanionClearsItsHalf() throws {
        let session = try makeSession()
        session.companionDidOpen()
        session.companionWillReload()
        session.companionDidClose()
        #expect(!session.companionIsOpen)
        #expect(!session.isAnalyzing)
        #expect(session.analysis == .empty)
        #expect(!session.isFinished)  // the player is still up
    }

    @Test func theSessionIsFinishedOnlyWhenBothSidesHaveClosed() throws {
        let session = try makeSession()
        session.companionDidOpen()
        session.playerDidClose()
        #expect(!session.playerIsOpen)
        #expect(!session.isFinished)
        session.companionDidClose()
        #expect(session.isFinished)
    }

    @Test func theRegistryHandsBackTheSameSessionAndReleasesAFinishedOne() throws {
        let app = AppModel()
        let session = try makeSession()
        app.registerAnalysisSession(session)
        #expect(app.analysisSession(for: session.id) === session)
        app.releaseAnalysisSessionIfFinished(session.id)
        #expect(app.analysisSession(for: session.id) === session)  // still open
        session.playerDidClose()
        session.companionDidClose()
        app.releaseAnalysisSessionIfFinished(session.id)
        #expect(app.analysisSession(for: session.id) == nil)
    }
}
```

Note: `ItemAnalysis` must be constructible from the app test. Check `Sources/SightsAndSoundsKit/TagAnalysis/ItemAnalysis.swift` for its memberwise init; if the init is internal, add a `public init(...)` with the same parameter order (suggested, existing, unmapped, md5s, matchedSchemas, readerReports, truncated, provenance) and make `ItemAnalysis` `Equatable` (it already is).

- [ ] **Step 2: Run the tests to watch them fail to compile**

Run: `swift build --build-tests 2>&1 | grep -E "error:" | head -3`
Expected: `cannot find 'TagAnalysisSession' in scope`.

- [ ] **Step 3: Create the session**

```swift
// Sources/SightsAndSoundsApp/TagAnalysis/TagAnalysisSession.swift
import Foundation
import Observation
import SightsAndSoundsKit

/// The handshake between one player window and its Tag Analysis
/// companion. The player writes what it is showing; the companion
/// writes what it found. Neither learns the other's internals: the
/// player installs `apply` and `step`, the companion calls them.
///
/// Registered in `AppModel` by id so the companion's window request —
/// which must be Codable for saved window state — can carry a UUID
/// rather than an object. A restored window whose id is unknown shows
/// its closed state; it never creates a player.
@Observable @MainActor
final class TagAnalysisSession {
    let id: UUID
    let libraryID: UUID
    let library: LibraryDatabase

    // MARK: Written by the player

    /// What the player is showing. nil until the first load lands.
    private(set) var itemID: UUID?
    /// Where in the playlist — "3 of 41". nil for a single item.
    private(set) var position: (index: Int, count: Int)?
    private(set) var playerIsOpen = true
    /// Apply one tag to the shown item, through the player's own path
    /// so its panel and history refresh. Installed by the player.
    var apply: (Tag) -> Void = { _ in }
    /// The player's next (+1) / previous (−1). Installed by the player.
    var step: (Int) -> Void = { _ in }

    // MARK: Written by the companion

    private(set) var analysis: ItemAnalysis = .empty
    private(set) var isAnalyzing = false
    private(set) var companionIsOpen = false

    init(libraryID: UUID, library: LibraryDatabase) {
        self.id = UUID()
        self.libraryID = libraryID
        self.library = library
    }

    func playerDidShow(itemID: UUID?, position: (index: Int, count: Int)?) {
        self.itemID = itemID
        self.position = position
    }

    func playerDidClose() {
        playerIsOpen = false
        apply = { _ in }
        step = { _ in }
    }

    func companionDidOpen() {
        companionIsOpen = true
    }

    func companionWillReload() {
        isAnalyzing = true
    }

    func companionDidReload(_ analysis: ItemAnalysis) {
        self.analysis = analysis
        isAnalyzing = false
    }

    func companionDidClose() {
        companionIsOpen = false
        isAnalyzing = false
        analysis = .empty
    }

    /// Both sides gone — the registry can drop it.
    var isFinished: Bool { !playerIsOpen && !companionIsOpen }
}
```

Add to `AppModel` in `Sources/SightsAndSoundsApp/SightsAndSoundsApp.swift`, directly after the `var loadError` property block:

```swift
    // MARK: - Tag Analysis sessions

    /// One per player that has opened a companion. Keyed by id because
    /// the companion's window request carries the id, not the object.
    private(set) var analysisSessions: [UUID: TagAnalysisSession] = [:]

    func registerAnalysisSession(_ session: TagAnalysisSession) {
        analysisSessions[session.id] = session
    }

    func analysisSession(for id: UUID) -> TagAnalysisSession? {
        analysisSessions[id]
    }

    /// Drop a session both sides have closed. Called by whichever side
    /// closes last; harmless when the other is still up.
    func releaseAnalysisSessionIfFinished(_ id: UUID) {
        guard let session = analysisSessions[id], session.isFinished else { return }
        analysisSessions[id] = nil
    }
```

If `ItemAnalysis` has no public init, add one in `Sources/SightsAndSoundsKit/TagAnalysis/ItemAnalysis.swift` inside the struct:

```swift
    public init(
        suggested: [AnalysisCandidate], existing: [ExistingTagFinding],
        unmapped: [AnalysisCandidate], md5s: [String], matchedSchemas: [String],
        readerReports: [ReaderReport], truncated: Bool, provenance: [ProvenanceStep]
    ) {
        self.suggested = suggested
        self.existing = existing
        self.unmapped = unmapped
        self.md5s = md5s
        self.matchedSchemas = matchedSchemas
        self.readerReports = readerReports
        self.truncated = truncated
        self.provenance = provenance
    }
```

(Match the stored property names exactly as declared in that file; `.empty` already exists.)

- [ ] **Step 4: Run the tests**

Run: `swift test --filter TagAnalysisSessionTests 2>&1 | grep -E "Test run with|✘"`
Expected: `Test run with 6 tests in 1 suite passed`.

- [ ] **Step 5: Commit**

```bash
git add Sources/SightsAndSoundsApp/TagAnalysis/TagAnalysisSession.swift Sources/SightsAndSoundsApp/SightsAndSoundsApp.swift Tests/SightsAndSoundsAppTests/TagAnalysisSessionTests.swift Sources/SightsAndSoundsKit/TagAnalysis/ItemAnalysis.swift
git commit -m "Tag analysis: a session object between a player and its companion"
```
(Write the full body per the Global Constraints.)

---

### Task 2: The player publishes to the session and applies through one path

**Files:**
- Modify: `Sources/SightsAndSoundsApp/Player/PlayerModel.swift` — `apply(loaded:url:)` (~line 232), `updatePlaylist` (~146), `toggleTag` (~526), `shutdown()` (~853)

**Interfaces:**
- Consumes: `TagAnalysisSession` (Task 1).
- Produces:
  ```swift
  extension PlayerModel {
      private(set) var analysisSession: TagAnalysisSession?
      func analysisSession(registeringIn app: AppModel) -> TagAnalysisSession
      func applyTag(_ tagID: UUID)
  }
  ```

- [ ] **Step 1: Add the session property, creation and publishing**

In `PlayerModel`, after `private(set) var playlist: [UUID]`:

```swift
    /// The companion's handshake, created the first time Tag Analysis
    /// is opened from this player and kept for the player's life. The
    /// player only ever writes what it is showing; see the session.
    private(set) var analysisSession: TagAnalysisSession?

    /// The session for this player, registered on first use so the
    /// companion's window can find it by id.
    func analysisSession(registeringIn app: AppModel) -> TagAnalysisSession {
        if let analysisSession { return analysisSession }
        let session = TagAnalysisSession(libraryID: libraryID, library: library)
        session.apply = { [weak self] tag in self?.applyTag(tag.id) }
        session.step = { [weak self] delta in
            delta < 0 ? self?.goPrevious() : self?.goNext()
        }
        app.registerAnalysisSession(session)
        analysisSession = session
        publishToSession()
        return session
    }

    /// What the companion follows: the shown item and its place in the
    /// playlist. Cheap and idempotent — called on every load and every
    /// playlist change.
    private func publishToSession() {
        guard let analysisSession else { return }
        let position: (index: Int, count: Int)? = {
            guard playlist.count > 1, let item, let index = playlist.firstIndex(of: item.id)
            else { return nil }
            return (index, playlist.count)
        }()
        analysisSession.playerDidShow(itemID: item?.id, position: position)
    }
```

In `apply(loaded:url:)`, add `publishToSession()` as the last line before `play()` (after `refreshBlocks()`). Also in the two early-return branches of that method (`guard let loaded` and `guard let url`), the item may be set; add `publishToSession()` after `item = loaded` in the offline branch.

In `updatePlaylist(_:)`, after `loadQueueItems()` add `publishToSession()`.

In `shutdown()`, add as the first line:

```swift
        analysisSession?.playerDidClose()
```

- [ ] **Step 2: Add `applyTag`**

After `func toggleTag(_ tagID: UUID)`:

```swift
    /// Apply (never remove) one tag — the companion's path in, and the
    /// results field's. Records the session history like a toggle-on
    /// does, and refreshes the panel, so a tag applied from the other
    /// window appears here at once without a broadcast.
    func applyTag(_ tagID: UUID) {
        guard let item else { return }
        do {
            try library.assignTag(tagID, to: item.id)
            recentlyAppliedTagIDs.removeAll { $0 == tagID }
            recentlyAppliedTagIDs.insert(tagID, at: 0)
            if recentlyAppliedTagIDs.count > 30 {
                recentlyAppliedTagIDs.removeLast()
            }
            refreshTagging()
        } catch {
            loadError = "\(error)"
        }
    }
```

- [ ] **Step 3: Build**

Run: `swift build 2>&1 | grep -E "warning:|error:|Build complete"`
Expected: `Build complete!` with no warnings.

- [ ] **Step 4: Commit**

```bash
git add Sources/SightsAndSoundsApp/Player/PlayerModel.swift
git commit -m "Player: publish the shown item to the analysis session and apply through one path"
```

---

### Task 3: TagAnalysisModel follows the session

**Files:**
- Modify: `Sources/SightsAndSoundsApp/TagAnalysis/TagAnalysisModel.swift` (large rewrite)
- Delete: `Tests/SightsAndSoundsAppTests/TagAnalysisPreviewTests.swift`
- Test: `Tests/SightsAndSoundsAppTests/TagAnalysisModelTests.swift`

**Interfaces:**
- Consumes: `TagAnalysisSession` (Task 1).
- Produces:
  ```swift
  final class TagAnalysisModel {
      init(session: TagAnalysisSession)
      let session: TagAnalysisSession
      var currentItemID: UUID? { session.itemID }
      var positionText: String?            // "3 of 41" or nil
      var playerIsOpen: Bool { session.playerIsOpen }
      enum StatusFilter { case undecided, applied, ignored, everything }
      func applyNow(_ tag: Tag)
      func applyNew(value: String, categoryID: UUID)
      func reload()
      func close()                          // companionDidClose + mark analyzed
      private(set) var tagsAppliedThisPass: Int
      private(set) var videosVisitedThisPass: Int
  }
  ```

- [ ] **Step 1: Write the failing tests**

Delete `Tests/SightsAndSoundsAppTests/TagAnalysisPreviewTests.swift` (the preview is gone). Create:

```swift
// Tests/SightsAndSoundsAppTests/TagAnalysisModelTests.swift
import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// The companion's model follows the session it was given: a new item
/// on the session is a reload, results land back on the session, and
/// applying goes through the session's hook.
@Suite @MainActor struct TagAnalysisModelTests {

    private func makeSession() async throws -> (TagAnalysisSession, [MediaItem], TagCategory) {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Companion")
        let source = Source(name: "S", rootPath: "/tmp/companion-\(UUID().uuidString)")
        let taper = TagCategory(name: "Taper")
        let items = ["show-with_MikeJones-a.mp4", "b.mp4"].map {
            MediaItem(sourceID: source.id, kind: .video, relativePath: $0, needsReview: false)
        }
        try await library.writer.write { db in
            try source.insert(db)
            try taper.insert(db)
            for item in items { try item.insert(db) }
            try Tag(tagCategoryID: taper.id, name: "Mike Jones").insert(db)
        }
        return (TagAnalysisSession(libraryID: UUID(), library: library), items, taper)
    }

    private func settle(_ model: TagAnalysisModel) async throws {
        for _ in 0..<400 where model.isLoading {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(!model.isLoading)
    }

    @Test func aNewItemOnTheSessionReloadsAndPublishesTheAnalysis() async throws {
        let (session, items, _) = try await makeSession()
        let model = TagAnalysisModel(session: session)
        #expect(session.companionIsOpen)

        session.playerDidShow(itemID: items[0].id, position: (index: 0, count: 2))
        // Observation delivers on the next turn of the main actor.
        try await Task.sleep(for: .milliseconds(50))
        try await settle(model)

        #expect(model.currentItemID == items[0].id)
        #expect(model.positionText == "1 of 2")
        #expect(session.analysis.existing.contains { $0.tag.name == "Mike Jones" })
        #expect(!session.isAnalyzing)
    }

    @Test func applyingGoesThroughTheSessionHookAndCountsThePass() async throws {
        let (session, items, taper) = try await makeSession()
        var applied: [String] = []
        session.apply = { applied.append($0.name) }
        let model = TagAnalysisModel(session: session)
        session.playerDidShow(itemID: items[0].id, position: nil)
        try await Task.sleep(for: .milliseconds(50))
        try await settle(model)

        let mike = try #require(session.analysis.existing.first?.tag)
        model.applyNow(mike)
        try await settle(model)
        model.applyNew(value: "New Person", categoryID: taper.id)
        try await settle(model)

        #expect(applied == ["Mike Jones", "New Person"])
        #expect(model.tagsAppliedThisPass == 2)
        let names = try session.library.vocabulary().flatMap(\.tags).map(\.name)
        #expect(names.contains("New Person"))
    }

    @Test func movingToAnotherItemCountsAVisitAndClearsTheSelection() async throws {
        let (session, items, _) = try await makeSession()
        let model = TagAnalysisModel(session: session)
        session.playerDidShow(itemID: items[0].id, position: nil)
        try await Task.sleep(for: .milliseconds(50))
        try await settle(model)
        model.select(model.allRows.first?.id)
        model.searchText = "mike"

        session.playerDidShow(itemID: items[1].id, position: nil)
        try await Task.sleep(for: .milliseconds(50))
        try await settle(model)

        #expect(model.videosVisitedThisPass == 2)
        #expect(model.selectedCandidateID == nil)
        #expect(model.searchText == "")
        #expect(model.currentItemID == items[1].id)
    }

    @Test func closingClearsTheSessionsHalf() async throws {
        let (session, items, _) = try await makeSession()
        let model = TagAnalysisModel(session: session)
        session.playerDidShow(itemID: items[0].id, position: nil)
        try await Task.sleep(for: .milliseconds(50))
        try await settle(model)

        model.close()
        #expect(!session.companionIsOpen)
        #expect(session.analysis == .empty)
    }
}
```

- [ ] **Step 2: Run to confirm the failure**

Run: `swift build --build-tests 2>&1 | grep -E "error:" | head -3`
Expected: errors about `init(session:)` / `positionText` not existing.

- [ ] **Step 3: Rewrite the model**

Replace the whole of `Sources/SightsAndSoundsApp/TagAnalysis/TagAnalysisModel.swift` with the following. Everything kept from the old file is kept verbatim (rules, aliases, rows, filters, sweeps); the queue, preview, basket and search index are gone.

```swift
import Foundation
import GRDB
import Observation
import SightsAndSoundsKit

/// The companion window's state: the analysis of whatever the followed
/// player is showing, and the filters over it. It does not own a video
/// or a queue — the session says which item, and the player owns the
/// walk. Accepting applies at once through the session's hook, so the
/// player's panel refreshes on the same call.
@Observable
@MainActor
final class TagAnalysisModel {

    let session: TagAnalysisSession
    var library: LibraryDatabase { session.library }
    var libraryID: UUID { session.libraryID }

    private(set) var analysis: ItemAnalysis = .empty
    private(set) var rules: [RuleEngine.Rule] = []
    private(set) var categories: [TagCategory] = []
    private(set) var isLoading = false
    private(set) var loadError: String?

    /// What this pass has done so far — a pass being the life of this
    /// window over whatever the player walked through.
    private(set) var tagsAppliedThisPass = 0
    private(set) var videosVisitedThisPass = 1

    var searchText = ""
    var selectedCandidateID: AnalysisCandidate.ID?

    /// The rail's Reader I/O page replaces the candidate table while on
    /// — a sibling view of the same video.
    var showingReaderIO = false

    /// Left-rail filters — the comp's EVIDENCE SOURCES and STATUS blocks.
    var readerFilter: String?
    var statusFilter: StatusFilter = .undecided

    enum StatusFilter: String, CaseIterable {
        case undecided, applied, ignored, everything

        var label: String {
            switch self {
            case .undecided: "Undecided"
            case .applied: "Applied"
            case .ignored: "Ignored"
            case .everything: "Everything"
            }
        }
    }

    /// The item the reload in flight (or the last one) was for — the
    /// guard that drops results for an item the player has left.
    private var loadedItemID: UUID?

    init(session: TagAnalysisSession) {
        self.session = session
        session.companionDidOpen()
        observeSession()
        if session.itemID != nil { reload() }
    }

    // MARK: - Following the player

    var currentItemID: UUID? { session.itemID }
    var playerIsOpen: Bool { session.playerIsOpen }

    /// "3 of 41", or nil for a single item.
    var positionText: String? {
        guard let position = session.position else { return nil }
        return "\(position.index + 1) of \(position.count)"
    }

    /// One observation at a time, re-armed after each change lands.
    /// `onChange` fires before the new value is visible, so the work is
    /// hopped to the next main-actor turn.
    private func observeSession() {
        withObservationTracking {
            _ = session.itemID
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.itemChanged()
                self.observeSession()
            }
        }
    }

    /// The player moved on: stamp the departed video, count the visit,
    /// drop everything that pointed at its strings, and reload.
    private func itemChanged() {
        guard session.itemID != loadedItemID else { return }
        if loadedItemID != nil {
            markAnalyzed(loadedItemID)
            videosVisitedThisPass += 1
        }
        selectedCandidateID = nil
        searchText = ""
        analysis = .empty
        reload()
    }

    /// Stamp a video as analyzed, at the current analyzer version.
    /// Moving past without applying anything still counts — seeing the
    /// evidence and judging nothing tag-worthy IS an analysis.
    private func markAnalyzed(_ id: UUID?) {
        guard let id else { return }
        try? library.markAnalyzed(id)
    }

    /// The window is going away: the companion's half of the session
    /// clears and the shown video is stamped.
    func close() {
        markAnalyzed(loadedItemID)
        session.companionDidClose()
    }

    // MARK: - Derived

    var selectedCandidate: AnalysisCandidate? {
        (analysis.suggested + analysis.unmapped).first { $0.id == selectedCandidateID }
    }

    /// One row per string — the comp's single table. The suggestion
    /// column carries the classification instead of three separate
    /// sections: a rule mapping, an existing-tag hit, or nothing.
    struct TableRow: Identifiable {
        let candidate: AnalysisCandidate
        let findings: [ExistingTagFinding]
        var id: AnalysisCandidate.ID { candidate.id }
    }

    var allRows: [TableRow] {
        let findingsByText = Dictionary(grouping: analysis.existing, by: \.foundIn)
        return (analysis.suggested + analysis.unmapped).map {
            TableRow(candidate: $0, findings: findingsByText[$0.value] ?? [])
        }
    }

    var visibleRows: [TableRow] {
        allRows.filter { matches($0) }
    }

    /// The inspector's right column: everything this reader's strings
    /// became, whichever bucket they landed in.
    func candidates(fromReader readerID: String) -> [TableRow] {
        allRows.filter { row in
            row.candidate.origins.contains { $0.readerID == readerID }
        }
    }

    func count(reader: String?) -> Int {
        allRows.count { row in
            (reader == nil || row.candidate.origins.contains { $0.readerID == reader })
                && status(of: row) == .undecided
        }
    }

    func count(status: StatusFilter) -> Int {
        if status == .everything { return allRows.count }
        return allRows.count(where: { self.status(of: $0) == status })
    }

    /// Applied means a found tag is already on the video — the reload
    /// after an apply is what moves a row here.
    func status(of row: TableRow) -> StatusFilter {
        if row.candidate.suppressedByRule != nil { return .ignored }
        if !row.findings.isEmpty, row.findings.allSatisfy(\.alreadyApplied) { return .applied }
        return .undecided
    }

    private func matches(_ row: TableRow) -> Bool {
        if let readerFilter,
           !row.candidate.origins.contains(where: { $0.readerID == readerFilter })
        {
            return false
        }
        if statusFilter != .everything, status(of: row) != statusFilter { return false }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return row.candidate.value.localizedCaseInsensitiveContains(query)
            || (row.candidate.key?.localizedCaseInsensitiveContains(query) ?? false)
    }

    /// How many places in THIS video the string was found.
    func occurrenceCount(for candidate: AnalysisCandidate) -> Int {
        candidate.origins.count
    }

    func category(named name: String) -> TagCategory? {
        categories.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    // MARK: - Loading

    /// Everything the analysis needs, then the analysis itself off the
    /// main actor. Results for an item the player has since left are
    /// dropped, not shown.
    func reload() {
        guard let itemID = currentItemID else {
            analysis = .empty
            session.companionDidReload(.empty)
            return
        }
        loadedItemID = itemID
        isLoading = true
        session.companionWillReload()
        let library = library
        Task {
            do {
                let rules = try library.analysisRules()
                let categories = try library.vocabulary().map(\.category)
                let analysis = try await Task.detached(priority: .userInitiated) {
                    try library.analyzeItem(itemID, rules: rules)
                }.value
                guard itemID == self.currentItemID else { return }
                self.rules = rules
                self.categories = categories
                self.analysis = analysis
                self.session.companionDidReload(analysis)
                self.loadError = nil
            } catch {
                self.loadError = "\(error)"
                self.session.companionDidReload(.empty)
            }
            self.isLoading = false
        }
    }

    /// The sweep runs on the job runner; the model only tracks that one
    /// is in flight.
    func beginSweep() { isLoading = true }
    func finishSweep() { reload() }

    func select(_ id: AnalysisCandidate.ID?) {
        selectedCandidateID = id
    }

    // MARK: - Applying

    /// Apply an existing tag to the shown video, now, through the
    /// player's hook so its panel refreshes on the same call. The reload
    /// that follows moves the row to Applied.
    func applyNow(_ tag: Tag) {
        session.apply(tag)
        tagsAppliedThisPass += 1
        reload()
    }

    /// Create (or find by name) then apply — the decide pane's Assign.
    func applyNew(value: String, categoryID: UUID) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let tag = try library.ensureTag(named: trimmed, inCategory: categoryID)
            applyNow(tag)
        } catch {
            loadError = "\(error)"
        }
    }

    // MARK: - Decide actions that write rules or vocabulary

    /// The comp's "Ignore this key": never offer it again, reversible.
    /// Implemented as an authored ignore RULE — candidates become rules —
    /// so reversing it is deleting the rule, and the Ignored status
    /// filter is the list the comp promises.
    func ignoreRule(for candidate: AnalysisCandidate) {
        let matcher: RuleMatcher = candidate.key.flatMap { key in
            key.isEmpty ? nil : .keyEquals(key: key)
        } ?? .valueStartsWith(prefix: candidate.value)
        do {
            try library.saveAnalysisRule(
                RuleEngine.Rule(id: UUID(), matcher: matcher, actions: [.ignore]))
            reload()
        } catch {
            loadError = "\(error)"
        }
    }

    /// The comp's "Hide the prefix": a pathRootStartsWith + hidePrefix
    /// rule, so the never-useful leading token stops appearing.
    func hidePrefixRule(root: String) {
        let trimmed = root.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        do {
            try library.saveAnalysisRule(
                RuleEngine.Rule(
                    id: UUID(), matcher: .pathRootStartsWith(root: trimmed),
                    actions: [.hidePrefix]))
            reload()
        } catch {
            loadError = "\(error)"
        }
    }

    /// The comp's "Add as an alias": folds this spelling into an existing
    /// tag. Vocabulary, not tagging — it writes immediately, because an
    /// alias belongs to the library, not to this video.
    func addAlias(_ value: String, toTag tagID: UUID) {
        do {
            try library.addAlias(value.trimmingCharacters(in: .whitespacesAndNewlines), toTag: tagID)
            reload()
        } catch {
            loadError = "\(error)"
        }
    }
}
```

- [ ] **Step 4: Build just the model and the tests**

The view still references removed members, so the app target will not build yet. Run only: `swift build --build-tests 2>&1 | grep -E "error:" | grep -v TagAnalysisView | head`
Expected: no errors outside `TagAnalysisView.swift` (those are Task 4). If the view's errors block the test build, proceed to Task 4 and run this task's tests at the end of Task 4 instead.

- [ ] **Step 5: Commit the model (build may still be red until Task 4; commit anyway, the branch is squashed by review)**

Skip this commit if the hooks run the build. Otherwise:
```bash
git add Sources/SightsAndSoundsApp/TagAnalysis/TagAnalysisModel.swift Tests/SightsAndSoundsAppTests/TagAnalysisModelTests.swift
git rm -q Tests/SightsAndSoundsAppTests/TagAnalysisPreviewTests.swift
git commit -m "Tag analysis: the model follows the session instead of a queue"
```

---

### Task 4: The companion window

**Files:**
- Modify: `Sources/SightsAndSoundsApp/TagAnalysis/TagAnalysisView.swift`
- Modify: `Sources/SightsAndSoundsApp/Browse/AuxiliaryWindow.swift`

**Interfaces:**
- Consumes: `TagAnalysisModel(session:)`, `AppModel.analysisSession(for:)` (Tasks 1, 3).
- Produces: `struct TagAnalysisView: View { var sessionID: UUID? }`; `AuxWindowRequest.sessionID: UUID?`.

- [ ] **Step 1: The window request carries the session id**

In `AuxiliaryWindow.swift`, `AuxWindowRequest`, after `var title: String? = nil`:

```swift
    /// Tag Analysis only: the player session the companion follows.
    /// Optional so saved window state decodes; a missing or unknown id
    /// renders the companion's closed state.
    var sessionID: UUID? = nil
```

Update the doc comment on `itemIDs`/`startIndex`: replace "Tag Analysis only: where in `itemIDs` to start the walk." with "Unused since the companion followed a player session; kept so saved window state decodes."

In `content(_:)`, replace the `.tagAnalysis` case:

```swift
            case .tagAnalysis:
                TagAnalysisView(sessionID: request.sessionID)
```

- [ ] **Step 2: Rewrite the view's top level**

In `TagAnalysisView.swift`, replace the `TagAnalysisView` struct (from `struct TagAnalysisView: View {` to the closing brace before `// MARK: - Left rail`) with:

```swift
struct TagAnalysisView: View {
    @Environment(BrowseModel.self) private var browse
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    /// The player session to follow. nil, or an id the app no longer
    /// holds, is the closed state.
    var sessionID: UUID?
    @State private var model: TagAnalysisModel?
    @State private var rules: RulesTabModel?
    @State private var schemas: SchemasTabModel?
    @State private var mode: Mode = .candidates
    @FocusState private var focused: Bool
    /// The rail opens at its saved width; a drag records the new one and
    /// persists it once the drag settles.
    @State private var railWidth = AppSettingsStore.shared.current.tagAnalysisRailWidth
    @State private var railPersist: Task<Void, Never>?

    enum Mode: String, Hashable { case candidates, rules, schemas }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let model, let rules {
                if !model.playerIsOpen {
                    playerClosed
                } else {
                    HSplitView {
                        RailView(model: model)
                            .frame(minWidth: 210, idealWidth: railWidth, maxWidth: 900)
                            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width in
                                guard width > 0, Double(width) != railWidth else { return }
                                railWidth = Double(width)
                                railPersist?.cancel()
                                railPersist = Task {
                                    try? await Task.sleep(for: .milliseconds(400))
                                    guard !Task.isCancelled else { return }
                                    AppSettingsStore.shared.update { $0.tagAnalysisRailWidth = width }
                                }
                            }
                        switch mode {
                        case .candidates:
                            if model.showingReaderIO {
                                ReaderIOView(model: model)
                                    .frame(minWidth: 620)
                            } else {
                                CandidateTable(model: model)
                                    .frame(minWidth: 460)
                                DecidePane(model: model, onMakeRule: makeRule)
                                    .frame(minWidth: 300, idealWidth: 340, maxWidth: 440)
                            }
                        case .rules:
                            RulesTabView(model: rules)
                        case .schemas:
                            if let schemas { SchemasTabView(model: schemas) }
                        }
                    }
                }
            } else if sessionID == nil || app.analysisSession(for: sessionID!) == nil {
                playerClosed
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 1_100, minHeight: 620)
        .background(Theme.Surface.content)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        // SHIFT+arrows walk the PLAYER's queue from here — punching
        // through a focused text field as the player's do.
        .onKeyPress(phases: [.down, .repeat]) { press in
            guard let model else { return .ignored }
            if press.modifiers.contains(.shift),
               press.key == .leftArrow || press.key == .rightArrow
            {
                model.session.step(press.key == .leftArrow ? -1 : 1)
                return .handled
            }
            return .ignored
        }
        .task {
            guard model == nil, let sessionID, let session = app.analysisSession(for: sessionID)
            else { return }
            let made = TagAnalysisModel(session: session)
            model = made
            rules = RulesTabModel(library: session.library)
            schemas = SchemasTabModel(library: session.library)
            focused = true
            sweepCurrentIfNeeded(made)
        }
        .onChange(of: model?.currentItemID) { _, _ in
            if let model { sweepCurrentIfNeeded(model) }
        }
        .onDisappear {
            model?.close()
            if let sessionID { app.releaseAnalysisSessionIfFinished(sessionID) }
        }
    }

    /// The followed player is gone (or was never found): say so and
    /// offer the one useful action.
    private var playerClosed: some View {
        VStack(spacing: 12) {
            ContentUnavailableView(
                "The player this window follows has closed.",
                systemImage: "play.slash",
                description: Text("Open Tag Analysis again from a player window."))
            Button("Close") { dismiss() }
                .buttonStyle(PrimaryButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sweepCurrentIfNeeded(_ model: TagAnalysisModel) {
        guard let id = model.currentItemID,
              (try? browse.library.unsweptCount(in: [id])) ?? 0 > 0
        else { return }
        model.beginSweep()
        browse.sweepMetadata(itemIDs: [id]) { model.finishSweep() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ThemeSegmentedControl(
                selection: $mode,
                options: [(.candidates, "Candidates"), (.rules, "Rules"), (.schemas, "Schemas")],
                emphasis: .neutral)
            if let model {
                Text(headline(model))
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.Text.tertiary)
                if let position = model.positionText {
                    Text(position)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.Text.quaternary)
                        .help("The followed player's place in its queue — ⇧← ⇧→ walk it from here")
                }
            }
            Spacer()
            if let model {
                HStack(spacing: 6) {
                    Text("⌕").font(Theme.ui(12)).foregroundStyle(Theme.Text.quaternary)
                    TextField(
                        "Filter values and keys",
                        text: Binding(get: { model.searchText }, set: { model.searchText = $0 }))
                        .textFieldStyle(.plain)
                        .font(Theme.ui(Theme.TypeScale.body))
                        .foregroundStyle(Theme.Text.primary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(width: 240)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.control)
                        .fill(Theme.Surface.well)
                        .stroke(Theme.Border.standard, lineWidth: 1))

                Button("Scan On-Screen Text") {
                    guard let id = model.currentItemID else { return }
                    model.beginSweep()
                    browse.scanText(itemID: id) { model.finishSweep() }
                }
                .buttonStyle(SecondaryButtonStyle(compact: true))
                .disabled(model.isLoading || model.currentItemID == nil)
                .help("Read on-screen text with Vision — resumable; click again to scan further")
                Button("Rescan This Video") {
                    guard let id = model.currentItemID else { return }
                    try? browse.library.resetMetadataSweep(itemIDs: [id])
                    model.beginSweep()
                    browse.sweepMetadata(itemIDs: [id]) { model.finishSweep() }
                }
                .buttonStyle(SecondaryButtonStyle(compact: true))
                .disabled(model.isLoading || model.currentItemID == nil)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Theme.Surface.toolbar)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.Border.standard).frame(height: 1)
        }
    }

    private func headline(_ model: TagAnalysisModel) -> String {
        if model.isLoading { return "scanning…" }
        let strings = model.allRows.count
        let undecided = model.count(status: .undecided)
        return "\(strings) strings · \(undecided) undecided"
    }

    private func makeRule(key: String?, value: String) {
        guard let rules else { return }
        rules.makeRule(key: key, value: value)
        mode = .rules
    }
}
```

- [ ] **Step 3: Trim the rail**

In `RailView`:
- Remove the `@Environment(BrowseModel.self)` line if it becomes unused (it is used by nothing after the preview goes; delete it).
- Remove `@State private var previewCollapsed`, `@FocusState private var fieldFocus`, `private static let universalFocusID`.
- Body becomes:
  ```swift
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                sources
                readerIO
                status
                thisPass
            }
            .padding(12)
        }
        .background(Theme.Surface.sidebar)
    }
  ```
- Delete these whole sections, each from its `// MARK:` line to the line before the next `// MARK:`: `// MARK: Preview`, `// MARK: Universal field`, `// MARK: Applied tags`, `// MARK: Candidate tags`. Keep `// MARK: Filters` onward.
- In `statusHue`, replace `case .inBasket: Theme.Status.green` with `case .applied: Theme.Status.green`.
- Replace the whole `thisPass` computed property with:
  ```swift
    private var thisPass: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("This pass").modifier(Theme.sectionLabel())
            tally(model.tagsAppliedThisPass, "tags applied")
            tally(model.videosVisitedThisPass, "videos visited")
        }
    }
  ```
  and change the MARK above it to `// MARK: This pass`.

- [ ] **Step 4: The table row and decide pane apply at once**

In `CandidateTableRow`:
- `suggestionChip`: replace the first branch `if model.status(of: row) == .inBasket { chip("In basket", ...) } else if let category ...` with `if let category = candidate.category { ... }` (drop the basket branch entirely; the rest of the chain stays).
- `quickAccept`:
  ```swift
    @ViewBuilder
    private var quickAccept: some View {
        if model.status(of: row) == .undecided {
            if let name = candidate.category, let category = model.category(named: name) {
                plusButton { model.applyNew(value: candidate.value, categoryID: category.id) }
            } else if let finding = row.findings.first(where: { !$0.alreadyApplied }) {
                plusButton { model.applyNow(finding.tag) }
            }
        }
    }
  ```
- `plusButton` help text: `"Take the suggestion — applies to the video now"`.

In `DecidePane.primaryButton`:
```swift
        case .assign:
            Button("Apply") {
                guard let categoryID else { return }
                model.applyNew(value: editedValue, categoryID: categoryID)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(
                categoryID == nil
                    || editedValue.trimmingCharacters(in: .whitespaces).isEmpty)
        case .applyExisting:
            Button("Apply Existing") {
                if let target { model.applyNow(target.tag) }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(target == nil)
```
(The alias, ignore and hidePrefix cases are unchanged.)

In `decideBlock`, the `.assign` radio note becomes `"Creates the tag if needed and applies it to this video."`

- [ ] **Step 5: Remove the queue strip, the numpad monitor and the preview transport**

Delete these whole sections from `TagAnalysisView.swift`, each from its `// MARK:` line to the line before the next `// MARK:` (or end of file): `// MARK: - Queue strip` (both `QueueStrip` and `QueueThumb`), `// MARK: - Numpad monitor`, `// MARK: - Preview transport`. Keep `// MARK: - Reader chips`.

Then remove the now-unused imports if any (`AVFoundation` is not imported here; check `AppKit` is still needed for `NSWorkspace` elsewhere in the file — keep whatever the build needs).

- [ ] **Step 6: Build, then run the Task 3 and Task 1 tests**

Run: `swift build 2>&1 | grep -E "warning:|error:|Build complete"`
Expected: `Build complete!`, zero warnings. Fix any leftover reference to `model.queue`, `model.index`, `previewPlayer`, `basket`, `stage(`, `commitBasket`, `universalFocusRequests`, `handlePreviewKey` by deleting the referencing code (all of it belongs to removed features).

Run: `swift test --filter "TagAnalysis" 2>&1 | grep -E "Test run with|✘"`
Expected: all TagAnalysisSessionTests and TagAnalysisModelTests pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/SightsAndSoundsApp/TagAnalysis/TagAnalysisView.swift Sources/SightsAndSoundsApp/Browse/AuxiliaryWindow.swift Sources/SightsAndSoundsApp/TagAnalysis/TagAnalysisModel.swift Tests/SightsAndSoundsAppTests
git commit -m "Tag analysis: the window follows a player session, and accepting applies at once"
```

---

### Task 5: Entry points

**Files:**
- Modify: `Sources/SightsAndSoundsApp/Player/PlayerView.swift` (`PlayerView` body after `.task`; `PlayerContent.toolbarItems` menu)
- Modify: `Sources/SightsAndSoundsApp/Browse/BrowseModel.swift` (after `var playerRequest`)
- Modify: `Sources/SightsAndSoundsApp/Browse/ItemGridView.swift` (the "Tag Analysis" button ~line 218)
- Modify: `Sources/SightsAndSoundsApp/Browse/LibraryWindowView.swift` (`openAux`)
- Modify: `Sources/SightsAndSoundsApp/Browse/CommandPalette.swift` (`aux(_:)`)
- Modify: `Sources/SightsAndSoundsApp/SightsAndSoundsApp.swift` (`ViewMenuCommands.aux`)

**Interfaces:**
- Consumes: `PlayerModel.analysisSession(registeringIn:)` (Task 2), `AuxWindowRequest.sessionID` (Task 4).
- Produces: `BrowseModel.pendingAnalysisOpen: Bool`; `BrowseModel.openPlayerForAnalysis(at itemID: UUID?)`.

- [ ] **Step 1: The browse model can open the player with the companion pending**

In `BrowseModel`, after `var playerRequest: PlayerRequest?`:

```swift
    /// Set by the browse entry points for Tag Analysis: the player is
    /// opened first, and the player view opens the companion as soon as
    /// its model exists, then clears this. The companion needs a player
    /// to follow; a grid has none.
    var pendingAnalysisOpen = false

    /// Open the player at `itemID` (or the first visible item) with the
    /// companion pending. Nothing to play means nothing to analyse, and
    /// the caller's control stays inert.
    func openPlayerForAnalysis(at itemID: UUID? = nil) {
        let online = visibleItems.filter(isOnline)
        guard let first = itemID.flatMap({ id in online.first { $0.id == id } }) ?? online.first
        else { return }
        pendingAnalysisOpen = true
        playerRequest = PlayerRequest(
            libraryID: libraryID, itemID: first.id, playlist: visibleItems.map(\.id))
    }
```

- [ ] **Step 2: The player opens the companion**

In `PlayerView` (the outer struct), add `@Environment(\.openWindow) private var openWindow` beside the other environment values, and after the `.task { ... }` that creates the model add:

```swift
        // A browse entry point asked for Tag Analysis: the player is up
        // now, so the companion can follow it.
        .onChange(of: model == nil) { _, absent in
            guard !absent, browse.pendingAnalysisOpen, let model else { return }
            browse.pendingAnalysisOpen = false
            openTagAnalysis(for: model)
        }
```

and a helper on `PlayerView`:

```swift
    /// One companion per player session: the request is keyed on the
    /// session id, so opening twice brings the same window forward.
    private func openTagAnalysis(for model: PlayerModel) {
        let session = model.analysisSession(registeringIn: app)
        openWindow(
            id: "aux",
            value: AuxWindowRequest(
                libraryID: model.libraryID, kind: .tagAnalysis,
                title: "Tag Analysis", sessionID: session.id))
    }
```

In `PlayerContent`, add `@Environment(AppModel.self) private var app` and replace the toolbar menu's Tag Analysis button (the `if let item = model.item { Button("Tag Analysis" ...) }` block) with a toolbar item of its own placed before the menu `ToolbarItem`:

```swift
        ToolbarItem {
            Button("Tag Analysis", systemImage: "sparkle.magnifyingglass") {
                let session = model.analysisSession(registeringIn: app)
                openWindow(
                    id: "aux",
                    value: AuxWindowRequest(
                        libraryID: model.libraryID, kind: .tagAnalysis,
                        title: "Tag Analysis", sessionID: session.id))
            }
            .help("Open the Tag Analysis companion beside this player")
        }
```

Delete the old menu entry and the `Divider()` above it if it leaves two dividers adjacent.

- [ ] **Step 3: The browse entry points open the player first**

`ItemGridView.swift`, the tile's "Tag Analysis" button body becomes:
```swift
            model.openPlayerForAnalysis(at: item.id)
```
(Remove the `queue`/`openWindow` lines; keep the button label.)

`LibraryWindowView.swift`, `openAux(_:)`: replace the `if kind == .tagAnalysis { ... return }` block with:
```swift
        if kind == .tagAnalysis {
            model.openPlayerForAnalysis()
            return
        }
```

`CommandPalette.swift`, `aux(_:)`:
```swift
    private func aux(_ kind: AuxWindowRequest.Kind) {
        if kind == .tagAnalysis {
            model.openPlayerForAnalysis()
            return
        }
        openWindow(id: "aux", value: AuxWindowRequest(libraryID: model.libraryID, kind: kind))
    }
```

`SightsAndSoundsApp.swift`, `ViewMenuCommands.aux(_:_:key:)`:
```swift
        Button(title) {
            guard let focusedLibraryID else { return }
            if kind == .tagAnalysis {
                focusedBrowse?.openPlayerForAnalysis()
                return
            }
            openWindow(
                id: "aux",
                value: AuxWindowRequest(libraryID: focusedLibraryID, kind: kind))
        }
```

- [ ] **Step 4: Build and launch**

Run: `swift build 2>&1 | grep -E "warning:|error:|Build complete"` — zero warnings.
Run: `./scripts/make-app-bundle.sh && open dist/SightsAndSounds.app && sleep 5 && pgrep -f sights-and-sounds-claude/dist/SightsAndSounds.app && pkill -f sights-and-sounds-claude/dist/SightsAndSounds.app`
Expected: a pid, then quit.

- [ ] **Step 5: Commit**

```bash
git add Sources/SightsAndSoundsApp/Player/PlayerView.swift Sources/SightsAndSoundsApp/Browse/BrowseModel.swift Sources/SightsAndSoundsApp/Browse/ItemGridView.swift Sources/SightsAndSoundsApp/Browse/LibraryWindowView.swift Sources/SightsAndSoundsApp/Browse/CommandPalette.swift Sources/SightsAndSoundsApp/SightsAndSoundsApp.swift
git commit -m "Tag analysis: every entry point opens a player first, and the player opens the companion"
```

---

### Task 6: Spec, verification, PR

**Files:**
- Modify: `docs/design/14-tag-analysis.md` (Decisions and Layout)

- [ ] **Step 1: Rewrite the spec's Layout paragraph and add the decision**

Add to `## Decisions` as item 10:

```
10. **A companion, not a second player.** Tag Analysis follows one player window through a
    shared session: the video plays there, tagging happens there, and this window shows the
    evidence and the decisions for whatever that player is showing. Accepting applies at once —
    no basket, no commit step; the player's next/previous just moves on. With the companion
    closed, no scan runs and the player's Tag Analysis Results field is dimmed. Design:
    `docs/superpowers/specs/2026-09-08-tag-analysis-companion-design.md`.
```

Replace the whole `**Candidates.**` paragraph under `## Layout` with:

```
**Candidates.** Header: mode control, mono headline, the followed player's position (`3 of 41`;
⇧← ⇧→ walk it from here), the filter field, Scan On-Screen Text, Rescan This Video. Left rail
(draggable, 210–900 pt, kept between launches): evidence sources, Reader I/O, status filter
(Undecided · Applied · Ignored · Everything), This pass (`tags applied` · `videos visited`).
Centre: candidate rows — the string, key, source chips, mono count, suggestion chip, and ⊕ to
take the suggestion now. Selecting one fills the decide pane: the string large, where it came
from, the decision radios with a category picker for Assign, **Apply** / **Apply Existing**,
and **Make a rule from this**. Below, the evidence strip — one still per origin, OCR stills
seeking to the read timestamp. No preview, no queue strip: the player has both. Player gone:
`The player this window follows has closed.` and a Close button.
```

- [ ] **Step 2: Full verification**

Run, in this order, and paste the outputs into the PR:
```
swift build 2>&1 | grep -E "warning:|error:|Build complete"
swift test 2>&1 | grep -E "Test run with|✘"
scripts/check-no-private-data.sh; scripts/check-terminology.sh
./scripts/make-app-bundle.sh && open dist/SightsAndSounds.app && sleep 5 && pgrep -f sights-and-sounds-claude/dist/SightsAndSounds.app; pkill -f sights-and-sounds-claude/dist/SightsAndSounds.app
```
Expected: zero warnings; all tests pass (count goes down by the 2 removed preview tests and up by the 10 new ones); both guards clean; the bundle alive then quit.

- [ ] **Step 3: Commit and push**

```bash
git add docs/design/14-tag-analysis.md
git commit -m "Tag analysis spec: the window is a companion to the player"
git push -u origin feature/tag-analysis-companion
```

- [ ] **Step 4: Open the PR** through the `github-putty` MCP server against `dev`, body sections Why / What (per file) / Verification (the outputs) / After merging ("Rebuild and relaunch. Open a video, click Tag Analysis in the player toolbar; move the window aside; ⇧→ in either window advances both. Note the results field in the player arrives in the next PR."). Report the URL and stop.
