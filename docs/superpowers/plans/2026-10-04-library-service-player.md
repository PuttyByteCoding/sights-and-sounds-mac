# Library Service, the Player — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Put the player (`PlayerModel`, `PlayQueue`, the text-lines panel, the key-bindings editor and the tag player window) behind `LibraryService`, with no change in what a person sees.

**Architecture:** Two new groups on `LibraryService`: `PlayerReading` and `PlayerWriting`, answered by `LocalLibraryService` with the code the player runs today. The player's reads become asynchronous and are applied only if the item they were asked about is still the one on screen. Its writes go through a `WriteQueue` shared with `BrowseModel` (the serial chain #533 put inside `BrowseModel`, taken out into a type of its own), and the app waits for every queue to settle before it quits.

**Tech Stack:** Swift 6 (tools 6.0, strict concurrency), SwiftPM, GRDB 7, swift-testing, AVFoundation.

**Spec:** `docs/superpowers/specs/2026-10-03-remote-library-design.md`, sections 1 and 4. The first plan, `2026-10-04-library-service-browse.md`, defines the protocol, `LocalLibraryService`, `StubLibraryService` and the guard this plan builds on.

## Global Constraints

- Behaviour-neutral, except where a task names a method that became `async` or a write that now lands a moment later.
- No GRDB type in any `LibraryService` signature. Inputs and results are `Codable`, `Equatable` and `Sendable`.
- Every operation is `async throws`.
- One task is one pull request against `dev`, branched from `origin/dev`, touching no file another open pull request touches.
- Each pull request that lowers a file's count runs `./scripts/check-service-boundary.sh --update` and commits the baseline.
- Before each push: `./scripts/check-build-warnings.sh`, `swift test` (both suites, counts reported), and the four guards (`check-terminology`, `check-no-private-data`, `check-kit-portable`, `check-service-boundary`).
- Fixtures are synthetic. Media for tests comes from `DemoMediaFactory`, under the temporary directory, and is removed.

## Review Focus

1. **Quitting or closing the window straight after pausing**: the resume position is saved. It is now a request in flight, not a line that has run. Task 1, `settleAllWaitsForEveryQueue`; Task 3, `closingThePlayerSavesWhereItStopped`.
2. **A bound key pressed several times quickly**: the tag ends on or off by the count of presses, in order. Task 4, `aBoundKeyPressedThreeTimesEndsOn`.
3. **Stepping to the next item while an answer for the last one is on its way**: the tags, segments and search values of the last item are not drawn under the new one, and a write asked of the last item is made to the last item. Task 2, `anAnswerForTheLastItemIsNotShownUnderTheNext`; Task 4, `aTagAppliedJustBeforeSteppingGoesToTheItemItWasPressedOn`.
4. **A playback URL that cannot be had** (source offline now; host unreachable later): nothing keeps playing, the panel answers for the item on screen, and the reason is shown. Task 2, `anItemWithNoPlaybackURLShowsWhyAndStopsTheLast` (the existing `PlayerLoadFailureTests`, run over the stub).
5. **A flag toggled while its file is being staged**: the row and the file URL shown are the ones after the last press, not the first to return. Task 3, `theLastOfTwoFlagPressesWins` (the existing `PlayerFlagOffMainTests`, run over the stub with a delay).

## Not in this plan

- **Thumbnails, scrub previews, drag-out, Reveal in Finder and Quick Look.** They take a local file path today (`resolvedFileURL`, `fileResolver`, `queueFileResolver`). For a library on another Mac a thumbnail is an image the host serves, and the rest are not offered. That is a different interface from "where is the file", and gets a plan of its own with the Browse grid. Until then those call sites stay on the database and in the guard's baseline: three in `BrowseModel.swift`, one in `PlayerModel.swift`.
- Every other window (Review, Maintenance, Tag Manager, Tag Analysis, Import, Organise, History, Settings, Background Tasks, the app's own library handling).

## Files

| File | Responsibility |
| --- | --- |
| `Sources/SightsAndSoundsApp/WriteQueue.swift` | Writes sent one at a time, in the order asked; every live queue can be waited for. |
| `Sources/SightsAndSoundsKit/Service/PlayerReading.swift` | What the player reads, and its value types. |
| `Sources/SightsAndSoundsKit/Service/PlayerWriting.swift` | What the player changes. |
| `Sources/SightsAndSoundsKit/Service/LocalLibraryService+Player.swift` | The local implementation. |
| `Sources/SightsAndSoundsKit/Service/QueueDefinition.swift` | `QueueDefinition`, moved from the app and made `Codable`. |
| `Sources/SightsAndSoundsApp/Player/PlayerModel.swift` and its neighbours | Lose their database calls group by group. |
| `Tests/SightsAndSoundsKitTests/LocalLibraryServicePlayer*Tests.swift` | One suite per group. |
| `Tests/SightsAndSoundsAppTests/PlayerModelServiceTests.swift` | The player over `StubLibraryService`. |

---

### Task 1: `WriteQueue`, and quitting waits for it

Branch `chore/write-queue`.

**Files:**
- Create: `Sources/SightsAndSoundsApp/WriteQueue.swift`, `Tests/SightsAndSoundsAppTests/WriteQueueTests.swift`
- Modify: `Sources/SightsAndSoundsApp/Browse/BrowseModel.swift` (its private `write` and `lastWrite` go; it holds a `WriteQueue`), `Sources/SightsAndSoundsApp/AppDelegate.swift` (`applicationShouldTerminate`)

**Interfaces:**
- Produces:

```swift
/// Writes to a library, sent one at a time in the order they were asked.
@MainActor
final class WriteQueue {
    init()
    /// Runs `work` after every write queued before it. Returns what it
    /// returned, or the error it threw.
    func run<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async -> Result<T, any Error>
    /// Queues `work` and returns at once; `failed` is called on the main
    /// actor if it throws. For a write nobody waits on: a resume position.
    func send(_ work: @escaping @Sendable () async throws -> Void, failed: @escaping @MainActor (any Error) -> Void = { _ in })
    /// Returns when every write queued on every live queue has finished.
    static func settleAll() async
}
```

`BrowseModel.write(orSay:_:)` keeps its signature and calls `writes.run`.

- [ ] **Step 1: Write the failing tests.**

```swift
@Suite @MainActor struct WriteQueueTests {
    @Test func writesRunInTheOrderTheyWereQueued() async {
        let queue = WriteQueue()
        let log = Log()
        async let first = queue.run { try await Task.sleep(for: .milliseconds(200)); log.add("first") }
        await Task.yield()
        async let second = queue.run { log.add("second") }
        _ = await (first, second)
        #expect(log.all == ["first", "second"])
    }
    @Test func aFailedWriteDoesNotStopTheOnesAfterIt() async {
        let queue = WriteQueue()
        struct Boom: Error {}
        let failed = await queue.run { throw Boom() }
        let after = await queue.run { 7 }
        #expect((try? failed.get()) == nil)
        #expect((try? after.get()) == 7)
    }
    @Test func settleAllWaitsForEveryQueue() async {
        let one = WriteQueue(), two = WriteQueue()
        let log = Log()
        one.send({ try await Task.sleep(for: .milliseconds(150)); log.add("one") })
        two.send({ try await Task.sleep(for: .milliseconds(150)); log.add("two") })
        await WriteQueue.settleAll()
        #expect(Set(log.all) == ["one", "two"])
    }
    @Test func aQueueLetGoOfStillFinishesWhatItWasSent() async {
        let log = Log()
        do { let queue = WriteQueue(); queue.send({ try await Task.sleep(for: .milliseconds(100)); log.add("sent") }) }
        await WriteQueue.settleAll()
        #expect(log.all == ["sent"])
    }
    @Test func aSentWriteThatFailsSaysSo() async {
        let queue = WriteQueue()
        struct Boom: Error {}
        var said = false
        queue.send({ throw Boom() }, failed: { _ in said = true })
        await WriteQueue.settleAll()
        #expect(said)
    }
}
/// `Log` is a lock-guarded `[String]` with `add(_:)` and `all`.
```

- [ ] **Step 2: Run them.** `swift test --filter WriteQueueTests`. Expected: does not compile.
- [ ] **Step 3: Write `WriteQueue`.** Each queue holds `last: Task<Void, Never>?`; `run` chains on it exactly as `BrowseModel.write` does. A static table of the last task of every queue that has one in flight (added when queued, removed when it finishes) is what `settleAll` awaits, in a loop until the table is empty.
- [ ] **Step 4: Run them.** Expected: 5 pass.
- [ ] **Step 5: Move `BrowseModel` onto it.** `BrowseModelServiceTests.writesLandInTheOrderTheyWereAskedFor` must still pass, and still fail if the chain is broken.
- [ ] **Step 6: Quitting waits.** In `applicationShouldTerminate`, where the app would return `.terminateNow`, return `.terminateLater`, start a task that awaits `WriteQueue.settleAll()` raced against three seconds, then call `reply(toApplicationShouldTerminate: true)`. A quit that is cancelled by the confirmation still returns `.terminateCancel` at once.
- [ ] **Step 7: Verify, commit** `App: writes queue in one place, and quitting waits for them`.

### Task 2: What the player reads

Branch `feature/library-service-player-reads`.

**Files:**
- Create: `Sources/SightsAndSoundsKit/Service/PlayerReading.swift`, `LocalLibraryService+Player.swift`, `QueueDefinition.swift`
- Modify: `LibraryService.swift` (compose `PlayerReading`); `Search/SearchRecipe.swift`, `Search/SearchStringBuilder.swift` (`SearchFormats`, `SearchRecipe`, `SearchSubject` become `Codable` where they are not)
- Modify: `Sources/SightsAndSoundsApp/Player/PlayerModel.swift` (`init` takes `service:`; `load(itemID:)`, `loadSnapshot`, `recountQueue`, `refreshHistory`, `refreshItemTags`, `refreshTagging`, `refreshSegments`, `refreshSearch`), `PlayQueue.swift` (`items(for:library:)` goes; `QueueDefinition` leaves), `OcrLinesPanel.swift`, `Browse/TagPlayerWindow.swift`
- Create: `Tests/SightsAndSoundsKitTests/LocalLibraryServicePlayerReadingTests.swift`, `Tests/SightsAndSoundsAppTests/PlayerModelServiceTests.swift`; Modify: `StubLibraryService.swift`

**Interfaces:**
- Produces:

```swift
public protocol PlayerReading: Sendable {
    /// An item and where its file can be played from, at one moment. The
    /// item is nil when it no longer exists; the URL is nil while its
    /// source is out of reach. A segment's URL is its parent's file.
    func playable(itemID: UUID) async throws -> Playable
    /// These items, in the order given, minus any that no longer exist.
    func items(ids: [UUID]) async throws -> [MediaItem]
    /// What a queue definition lists now.
    func queueItems(_ definition: QueueDefinition) async throws -> [MediaItem]
    /// By item, the tags it wears.
    func tagMembership(itemIDs: [UUID]) async throws -> [UUID: Set<UUID>]
    func recentlyWatched(limit: Int) async throws -> [MediaItem]
    /// Everything the tag panel draws for one item.
    func tagging(itemID: UUID) async throws -> PlayerTagging
    /// A video's segments and its hide blocks.
    func segments(parentID: UUID) async throws -> PlayerSegments
    func searchContext(itemID: UUID) async throws -> SearchContext
    /// The text scan queued or running for an item, if any.
    func pendingTextScan(itemID: UUID) async throws -> UUID?
    func textLines(itemID: UUID) async throws -> [OcrTextLine]
}

public struct Playable: Codable, Equatable, Sendable { public var item: MediaItem?; public var url: URL? }
public struct PlayerTagging: Codable, Equatable, Sendable {
    public var itemTags: [CategoryTags]        // what the item wears
    public var vocabulary: [CategoryTags]      // every category, hidden-from-browse included
    public var aliases: [UUID: [String]]
    public var keyBindings: [TagKeyBinding]
}
public struct PlayerSegments: Codable, Equatable, Sendable { public var clips: [MediaItem]; public var hideBlocks: [VideoBlock] }
public struct SearchContext: Codable, Equatable, Sendable { public var formats: SearchFormats; public var subject: SearchSubject? }

public enum QueueDefinition: Codable, Hashable, Sendable {
    case listing(filter: MediaFilter, kinds: MediaKinds, ordering: MediaOrdering)
    case tag(id: UUID, name: String)
    case history
    case explicit(ids: [UUID], name: String)
}
```

`PlayerModel.init(request:library:appDatabase:fileAccess:service:nowPlaying:)` gains `service: (any LibraryService)? = nil`.

The refresh methods keep their names and stay callable from synchronous code; each starts a task, and applies its answer only if `item?.id` is still the id it asked about. Each gains an `async` twin the tests await (`loadTagging()`, `loadSegments()`, `loadSearch()`).

- [ ] **Step 1: Write the failing Kit tests**, each comparing the service's answer with the `LibraryDatabase` calls it replaces, on a fixture with a source holding one real `DemoMediaFactory` video, a segment of it, a hide block, a second source that is not mounted, two categories (one hidden from browse), tags, an alias and a key binding:
  `aPlayableItemComesWithItsFileURL`, `aSegmentPlaysFromItsParentsFile`, `anItemOnAnUnmountedSourceHasNoURL`, `anItemThatIsGoneIsNil`, `itemsComeBackInTheOrderAskedMinusTheMissing`, `eachQueueDefinitionListsWhatPlayQueueListed` (all four cases against `PlayQueue.items(for:library:)` as it is today, copied into the test as the expected value), `theTagPanelGetsEveryCategoryIncludingThoseHiddenFromBrowse`, `segmentsAreTheClipsAndTheHideBlocksOnly`, `everyAnswerSurvivesEncodingAndDecoding`.
- [ ] **Step 2: Run them.** Expected: do not compile.
- [ ] **Step 3: Implement `PlayerReading` in `LocalLibraryService`** by moving: `load(itemID:)`'s detached read, `loadSnapshot`'s read, `PlayQueue.items(for:library:)`, `refreshTagging`'s four reads (including `TagAlias.fetchAll`), `refreshSegments`' two, `refreshSearch`'s two, and `OcrLinesPanel`'s read of `ocrTextLine`.
- [ ] **Step 4: Run them.** Expected: 9 pass.
- [ ] **Step 5: Forward the group in `StubLibraryService`. Write the failing app tests:**

```swift
@Test func anAnswerForTheLastItemIsNotShownUnderTheNext() async throws {
    let model = f.player(playlist: [f.a.id, f.b.id])            // a wears "Alpha", b wears nothing
    try await waitUntil { model.item?.id == f.a.id && !model.itemTags.isEmpty }
    f.stub.delay("tagging(itemID:)", by: .milliseconds(400))    // a's panel answer, re-asked, is slow
    model.refreshTagging()
    model.load(itemID: f.b.id)
    try await waitUntil { model.item?.id == f.b.id }
    try await waitUntil { f.stub.answered("tagging(itemID:)") >= 3 }   // open, the slow one, b's
    try await Task.sleep(for: .milliseconds(100))
    #expect(model.itemTags.allSatisfy { $0.tags.isEmpty }, "a's tags are drawn under b")
}

@Test func anItemWithNoPlaybackURLShowsWhyAndStopsTheLast() async throws {
    let model = f.player(playlist: [f.a.id, f.unmounted.id])
    try await waitUntil { model.fileURL != nil }
    model.load(itemID: f.unmounted.id)
    try await waitUntil { model.loadError != nil }
    #expect(model.fileURL == nil && model.item?.id == f.unmounted.id)
}

@Test func aFailedLoadLetsGoOfTheItem() async throws {
    let model = f.player(playlist: [f.a.id, f.b.id])
    try await waitUntil { model.fileURL != nil }
    f.stub.fail("playable(itemID:)")
    model.load(itemID: f.b.id)
    try await waitUntil { model.loadError != nil }
    #expect(model.item == nil && model.fileURL == nil)
}
```

- [ ] **Step 6: Run them.** Expected: do not compile (`service:`).
- [ ] **Step 7: Move the eight `PlayerModel` reads, `PlayQueue`, `OcrLinesPanel`'s reads and `TagPlayerWindow` onto the service.** Run the whole player test list (`Player*Tests`, `PlayQueue*Tests`, `HistoryQueueTests`); a test that read a result on the line after a refresh now awaits the `async` twin.
- [ ] **Step 8: Lower the baseline, verify, commit** `Library service: the player reads through it`.

### Task 3: Playback history and the item's flags

Branch `feature/library-service-player-playback`.

**Files:**
- Create: `Sources/SightsAndSoundsKit/Service/PlayerWriting.swift`; Modify: `LibraryService.swift`, `LocalLibraryService+Player.swift`
- Modify: `PlayerModel.swift` (`apply(loaded:url:)`, the time observer's completion, `persistProgress()`, `toggle(_:)`, `shutdown()`)
- Create: `Tests/SightsAndSoundsKitTests/LocalLibraryServicePlayerWritingTests.swift`; Modify: `PlayerModelServiceTests.swift`, `StubLibraryService.swift`

**Interfaces:**
- Consumes: Task 1's `WriteQueue`, Task 2's `Playable`.
- Produces:

```swift
public protocol PlayerWriting: Sendable {
    /// Stamped by the player when it happened, not when it arrived.
    func recordPlayback(_ event: PlaybackEvent) async throws
    /// Set or clear one flag. Marking for deletion and playback issue
    /// stage the file and move it back. Returns the row and its URL as
    /// they are afterwards: a staged file has a new path.
    func setFlag(_ flag: ItemFlag, _ on: Bool, itemID: UUID) async throws -> Playable
}

public enum PlaybackEvent: Codable, Equatable, Sendable {
    case started(itemID: UUID, at: Date)
    case stopped(itemID: UUID, positionSeconds: Double, durationSeconds: Double?, at: Date)
    case completed(itemID: UUID, at: Date)
}

public enum ItemFlag: String, Codable, Sendable, CaseIterable {
    case markedForDeletion, playbackIssue, favorite, needsReview
}
```

`PlayerToggleFlag` in the app becomes a typealias for `ItemFlag`.

- [ ] **Step 1: Write the failing Kit tests:** `eachPlaybackEventWritesWhatItsOwnCallWrites` (start, stop, completion against `recordPlaybackStart/Stop/Completion` on a second library, comparing the item rows), `anEventKeepsTheTimeItWasStampedWith`, `aPlainFlagChangesOnlyItsColumn`, `markingForDeletionStagesTheFileAndReturnsItsNewURL`, `unmarkingPutsItBack`, `eventsAndFlagsSurviveEncodingAndDecoding`.
- [ ] **Step 2: Run them.** Expected: do not compile.
- [ ] **Step 3: Implement.** `setFlag` is the body of the detached task in `PlayerModel.toggle(_:)`: the stage or unstage, or the one-column update, then the fresh row and its resolved URL.
- [ ] **Step 4: Run them.** Expected: 6 pass.
- [ ] **Step 5: Write the failing app tests:**

```swift
@Test func closingThePlayerSavesWhereItStopped() async throws {
    let model = f.player(playlist: [f.a.id])
    try await waitUntil { model.fileURL != nil }
    model.seek(to: 2)
    try await waitUntil { model.currentSeconds >= 2 }
    f.stub.delay("recordPlayback(_:)", by: .milliseconds(200))
    model.persistProgress()
    model.shutdown()
    await WriteQueue.settleAll()
    #expect((try f.row(f.a).resumePositionSeconds ?? 0) >= 2)
}

@Test func theLastOfTwoFlagPressesWins() async throws {
    let model = f.player(playlist: [f.a.id])
    try await waitUntil { model.fileURL != nil }
    f.stub.delay("setFlag(_:_:itemID:)", by: .milliseconds(300))
    model.perform(.toggleFavorite)      // on, slow
    model.perform(.toggleFavorite)      // off
    await WriteQueue.settleAll()
    #expect(model.item?.isFavorite == false)
    #expect(try f.row(f.a).isFavorite == false)
}
```

- [ ] **Step 6: Move the four call sites.** `persistProgress()` and the two history stamps use `writes.send` with the date taken at the call; `toggle(_:)` keeps its optimistic update and its in-flight count and sends `setFlag` through `writes.run`, dropping its own `flagWork` chain.
- [ ] **Step 7: Lower the baseline, verify, commit** `Library service: the player records playback and flags through it`.

### Task 4: The tag panel's writes

Branch `feature/library-service-player-tagging`.

**Files:**
- Modify: `PlayerWriting.swift`, `LocalLibraryService+Player.swift`, `PlayerModel.swift` (`toggleTag`, `applyTag`, `renameTag`, `addTag(named:categoryID:)`, `addAlias`, `handleBoundKey`, `movePanelRow`), `Player/KeyBindingsEditor.swift`
- Modify: the Kit and app test files of Task 3

**Interfaces:**
- Produces, added to `PlayerWriting`:

```swift
/// Returns whether the item wears the tag afterwards.
func toggleTag(_ tagID: UUID, on itemID: UUID) async throws -> Bool
func renameTag(_ tagID: UUID, to name: String) async throws
/// The tag of that name in the category, created if it is not there.
func ensureTag(named name: String, inCategory categoryID: UUID) async throws -> Tag
func addAlias(_ alias: String, toTag tagID: UUID) async throws
func setCategoryOrder(_ categoryIDs: [UUID]) async throws
func setKeyBinding(_ key: String, tagID: UUID, advance: Bool) async throws
func removeKeyBinding(_ key: String) async throws
```

`assignTag(_:to:)` is `BrowseWriting`'s. `handleBoundKey(_:) -> Bool` still answers at once whether the key is bound; the toggle it starts is queued.

- [ ] **Step 1: Failing Kit tests:** `togglingReturnsWhetherTheTagIsNowOn`, `aSingleSelectCategoryReplacesOnToggle`, `renamingToANameInUseIsRefused`, `ensureTagReturnsTheExistingOneCaseInsensitively`, `anAliasIsAddedAndAnEmptyOneIsNot`, `categoryOrderIsStored`, `aKeyIsBoundReboundAndUnbound`.
- [ ] **Step 2–4:** run, implement by calling the `LibraryDatabase` method of the same name, run.
- [ ] **Step 5: Failing app tests:**

```swift
@Test func aBoundKeyPressedThreeTimesEndsOn() async throws {
    try f.library.setKeyBinding("1", tagID: f.alpha.id)
    let model = f.player(playlist: [f.b.id])                    // b wears nothing
    try await waitUntil { model.item?.id == f.b.id && !model.panelVocabulary.isEmpty }
    f.stub.delay("toggleTag(_:on:)", by: .milliseconds(200))
    for _ in 0..<3 { #expect(model.handleBoundKey("1")) }
    await WriteQueue.settleAll()
    #expect(try f.isTagged(f.b, f.alpha))
}

@Test func aTagAppliedJustBeforeSteppingGoesToTheItemItWasPressedOn() async throws {
    let model = f.player(playlist: [f.b.id, f.c.id])
    try await waitUntil { model.item?.id == f.b.id }
    f.stub.delay("toggleTag(_:on:)", by: .milliseconds(300))
    model.toggleTag(f.alpha.id)
    model.load(itemID: f.c.id)
    await WriteQueue.settleAll()
    #expect(try f.isTagged(f.b, f.alpha) && !f.isTagged(f.c, f.alpha))
}
```

- [ ] **Step 6: Move the seven model methods and the editor.** Each captures the item id when it is called, sends through `writes`, and reloads the panel when the write returns if that item is still showing.
- [ ] **Step 7: Lower the baseline, verify, commit** `Library service: the player's tag panel writes through it`.

### Task 5: Segments, blocks and search formats

Branch `feature/library-service-player-segments`.

**Files:**
- Modify: `PlayerWriting.swift`, `LocalLibraryService+Player.swift`, `PlayerModel.swift` (`closeSegmentMark(as:)`, `renameSegment`, `removeSegment`, `blockTap(open:)`, `deleteBlock`, `saveSearchFormat`, `setDefaultSearchFormat`)

**Interfaces:**
- Produces, added to `PlayerWriting`:

```swift
func createSegment(parentID: UUID, name: String, startSeconds: Double, endSeconds: Double, role: SegmentRole) async throws -> MediaItem
func renameSegment(_ itemID: UUID, to name: String) async throws
func deleteSegment(_ itemID: UUID) async throws
func addBlock(to itemID: UUID, startSeconds: Double, endSeconds: Double, kind: VideoBlockKind) async throws -> VideoBlock
func deleteBlock(_ blockID: UUID) async throws
func setSearchFormats(_ formats: SearchFormats, replacingUnreadable: Bool) async throws
```

- [ ] **Step 1: Failing Kit tests:** `aSegmentIsCreatedRenamedAndDeleted`, `deletingASegmentLeavesItsParentAndTheOtherSegments`, `aHideBlockIsAddedAndRemoved`, `searchFormatsAreStoredAndReadBack`.
- [ ] **Step 2–4:** run, implement, run.
- [ ] **Step 5: Failing app test:** `aSegmentMarkedJustBeforeSteppingBelongsToTheVideoItWasMarkedOn` (the shape of Task 4's second test, with `closeSegmentMark`).
- [ ] **Step 6: Move the seven methods.** The existing `PlayerSegmentTimelineTests` await the methods that became `async`.
- [ ] **Step 7: Lower the baseline, verify, commit** `Library service: the player's segments and search formats write through it`.

After Task 5, `PlayerModel.swift` has one direct use left (`queueFileResolver`) and the other four player files have none.

## Self-review

- Spec section 4 says the player asks the service for an item's playable URL: `playable(itemID:)`, Task 2. The relay that will stand behind that URL for a remote library is the remote plan's.
- Types used across tasks: `Playable` (2) is returned by `setFlag` (3); `WriteQueue` (1) is used by 3, 4 and 5; `CategoryTags`, `TagPill`, `StubLibraryService` come from the first plan.
- The five Review Focus lines each name their test and task.
- Known gap, stated under "Not in this plan": file paths for thumbnails and Finder.
