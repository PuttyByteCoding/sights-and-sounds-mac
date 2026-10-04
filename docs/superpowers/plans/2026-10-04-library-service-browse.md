# Library Service, Browse First — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Put `BrowseModel` behind a `LibraryService` protocol in the Kit, answered locally by `LocalLibraryService`, with no change in behaviour.

**Architecture:** One protocol, composed of one sub-protocol per group of operations (`BrowseReading`, `BrowseListing`, `BrowseWriting`, `JobRequesting`). Every operation is `async throws` and takes and returns `Codable` values, because the same protocol will later be answered by another Mac. `LocalLibraryService` wraps `LibraryDatabase`, `JobRunner` and `FileAccess` and runs the code `BrowseModel` runs today; the raw SQL in `BrowseModel` moves into it.

**Tech Stack:** Swift 6 (tools 6.0, strict concurrency), SwiftPM, GRDB 7, swift-testing. Targets `SightsAndSoundsKit` and `SightsAndSoundsApp`.

**Spec:** `docs/superpowers/specs/2026-10-03-remote-library-design.md` (section 1, and steps 1 of "Order of work"). This plan covers Browse only. The player and each auxiliary window get their own plans.

## Global Constraints

- Behaviour-neutral: every existing test passes unchanged after every task, except where a task says a `BrowseModel` method became `async`.
- No GRDB type in any `LibraryService` signature. Inputs and results are `Codable`, `Equatable` and `Sendable`.
- Every operation is `async throws`.
- New Kit code goes in `Sources/SightsAndSoundsKit/Service/`. The Kit stays portable: `./scripts/check-kit-portable.sh` must pass.
- One task is one pull request against `dev`, branched from `origin/dev`, touching no file another open pull request touches.
- Before each push: `./scripts/check-build-warnings.sh` (no warnings), `swift test` (both suites, counts reported), `./scripts/check-terminology.sh`, `./scripts/check-no-private-data.sh`, `./scripts/check-kit-portable.sh`.
- Fixtures and test data are synthetic. Test folders live under the temporary directory and are removed.
- A new migration is not expected. If one is added, its name goes in `Tests/SightsAndSoundsKitTests/ExpectedMigrations.swift`.

## Review Focus

What the spec implies and a person would trip on, most likely first. Each has its test in the task named.

1. **Two actions in quick succession, now that writes are asynchronous** (favourite toggled twice before the first lands): both apply, in the order pressed. Task 3, `twoTogglesInARowLandInOrder`.
2. **A write that fails**: the reason still appears on the window's error line, and a selection is kept, not cleared, when its action failed. Task 3, `aFailedWriteSaysSoAndKeepsTheSelection`.
3. **One sidebar answer failing** (later: the host unreachable for one request): the other parts still load, what was on screen stays, and the error line names the part. Task 2, `oneFailedPartLeavesTheOthersLoaded`.
4. **A slow answer arriving after a newer one**: the older listing must not replace the newer. Task 2, `aSlowOlderListingDoesNotReplaceANewerOne`.
5. **A window closing**: its change stream ends and the hub subscription is released, not left feeding a model that is gone. Task 2, `closingTheWindowEndsItsSubscription`.

One statement in the spec is corrected here: section "Risks" says a listing is "one request per page of items, as it is one query today". Today a listing is one query for **every** matching item. `BrowseListing` keeps that shape, since this plan may not change behaviour; paging belongs to the remote plan and will change `ListingRequest`, not the windows.

## Files

| File | Responsibility |
| --- | --- |
| `Sources/SightsAndSoundsKit/Service/LibraryService.swift` | The protocol and the change stream. |
| `Sources/SightsAndSoundsKit/Service/BrowseReading.swift` | Sidebar reads and their value types. |
| `Sources/SightsAndSoundsKit/Service/BrowseListing.swift` | The listing request and answer; `TagPill`. |
| `Sources/SightsAndSoundsKit/Service/BrowseWriting.swift` | Browse's writes. |
| `Sources/SightsAndSoundsKit/Service/JobRequesting.swift` | `JobRequest`, `JobWait`. |
| `Sources/SightsAndSoundsKit/Service/LocalLibraryService.swift` | The local implementation; one extension file per group once it passes about 300 lines. |
| `Sources/SightsAndSoundsApp/Browse/BrowseModel.swift` | Loses its database and runner calls group by group. |
| `Tests/SightsAndSoundsKitTests/LocalLibraryService*Tests.swift` | One suite per group, against an in-memory library. |
| `Tests/SightsAndSoundsAppTests/StubLibraryService.swift` | A service whose operations can be made to fail or wait. |
| `scripts/check-service-boundary.sh`, `scripts/service-boundary-baseline.txt` | The ratchet: the app's direct database use may only go down. |

Not in this plan, and still on `model.library` when it is done: `resolvedFileURL` and `fileResolver` (they return a local path; they move with the player, where a remote library gives a relay URL instead), `library.info()` for the window's name (moves with `AppModel`), and every auxiliary window's own reads.

---

### Task 1: The protocol and the sidebar's reads

Branch `feature/library-service-browse-reads`.

**Files:**
- Create: `Sources/SightsAndSoundsKit/Service/LibraryService.swift`, `BrowseReading.swift`, `LocalLibraryService.swift`
- Modify: `Sources/SightsAndSoundsKit/Filtering/FolderTree.swift` (`FolderNode: Codable`), `Filtering/BrowseCounts.swift` (`BrowseCounts: Codable`), `Filtering/MediaKinds.swift` (`Codable` through `init(_:)`), `Operations/TileMenuFacts.swift` (`SnapshotRef: Codable`)
- Modify: `Sources/SightsAndSoundsApp/Browse/BrowseModel.swift` (`refresh(_:)`, `refreshSavedFilterCounts()`, `watchThumbnailQueue()`, the change subscription; `CategoryTags` and `ThumbnailQueueStatus` leave for the Kit)
- Test: `Tests/SightsAndSoundsKitTests/LocalLibraryServiceBrowseTests.swift`

**Interfaces:**
- Consumes: `LibraryDatabase.sources()`, `vocabulary()`, `folderCounts(kinds:sourceID:)`, `browseCounts(kinds:)`, `pendingCandidates()`, `savedFilters()`, `mediaItemCount(matching:kinds:)`, `itemIDsWithHideBlocks()`, `recentSnapshotRefs(perItem:)`, `changes.subscribe(_:)`.
- Produces:

```swift
public protocol LibraryService: BrowseReading {
    func changes() -> AsyncStream<LibraryChange>
}

public protocol BrowseReading: Sendable {
    func sourceStates() async throws -> [SourceState]
    func browseVocabulary() async throws -> BrowseVocabulary
    func sidebarCounts(kinds: MediaKinds) async throws -> SidebarCounts
    func pendingDuplicateCount() async throws -> Int
    func savedFilters() async throws -> [SavedFilter]
    func savedFilterCounts(kinds: MediaKinds) async throws -> [UUID: Int]
    func tileMenuFacts(snapshotsPerItem: Int) async throws -> TileMenuFacts
    func thumbnailQueueStatus() async throws -> ThumbnailQueueStatus?
}

public struct SourceState: Codable, Equatable, Sendable, Identifiable { public var source: Source; public var isOnline: Bool }
public struct CategoryTags: Codable, Equatable, Sendable, Identifiable { public let category: TagCategory; public let tags: [Tag] }
public struct BrowseVocabulary: Codable, Equatable, Sendable { public var categories: [CategoryTags]; public var aliases: [UUID: [String]] }
public struct SidebarCounts: Codable, Equatable, Sendable { public var trees: [UUID: [FolderNode]]; public var counts: BrowseCounts }
public struct TileMenuFacts: Codable, Equatable, Sendable { public var hideBlockItemIDs: Set<UUID>; public var snapshotRefs: [UUID: [SnapshotRef]] }
public struct ThumbnailQueueStatus: Codable, Equatable, Sendable { public var current: Int; public var total: Int?; public var failed: Int }

public final class LocalLibraryService: LibraryService {
    public init(library: LibraryDatabase, runner: JobRunner, fileAccess: any FileAccess = LiveFileAccess())
}
```

`BrowseModel` gains `let service: any LibraryService`, built in its initialiser from the library and runner it is given.

- [ ] **Step 1: Write the failing tests.** `LocalLibraryServiceBrowseTests`: a fixture library with an online, an unmounted and a disabled source, a visible and a hidden-from-browse category, a tag with an alias, and three items in two folders. Ten tests: `sourcesComeWithWhetherTheirFilesAreReachableHere`, `theBrowseVocabularyLeavesOutCategoriesHiddenFromBrowse`, `sidebarCountsCarryATreePerEnabledSourceAndTheLibraryCounts`, `savedFiltersAreCountedUnderTheKindsShown`, `pendingDuplicatesAreCounted`, `tileMenuFactsAreTheHideBlocksAndTheRecentSnapshots`, `theThumbnailQueueIsReportedOnlyWhileASweepIsPending`, `aWriteAnywhereReachesTheChangeStream`, `everyAnswerSurvivesEncodingAndDecoding`, `decodedKindsAreNeverEmpty`. Each compares the service's answer with what the `LibraryDatabase` call it replaces returns.
- [ ] **Step 2: Run them.** `swift test --filter LocalLibraryServiceBrowseTests`. Expected: does not compile, `LocalLibraryService` is not defined.
- [ ] **Step 3: Write the protocol, the value types and `LocalLibraryService`.** Each method is the code now in `BrowseModel.refresh(_:)`, `refreshSavedFilterCounts()` and `thumbnailQueueStatus(in:)`, moved. `changes()` wraps the hub: the subscription is made inside the `AsyncStream` builder (so it exists before the caller's first `await`) and cancelled in `onTermination`.
- [ ] **Step 4: Run them.** Expected: 10 pass.
- [ ] **Step 5: Move `BrowseModel` onto the service** for those reads, and read the change stream in a task held by a small bag whose `deinit` cancels it (the pattern `ObserverBag` already uses).
- [ ] **Step 6: Verify and commit.** The five commands in Global Constraints. Commit `Library service: the Browse sidebar reads through it`.

### Task 2: The listing, and a service that can be made to fail

Branch `feature/library-service-browse-listing`.

**Files:**
- Create: `Sources/SightsAndSoundsKit/Service/BrowseListing.swift`
- Modify: `Sources/SightsAndSoundsKit/Service/LibraryService.swift` (compose `BrowseListing`), `LocalLibraryService.swift`, `Sources/SightsAndSoundsKit/Filtering/MediaFilter.swift` (`MediaOrdering: Codable`)
- Modify: `Sources/SightsAndSoundsApp/Browse/TileCard.swift` (`TagPill` leaves for the Kit), `BrowseModel.swift` (`refreshItems()`; `ListingPayload` goes; the initialiser takes an optional service)
- Create: `Tests/SightsAndSoundsKitTests/LocalLibraryServiceListingTests.swift`, `Tests/SightsAndSoundsAppTests/StubLibraryService.swift`, `Tests/SightsAndSoundsAppTests/BrowseModelServiceTests.swift`

**Interfaces:**
- Consumes: Task 1's `LibraryService`, `TileMenuFacts`, `LocalLibraryService`.
- Produces:

```swift
public protocol BrowseListing: Sendable {
    func listing(_ request: ListingRequest) async throws -> BrowseListingAnswer
}

public struct ListingRequest: Codable, Equatable, Sendable {
    public var filter: MediaFilter
    public var kinds: MediaKinds
    public var ordering: MediaOrdering
    /// Tag pills and missing categories per item: only when tiles show them.
    public var includesTagData: Bool
    /// Which items are in a pending duplicate pair: only when tiles badge it.
    public var includesDuplicateData: Bool
    public var snapshotsPerItem: Int
    public init(filter: MediaFilter, kinds: MediaKinds, ordering: MediaOrdering,
                includesTagData: Bool, includesDuplicateData: Bool, snapshotsPerItem: Int)
}

public struct BrowseListingAnswer: Codable, Equatable, Sendable {
    public var items: [MediaItem]
    public var tags: [UUID: [TagPill]]
    public var missingCategories: [UUID: [String]]
    public var duplicateIDs: Set<UUID>
    public var filteredTagCounts: [UUID: Int]
    public var filteredMissingCounts: [UUID: Int]
    public var menuFacts: TileMenuFacts
}

public struct TagPill: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID; public var name: String; public var categoryID: UUID
    public var categoryName: String; public var colorIndex: Int
    public init(id: UUID, name: String, categoryID: UUID, categoryName: String, colorIndex: Int)
}

public protocol LibraryService: BrowseReading, BrowseListing { … }
```

`BrowseModel.init(libraryID:library:runner:fileAccess:service:onWorkFinished:)` gains `service: (any LibraryService)? = nil`; nil builds the local one as before.

- [ ] **Step 1: Write the failing Kit tests.**

```swift
@Suite struct LocalLibraryServiceListingTests {
    // Fixture: categories Band (sortOrder 0) and Venue (sortOrder 1); tags
    // Band▸Zed, Band▸Alpha, Venue▸Hall; items a.mp4 (Zed, Alpha, Hall),
    // b.mp4 (Alpha), c.mp4 (no tags); one pending DuplicateCandidate(a, b,
    // source: .contentHash).

    @Test func theListingIsTheItemsTheDatabaseListsInTheOrderAsked() async throws {
        let answer = try await f.service.listing(f.request())
        #expect(answer.items == (try f.library.mediaItems(
            matching: MediaFilter(), kinds: .video, orderedBy: .relativePath)))
        #expect(answer.filteredTagCounts == (try f.library.filteredTagCounts(kinds: .video, filter: MediaFilter())))
        #expect(answer.filteredMissingCounts == (try f.library.filteredMissingCategoryCounts(kinds: .video, filter: MediaFilter())))
        #expect(answer.menuFacts == (try await f.service.tileMenuFacts(snapshotsPerItem: 10)))
    }

    @Test func pillsAreInCategoryOrderThenByName() async throws {
        let answer = try await f.service.listing(f.request(tags: true))
        #expect(answer.tags[f.a.id]?.map(\.name) == ["Alpha", "Zed", "Hall"])
        #expect(answer.missingCategories[f.b.id] == ["Venue"])
        #expect(answer.missingCategories[f.c.id] == ["Band", "Venue"])
    }

    @Test func tagAndDuplicateDataAreLeftOutUnlessAskedFor() async throws {
        let bare = try await f.service.listing(f.request())
        #expect(bare.tags.isEmpty && bare.missingCategories.isEmpty && bare.duplicateIDs.isEmpty)
        let full = try await f.service.listing(f.request(tags: true, duplicates: true))
        #expect(full.duplicateIDs == [f.a.id, f.b.id])
    }

    @Test func theAnswerSurvivesEncodingAndDecoding() async throws {
        let answer = try await f.service.listing(f.request(tags: true, duplicates: true))
        let decoded = try JSONDecoder().decode(BrowseListingAnswer.self, from: JSONEncoder().encode(answer))
        #expect(decoded == answer)
        for ordering: MediaOrdering in [.relativePath, .fileName, .fieldValue(UUID(), ascending: false),
                                       .fileSize(ascending: true), .duration(ascending: false), .fullPath, .random(seed: 7)] {
            #expect(try JSONDecoder().decode(MediaOrdering.self, from: JSONEncoder().encode(ordering)) == ordering)
        }
    }
}
```

- [ ] **Step 2: Run them.** `swift test --filter LocalLibraryServiceListingTests`. Expected: does not compile, `ListingRequest` is not defined.
- [ ] **Step 3: Implement `listing(_:)`** in `LocalLibraryService` by moving the body of the detached task in `BrowseModel.refreshItems()` (from `library.mediaItems(matching:…)` to the duplicate ids), including the `SELECT mediaItemID, tagID FROM mediaItemTag` read and the timing line logged to `AppLog` at debug level. Add `Codable` to `MediaOrdering`. Move `TagPill` to the Kit with a public initialiser.
- [ ] **Step 4: Run them.** Expected: 4 pass.
- [ ] **Step 5: Write `StubLibraryService`** in the app tests: it wraps a `LocalLibraryService`, forwards every operation, and before forwarding calls `gate(#function)`, which throws `StubLibraryService.Failure(name)` if the test called `fail(name)`, and sleeps if the test called `delay(name, by:)` (first call only). State sits behind an `NSLock`.
- [ ] **Step 6: Write the failing app tests** in `BrowseModelServiceTests` (`@MainActor`, each with a `waitUntil` like `BrowseSelectionTests`):

```swift
@Test func oneFailedPartLeavesTheOthersLoaded() async throws {
    stub.fail("savedFilters()")
    let model = BrowseModel(libraryID: UUID(), library: library, runner: runner, service: stub)
    try await waitUntil { model.items.count == 3 && model.sources.count == 1 }
    #expect(model.vocabulary.map(\.category.name) == ["Band"])
    #expect(model.errorMessage?.contains("saved filters") == true)
    #expect(model.listingError == nil)
}

@Test func aSlowOlderListingDoesNotReplaceANewerOne() async throws {
    let model = BrowseModel(libraryID: UUID(), library: library, runner: runner, service: stub)
    try await waitUntil { model.items.count == 3 }
    stub.delay("listing(_:)", by: .milliseconds(400))      // the next listing is slow
    model.filter.searchText = "alpha"                       // slow: would list 1
    model.filter.searchText = ""                            // fast: lists 3
    try await Task.sleep(for: .milliseconds(700))
    #expect(model.items.count == 3)
}

@Test func closingTheWindowEndsItsSubscription() async throws {
    var model: BrowseModel? = BrowseModel(libraryID: UUID(), library: library, runner: runner, service: stub)
    try await waitUntil { model?.items.count == 3 }
    #expect(stub.openChangeStreams == 1)
    model = nil
    try await waitUntil { stub.openChangeStreams == 0 }
}
```

`openChangeStreams` is counted by the stub: its `changes()` wraps the base stream in one that increments on creation and decrements in `onTermination`.

- [ ] **Step 7: Run them.** Expected: do not compile (`service:` parameter).
- [ ] **Step 8: Move `refreshItems()` onto `service.listing(_:)`**, add the `service:` parameter, delete `ListingPayload`.
- [ ] **Step 9: Run all tests, verify, commit** `Library service: the Browse listing reads through it`.

### Task 3: Browse's writes

Branch `feature/library-service-browse-writes`.

**Files:**
- Create: `Sources/SightsAndSoundsKit/Service/BrowseWriting.swift`; Modify: `LibraryService.swift`, `LocalLibraryService.swift`, `Sources/SightsAndSoundsKit/Organization/MoveService.swift` (`StagingFolder: Codable`)
- Modify: `Sources/SightsAndSoundsApp/Browse/BrowseModel.swift` and each caller of the methods that become `async`
- Create: `Tests/SightsAndSoundsKitTests/LocalLibraryServiceWritingTests.swift`; Modify: `Tests/SightsAndSoundsAppTests/BrowseModelServiceTests.swift`, `StubLibraryService.swift`

**Interfaces:**
- Consumes: Task 2's `StubLibraryService`, `BrowseModel.init(…service:…)`.
- Produces:

```swift
public protocol BrowseWriting: Sendable {
    func renameSource(_ id: UUID, to name: String) async throws
    func setSourceEnabled(_ id: UUID, _ enabled: Bool) async throws
    func addSource(named name: String, rootPath: String) async throws -> Source
    @discardableResult func saveFilter(named name: String, _ filter: MediaFilter) async throws -> SavedFilter
    func updateSavedFilter(_ id: UUID, to filter: MediaFilter) async throws
    func renameSavedFilter(_ id: UUID, to name: String) async throws
    func deleteSavedFilter(_ id: UUID) async throws
    func assignTag(_ tagID: UUID, to itemIDs: [UUID]) async throws
    func removeTag(_ tagID: UUID, from itemIDs: [UUID]) async throws
    func setFavorite(_ itemIDs: [UUID], _ isFavorite: Bool) async throws
    func setNeedsReview(_ itemIDs: [UUID], _ needsReview: Bool) async throws
    /// Moves each item into or out of a staging folder. One line per item
    /// that could not be moved; the others are moved.
    func setStaging(_ folder: StagingFolder, on: Bool, itemIDs: [UUID]) async throws -> [String]
}
```

In `BrowseModel`, these become `async` and keep their names: `renameSource(_:to:)`, `setSourceEnabled(_:_:)`, `addSource(at:) -> Source?`, `saveCurrentFilter(named:)`, `updateSavedFilter(_:)`, `renameSavedFilter(_:to:)`, `deleteSavedFilter(_:)`, `markSelectionReviewed()`, `applyTagToSelection(_:)`, `toggleSelectionFavorite()`, `removeTagFromSelection(_:)`. `setStaging(_:on:for:)` already starts a task and stays synchronous. A caller in a view wraps the call in `Task { await … }`; a caller that used the result at once (`ImportView.addSource`) awaits it.

Two deliberate tightenings, each with a test: `renameSource` and `setSourceEnabled` write the one column by id, where the app wrote back the whole `Source` row it had in memory; and the model's writes are queued on one serial task chain, so two actions land in the order pressed.

- [ ] **Step 1: Write the failing Kit tests.**

```swift
@Suite struct LocalLibraryServiceWritingTests {
    @Test func renamingASourceChangesOnlyItsName() async throws {
        try await f.library.writer.write { db in      // changed since the window read it
            try db.execute(sql: "UPDATE source SET enabled = 0 WHERE id = ?", arguments: [f.source.id])
        }
        try await f.service.renameSource(f.source.id, to: "  Shows  ")
        let row = try await f.library.writer.read { try Source.fetchOne($0, key: f.source.id) }
        #expect(row?.name == "Shows" && row?.enabled == false)
    }
    @Test func anEmptySourceNameIsRefused() async throws {
        await #expect(throws: ServiceError.emptyName) { try await f.service.renameSource(f.source.id, to: "   ") }
    }
    @Test func savedFiltersAreSavedUpdatedRenamedAndDeleted() async throws {
        let saved = try await f.service.saveFilter(named: "One", MediaFilter())
        var narrowed = MediaFilter(); narrowed.searchText = "a"
        try await f.service.updateSavedFilter(saved.id, to: narrowed)
        try await f.service.renameSavedFilter(saved.id, to: "Two")
        #expect(try f.library.savedFilters().map(\.name) == ["Two"])
        #expect(try f.library.savedFilters().first?.filter == narrowed)
        try await f.service.deleteSavedFilter(saved.id)
        #expect(try f.library.savedFilters().isEmpty)
    }
    @Test func aSingleSelectCategoryStillReplacesWhenTaggedThroughTheService() async throws {
        try await f.service.assignTag(f.yearA.id, to: [f.a.id, f.b.id])
        try await f.service.assignTag(f.yearB.id, to: [f.a.id])
        #expect(try f.tagIDs(of: f.a) == [f.yearB.id])
        #expect(try f.tagIDs(of: f.b) == [f.yearA.id])
        try await f.service.removeTag(f.yearA.id, from: [f.a.id, f.b.id])
        #expect(try f.tagIDs(of: f.b).isEmpty)
    }
    @Test func flagsAreSetForEveryItemNamed() async throws {
        try await f.service.setFavorite([f.a.id, f.b.id], true)
        try await f.service.setNeedsReview([f.a.id], false)
        let rows = try f.library.mediaItems(matching: MediaFilter(), kinds: .video)
        #expect(rows.filter(\.isFavorite).map(\.id).sorted() == [f.a.id, f.b.id].sorted())
    }
    @Test func stagingReportsTheItemsItCouldNotMoveAndMovesTheRest() async throws {
        // a.mp4 exists on disk, ghost.mp4 has a row and no file.
        let failures = try await f.service.setStaging(.toDelete, on: true, itemIDs: [f.a.id, f.ghost.id])
        #expect(failures.count == 1 && failures[0].hasPrefix("ghost.mp4"))
        #expect(try f.item(f.a.id).markedForDeletion)
    }
    @Test func addingASourceThatOverlapsOneIsRefused() async throws {
        await #expect(throws: SourceError.self) {
            try await f.service.addSource(named: "Again", rootPath: f.source.rootPath)
        }
    }
}
```

- [ ] **Step 2: Run them.** Expected: do not compile.
- [ ] **Step 3: Implement `BrowseWriting` in `LocalLibraryService`**, each method calling the `LibraryDatabase` method of the same name; `renameSource` trims and refuses an empty name by throwing `ServiceError.emptyName`, a new one-case error declared in `BrowseWriting.swift` (`public enum ServiceError: Error, Equatable, Sendable, CustomStringConvertible { case emptyName }`, described as "a name cannot be empty"), and returns without writing when the name is unchanged; the two source writes are `UPDATE source SET name = ? WHERE id = ?` and `UPDATE source SET enabled = ? WHERE id = ?`; `setStaging` is the loop now in `BrowseModel.setStaging`, with `fileName: error` lines.
- [ ] **Step 4: Run them.** Expected: 7 pass.
- [ ] **Step 5: Write the failing app tests** (added to `BrowseModelServiceTests`):

```swift
@Test func twoTogglesInARowLandInOrder() async throws {
    model.click(items[0].id, extend: true, range: false)
    stub.delay("setFavorite(_:_:)", by: .milliseconds(200))   // the first is slow
    Task { await model.toggleSelectionFavorite() }             // on
    Task { await model.toggleSelectionFavorite() }             // decided from what is on screen: on again
    try await waitUntil { stub.calls("setFavorite(_:_:)") == 2 }
    #expect(try library.mediaItems(matching: MediaFilter(), kinds: .video).first { $0.id == items[0].id }?.isFavorite == true)
}

@Test func aFailedWriteSaysSoAndKeepsTheSelection() async throws {
    model.click(items[0].id, extend: true, range: false)
    stub.fail("setNeedsReview(_:_:)")
    await model.markSelectionReviewed()
    #expect(model.errorMessage != nil)
    #expect(model.selection == [items[0].id])
}
```

- [ ] **Step 6: Run them.** Expected: do not compile (`await` on a synchronous method).
- [ ] **Step 7: Make the eleven `BrowseModel` methods `async`** and call the service. Find callers with `grep -rn "renameSource\|setSourceEnabled\|addSource(at\|saveCurrentFilter\|updateSavedFilter\|renameSavedFilter\|deleteSavedFilter\|markSelectionReviewed\|applyTagToSelection\|toggleSelectionFavorite\|removeTagFromSelection" Sources Tests` and update each. The saved-filter methods no longer re-read the list themselves: the change hub delivers `.savedFilters` and the model refreshes, as it does for a change made by any other window.
- [ ] **Step 8: Run all tests, verify, commit** `Library service: Browse writes through it`.

### Task 4: Browse's jobs

Branch `feature/library-service-browse-jobs`.

**Files:**
- Create: `Sources/SightsAndSoundsKit/Service/JobRequesting.swift`; Modify: `LibraryService.swift`, `LocalLibraryService.swift`
- Modify: `Sources/SightsAndSoundsApp/Browse/BrowseModel.swift` (`scanText`, `joinFolder`, `writeTags`, `restoreSnapshot`, `runValidation`, `remux`, `sweepMetadata`, `examineSelection`, `runOperation`; `jobRunner` goes)
- Create: `Tests/SightsAndSoundsKitTests/LocalLibraryServiceJobTests.swift`

**Interfaces:**
- Produces:

```swift
public enum JobRequest: Codable, Equatable, Sendable {
    case recogniseText(itemID: UUID)
    case joinFolder(sourceID: UUID, folderPath: String)
    case writeTags(itemIDs: [UUID], scope: String)
    case restoreSnapshot(UUID)
    case remux(itemID: UUID, mode: RemuxJob.Mode)
    case metadataSweep(itemIDs: [UUID]?)
    case examine(itemIDs: [UUID])
    case validation
}

public enum JobWait: String, Codable, Sendable {
    /// Queue it, start the lane, return at once.
    case none
    /// Queue it, move it next after the job running, return when it settles.
    case nextThenSettled
    /// One of its kind at most: queue it unless one is pending, and
    /// return when none of that kind is pending.
    case unlessPendingThenSettled
}

public protocol JobRequesting: Sendable {
    /// The job queued, or nil when `unlessPendingThenSettled` found one pending.
    @discardableResult func run(_ request: JobRequest, wait: JobWait) async throws -> JobRecord?
}
```

How today's calls map: `scanText(_:)`, `joinFolder`, `writeTags`, `restoreSnapshot`, `remux`, `examineSelection` → `.none`; `scanText(itemID:then:)` and `sweepMetadata(itemIDs: ids)` → `.nextThenSettled`; `runValidation()` and `sweepMetadata(itemIDs: nil)` → `.unlessPendingThenSettled`.

- [ ] **Step 1: Write the failing tests**, with a `JobRunner` whose catalog is the real one and a paused runner where the test must see the queue before it drains:

```swift
@Suite struct LocalLibraryServiceJobTests {
    @Test func eachRequestQueuesItsOwnKindWithItsPayload() async throws {
        // paused runner: nothing drains
        let cases: [(JobRequest, String)] = [
            (.recogniseText(itemID: f.a.id), OcrJob.kind),
            (.joinFolder(sourceID: f.source.id, folderPath: "set"), JoinJob.kind),
            (.writeTags(itemIDs: [f.a.id], scope: "one"), WritebackJob.kind),
            (.restoreSnapshot(UUID()), RestoreTagsJob.kind),
            (.remux(itemID: f.a.id, mode: .optimize), RemuxJob.kind),
            (.metadataSweep(itemIDs: [f.a.id]), MetadataSweepJob.kind),
            (.examine(itemIDs: [f.a.id]), MediaSignalJob.kind),
        ]
        for (request, kind) in cases {
            let record = try #require(try await f.service.run(request, wait: .none))
            #expect(record.kind == kind)
            #expect(record.payload == f.payloadTheStaticEnqueueWrites(for: request))
        }
    }
    @Test func aSecondValidationWhileOneIsPendingQueuesNothing() async throws {
        _ = try await f.runner.enqueue(ValidationJob.self)        // pending, paused runner
        let waiting = Task { try await f.service.run(.validation, wait: .unlessPendingThenSettled) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(try f.jobCount(kind: ValidationJob.kind) == 1)
        await f.runner.setPaused(false); await f.runner.startDraining()
        #expect(try await waiting.value == nil)
    }
    @Test func nextThenSettledReturnsOnceTheJobHasRun() async throws {
        let record = try #require(try await f.liveService.run(.validation, wait: .nextThenSettled))
        #expect(try f.job(record.id).state == .succeeded)
    }
    @Test func requestsSurviveEncodingAndDecoding() throws {
        let requests: [JobRequest] = [
            .recogniseText(itemID: UUID()), .joinFolder(sourceID: UUID(), folderPath: "set"),
            .writeTags(itemIDs: [UUID()], scope: "one"), .restoreSnapshot(UUID()),
            .remux(itemID: UUID(), mode: .optimize), .metadataSweep(itemIDs: nil),
            .metadataSweep(itemIDs: [UUID()]), .examine(itemIDs: [UUID()]), .validation,
        ]
        for request in requests {
            #expect(try JSONDecoder().decode(JobRequest.self, from: JSONEncoder().encode(request)) == request)
        }
        for wait in [JobWait.none, .nextThenSettled, .unlessPendingThenSettled] {
            #expect(try JSONDecoder().decode(JobWait.self, from: JSONEncoder().encode(wait)) == wait)
        }
    }
}
```

`payloadTheStaticEnqueueWrites(for:)` queues the same job through its `enqueue(on:…)` on a second paused runner over a second library and returns that row's payload, so the service and the static function are compared, not re-described.

- [ ] **Step 2: Run them.** Expected: do not compile.
- [ ] **Step 3: Implement `run(_:wait:)`**: a `switch` over the request that calls the job's existing static `enqueue(on:…)` (or `runner.enqueue(ValidationJob.self)`), then per `wait`: `startDraining()`; or `runNext(id)` and `waitUntilSettled([id])`; or `enqueueUnlessPending` then `waitUntilSettled` / `waitUntilNonePending(of:)`.
- [ ] **Step 4: Run them.** Expected: 4 pass.
- [ ] **Step 5: Move the nine `BrowseModel` methods onto `service.run`**; delete `runOperation` and the `jobRunner` property. The initialiser keeps its `runner:` parameter (it builds the local service).
- [ ] **Step 6: Run all tests, verify, commit** `Library service: Browse queues jobs through it`.

### Task 5: The ratchet

Branch `chore/service-boundary-guard`.

**Files:**
- Create: `scripts/check-service-boundary.sh`, `scripts/service-boundary-baseline.txt`
- Modify: `.github/workflows/` (the job that runs the other guards), `docs/` wherever the guards are listed

- [ ] **Step 1: Write the script** (bash 3.2, like the other guards): for every file under `Sources/SightsAndSoundsApp`, count lines matching `library\.[a-zA-Z]+\(|\.writer\.(read|write)|[rR]unner\.[a-zA-Z]+\(`; compare with the file's line in the baseline (`<count> <path>`, absent means 0); fail, naming the file and both numbers, if a count is above its baseline; print a reminder, without failing, when a count is below it so the baseline is lowered in the same pull request.
- [ ] **Step 2: Prove it fails.** Add one `library.sources()` call to a scratch copy of `SidebarView.swift`; run; expect exit 1 naming the file. Remove it.
- [ ] **Step 3: Generate the baseline** from `dev` as it then stands, commit both, wire it into CI beside `check-kit-portable.sh`.
- [ ] **Step 4: Verify, commit** `Guards: the app's direct database use can only go down`.

## Self-review

- Spec section 1 asks that the app target stop naming `LibraryDatabase` and `JobRunner`. This plan does it for `BrowseModel`'s own calls except the three listed under "Not in this plan"; Task 5's baseline is the list of what remains.
- Every type named in a later task is defined in an earlier one: `TileMenuFacts` (1) is used by `BrowseListingAnswer` (2); `StubLibraryService` and the `service:` initialiser (2) by Task 3's tests.
- The five Review Focus lines each name their test and task.
