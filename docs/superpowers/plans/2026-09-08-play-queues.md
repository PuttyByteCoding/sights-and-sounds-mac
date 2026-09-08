# Play Queues (PR 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every player owns a snapshot queue with a definition, changed only by Refresh; the player stops following its window's listing.

**Architecture:** A `PlayQueue` (definition + snapshot rows) replaces the player's id array. `PlayerRequest` carries the definition and a title; every entry point states what its queue is. `PlayerModel` exposes `playlist`/`queueItems` from the queue, gains `refreshQueue`, and loses `updatePlaylist`. The queue strip gets a header with the title, count and Refresh; ⌘R refreshes too.

**Tech Stack:** Swift 6, SwiftUI, Observation, GRDB via the Kit, Swift Testing. macOS 15+.

**Spec:** `docs/superpowers/specs/2026-09-08-play-queues-design.md` (delivery item 1). Branch `feature/play-queues` off dev.

## Global Constraints

- Worktree only; zero-warning build; full `swift test`; both guard scripts; a bundle launch before pushing.
- F5 is NOT bound to Refresh: F1–F9 are already bindable tag keys in the player. Refresh is the button and ⌘R; the spec's Keys line is corrected in Task 4.
- Copy verbatim: header button help "Refresh — re-run this queue's definition (⌘R)"; empty strip text "Nothing matches — Refresh again later."
- Tests never touch `AppSettingsStore.shared`.

---

### Task 1: PlayQueue and QueueDefinition

**Files:**
- Create: `Sources/SightsAndSoundsApp/Player/PlayQueue.swift`
- Test: `Tests/SightsAndSoundsAppTests/PlayQueueTests.swift`

**Interfaces (produces):**
```swift
enum QueueDefinition: Hashable, Sendable {
    case listing(filter: MediaFilter, kinds: MediaKinds, ordering: MediaOrdering)
    case tag(id: UUID, name: String)
    case history
    case explicit(ids: [UUID], name: String)
    var title: String
}
@Observable @MainActor final class PlayQueue {
    private(set) var definition: QueueDefinition
    var title: String { definition.title }
    private(set) var items: [MediaItem]
    var ids: [UUID] { items.map(\.id) }
    init(definition: QueueDefinition, items: [MediaItem])
    static func run(_ definition: QueueDefinition, library: LibraryDatabase) throws -> [MediaItem]   // nonisolated
    static func make(_ definition: QueueDefinition, library: LibraryDatabase) throws -> PlayQueue
    func replaceDefinition(_ definition: QueueDefinition)   // listing refresh in the library window
    func apply(_ items: [MediaItem])                         // a refresh landed
}
```

- [ ] **Step 1: Failing tests**

```swift
// Tests/SightsAndSoundsAppTests/PlayQueueTests.swift
import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// A queue is a snapshot with a definition: it changes only when the
/// definition is re-run, whatever the library does in between.
@Suite @MainActor struct PlayQueueTests {

    private func makeLibrary() async throws -> (LibraryDatabase, Source, TagCategory) {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Queues")
        let source = Source(name: "S", rootPath: "/tmp/queues-\(UUID().uuidString)")
        let band = TagCategory(name: "Band")
        try await library.writer.write { db in
            try source.insert(db)
            try band.insert(db)
        }
        return (library, source, band)
    }

    @discardableResult
    private func insert(_ library: LibraryDatabase, _ source: Source, _ path: String) async throws -> MediaItem {
        let item = MediaItem(sourceID: source.id, kind: .video, relativePath: path, needsReview: false)
        try await library.writer.write { try item.insert($0) }
        return item
    }

    @Test func aListingQueueIsASnapshotUntilRefreshed() async throws {
        let (library, source, _) = try await makeLibrary()
        try await insert(library, source, "a.mp4")
        let queue = try PlayQueue.make(
            .listing(filter: MediaFilter(), kinds: .video, ordering: .relativePath),
            library: library)
        #expect(queue.items.map(\.relativePath) == ["a.mp4"])

        try await insert(library, source, "b.mp4")
        #expect(queue.items.map(\.relativePath) == ["a.mp4"])  // untouched

        queue.apply(try PlayQueue.run(queue.definition, library: library))
        #expect(queue.items.map(\.relativePath) == ["a.mp4", "b.mp4"])
    }

    @Test func aTagQueueHoldsOnlyThatTagsItemsAndKeepsItsTitle() async throws {
        let (library, source, band) = try await makeLibrary()
        let phish = SightsAndSoundsKit.Tag(tagCategoryID: band.id, name: "Phish")
        try await library.writer.write { try phish.insert($0) }
        let tagged = try await insert(library, source, "phish.mp4")
        try await insert(library, source, "other.mp4")
        try library.assignTag(phish.id, to: tagged.id)

        let queue = try PlayQueue.make(.tag(id: phish.id, name: "Phish"), library: library)
        #expect(queue.items.map(\.relativePath) == ["phish.mp4"])
        #expect(queue.title == "Tag: Phish")
    }

    @Test func anExplicitQueueDropsItemsThatNoLongerExistOnRefresh() async throws {
        let (library, source, _) = try await makeLibrary()
        let a = try await insert(library, source, "a.mp4")
        let b = try await insert(library, source, "b.mp4")
        let queue = try PlayQueue.make(.explicit(ids: [b.id, a.id], name: "Selection"), library: library)
        #expect(queue.ids == [b.id, a.id])  // the given order, not the table's

        try await library.writer.write { db in _ = try MediaItem.deleteOne(db, key: a.id) }
        queue.apply(try PlayQueue.run(queue.definition, library: library))
        #expect(queue.ids == [b.id])
    }

    @Test func aHistoryQueueIsWhatWasWatchedMostRecentFirst() async throws {
        let (library, source, _) = try await makeLibrary()
        let old = try await insert(library, source, "old.mp4")
        let new = try await insert(library, source, "new.mp4")
        try await insert(library, source, "never.mp4")
        try library.recordPlaybackStop(itemID: old.id, positionSeconds: 10, durationSeconds: 100)
        try await Task.sleep(for: .milliseconds(20))
        try library.recordPlaybackStop(itemID: new.id, positionSeconds: 10, durationSeconds: 100)

        let queue = try PlayQueue.make(.history, library: library)
        #expect(queue.items.map(\.relativePath) == ["new.mp4", "old.mp4"])
    }

    @Test func replacingTheDefinitionChangesWhatRefreshRuns() async throws {
        let (library, source, _) = try await makeLibrary()
        try await insert(library, source, "b.mp4")
        try await insert(library, source, "a.mp4")
        let queue = try PlayQueue.make(
            .listing(filter: MediaFilter(), kinds: .video, ordering: .relativePath),
            library: library)
        #expect(queue.items.map(\.relativePath) == ["a.mp4", "b.mp4"])
        queue.replaceDefinition(
            .listing(filter: MediaFilter(), kinds: .video, ordering: .fileSize(ascending: false)))
        #expect(queue.items.map(\.relativePath) == ["a.mp4", "b.mp4"])  // not until refresh
        queue.apply(try PlayQueue.run(queue.definition, library: library))
        #expect(queue.items.count == 2)
    }
}
```
Check `recordPlaybackStop`'s real signature in `Sources/SightsAndSoundsKit/Playback/PlaybackProgress.swift` and match it.

- [ ] **Step 2: Run** `swift build --build-tests 2>&1 | grep error: | grep -v emit-module | head -1` — `cannot find 'PlayQueue'`.

- [ ] **Step 3: Create `PlayQueue.swift`**

```swift
import Foundation
import GRDB
import Observation
import SightsAndSoundsKit

/// What a queue IS, as a thing that can be run again. A player's queue
/// is the snapshot the definition produced when the player opened;
/// Refresh runs the definition again. Nothing else changes a queue.
enum QueueDefinition: Hashable, Sendable {
    /// The library window's listing at the moment of opening.
    case listing(filter: MediaFilter, kinds: MediaKinds, ordering: MediaOrdering)
    /// Every item wearing one tag — the Tag Pivot window.
    case tag(id: UUID, name: String)
    /// What has been watched, most recent first.
    case history
    /// A fixed set — a selection, a compare pair, a Recently Watched row.
    case explicit(ids: [UUID], name: String)

    var title: String {
        switch self {
        case .listing(let filter, _, _): filter.isEmpty ? "All items" : "Filtered listing"
        case .tag(_, let name): "Tag: \(name)"
        case .history: "Recently Watched"
        case .explicit(_, let name): name
        }
    }
}

/// A player's queue: the definition and the rows it produced. Owned by
/// one player, dies with its window. The player never receives a new
/// list from outside; it asks the queue to refresh.
@Observable @MainActor
final class PlayQueue {
    private(set) var definition: QueueDefinition
    private(set) var items: [MediaItem]

    var title: String { definition.title }
    var ids: [UUID] { items.map(\.id) }

    init(definition: QueueDefinition, items: [MediaItem]) {
        self.definition = definition
        self.items = items
    }

    /// Run the definition once and hold the result.
    static func make(_ definition: QueueDefinition, library: LibraryDatabase) throws -> PlayQueue {
        PlayQueue(definition: definition, items: try run(definition, library: library))
    }

    /// The definition, as rows. Nonisolated so a refresh can run it off
    /// the main actor; the caller hands the rows to `apply`.
    nonisolated static func run(
        _ definition: QueueDefinition, library: LibraryDatabase
    ) throws -> [MediaItem] {
        switch definition {
        case .listing(let filter, let kinds, let ordering):
            return try library.mediaItems(matching: filter, kinds: kinds, orderedBy: ordering)
        case .tag(let id, _):
            return try library.items(withTag: id, limit: 10_000).items
        case .history:
            return try library.recentlyWatched()
        case .explicit(let ids, _):
            // The given order, minus anything that no longer exists.
            let rows: [MediaItem] = try library.writer.read { db -> [MediaItem] in
                try MediaItem.fetchAll(db, keys: ids)
            }
            let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
            return ids.compactMap { byID[$0] }
        }
    }

    /// The library window's Refresh: the grid's current definition
    /// becomes this queue's, then a refresh catches the queue up.
    func replaceDefinition(_ definition: QueueDefinition) {
        self.definition = definition
    }

    /// A refresh landed.
    func apply(_ items: [MediaItem]) {
        self.items = items
    }
}
```
If `library.items(withTag:limit:)` returns a different shape, match it (see `TagPlayerWindow.swift`).

- [ ] **Step 4: Run** `swift test --filter PlayQueueTests` — 5 pass. **Step 5: Commit** `Player: PlayQueue — a snapshot with a definition`.

---

### Task 2: Every entry point states its queue

**Files:**
- Modify: `Sources/SightsAndSoundsApp/SightsAndSoundsApp.swift` (`PlayerRequest` ~line 503)
- Modify: `Sources/SightsAndSoundsApp/Browse/AuxiliaryWindow.swift` (`AuxWindowRequest`, player kind)
- Modify: `Sources/SightsAndSoundsApp/Browse/TagPlayerWindow.swift`
- Modify: `Sources/SightsAndSoundsApp/Browse/ItemGridView.swift` (`play()` ~line 289)
- Modify: `Sources/SightsAndSoundsApp/Browse/BrowseModel.swift` (`openPlayerForAnalysis` ~line 70, `queueSelection` ~line 715)
- Modify: `Sources/SightsAndSoundsApp/Browse/WatchedView.swift` (`play` ~line 189)
- Modify: `Sources/SightsAndSoundsApp/Browse/ReviewView.swift` (~line 1012)

- [ ] **Step 1: `PlayerRequest`** becomes:
```swift
/// Identifies one item to play and the queue it plays inside: the
/// definition (so Refresh can run it again) and the ids the definition
/// produced at the moment of opening (so the player starts at once).
/// Setting one on a BrowseModel swaps that library window over to the
/// embedded player.
struct PlayerRequest: Hashable {
    var libraryID: UUID
    var itemID: UUID
    var definition: QueueDefinition
    var playlist: [UUID]

    init(libraryID: UUID, itemID: UUID, definition: QueueDefinition, playlist: [UUID]) {
        self.libraryID = libraryID
        self.itemID = itemID
        self.definition = definition
        self.playlist = playlist
    }

    /// A fixed set with a name — the compare pane, a selection.
    init(libraryID: UUID, itemID: UUID, playlist: [UUID], name: String) {
        self.init(
            libraryID: libraryID, itemID: itemID,
            definition: .explicit(ids: playlist, name: name), playlist: playlist)
    }
}
```
(Codable is dropped; nothing encodes it.)

- [ ] **Step 2: Call sites.**

`ItemGridView.play()`:
```swift
        model.playerRequest = PlayerRequest(
            libraryID: model.libraryID, itemID: item.id,
            definition: .listing(filter: model.filter, kinds: model.kinds, ordering: model.ordering),
            playlist: model.visibleItems.map(\.id))
```
`BrowseModel.openPlayerForAnalysis`: the same `definition: .listing(...)` with `self.filter/kinds/ordering`.
`BrowseModel.queueSelection`: `PlayerRequest(libraryID: libraryID, itemID: first.id, playlist: items.map(\.id), name: "Selection")`.
`WatchedView.play`: `PlayerRequest(libraryID: model.libraryID, itemID: item.id, definition: .history, playlist: rows.map(\.id))`.
`ReviewView`: `PlayerRequest(libraryID: model.libraryID, itemID: item.id, playlist: [item.id], name: "Compare")`.

`AuxWindowRequest` gains `var tagID: UUID? = nil` (doc: "Player kind: the tag whose items the queue holds, so Refresh can re-run it. Optional so saved window state decodes."). `openTagPlayerWindow` passes `tagID: tag.id`. `AuxiliaryWindowView.task`:
```swift
                if request.kind == .player, let first = request.itemIDs.first {
                    let definition: QueueDefinition = request.tagID.map {
                        .tag(id: $0, name: request.title?.replacingOccurrences(of: "Tag: ", with: "") ?? "Tag")
                    } ?? .explicit(ids: request.itemIDs, name: request.title ?? "Queue")
                    made.playerRequest = PlayerRequest(
                        libraryID: request.libraryID, itemID: first,
                        definition: definition, playlist: request.itemIDs)
                }
```

- [ ] **Step 3: Build** (the model still compiles: it ignores the new fields until Task 3). **Commit** `Player: every entry point states its queue's definition`.

---

### Task 3: The player owns a queue and refreshes it

**Files:**
- Modify: `Sources/SightsAndSoundsApp/Player/PlayerModel.swift` (`playlist` ~line 25, init ~157, `// MARK: - Play queue` ~167–225, `publishToSession` ~50, `step` ~877)
- Modify: `Sources/SightsAndSoundsApp/Player/PlayerView.swift` (drop the `.onChange(of: browse.visibleItems...)` ~line 99; ⌘R in `handle`; `QueuePanel` header ~1657; `queueMinHeight` ~430)
- Test: `Tests/SightsAndSoundsAppTests/PlayerQueueTests.swift`

- [ ] **Step 1: Failing test**

```swift
import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// The player's queue is its own: nothing outside replaces it, Refresh
/// re-runs its definition, and a refresh never stops playback.
@Suite @MainActor struct PlayerQueueTests {
    private func makeLibrary() async throws -> (LibraryDatabase, Source) {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "PlayerQueue")
        let source = Source(name: "S", rootPath: "/tmp/pq-\(UUID().uuidString)")
        try await library.writer.write { try source.insert($0) }
        return (library, source)
    }

    private func insert(_ library: LibraryDatabase, _ source: Source, _ path: String) async throws -> MediaItem {
        let item = MediaItem(sourceID: source.id, kind: .video, relativePath: path, needsReview: false)
        try await library.writer.write { try item.insert($0) }
        return item
    }

    private func settle(_ model: PlayerModel) async throws {
        for _ in 0..<200 where model.item == nil { try await Task.sleep(for: .milliseconds(25)) }
        for _ in 0..<200 where model.isRefreshingQueue { try await Task.sleep(for: .milliseconds(25)) }
    }

    @Test func refreshRerunsTheDefinitionAndKeepsTheShownItem() async throws {
        let (library, source) = try await makeLibrary()
        let a = try await insert(library, source, "a.mp4")
        let b = try await insert(library, source, "b.mp4")
        let model = PlayerModel(
            request: PlayerRequest(
                libraryID: UUID(), itemID: a.id,
                definition: .listing(filter: MediaFilter(), kinds: .video, ordering: .relativePath),
                playlist: [a.id, b.id]),
            library: library, appDatabase: nil)
        try await settle(model)
        #expect(model.playlist == [a.id, b.id])

        _ = try await insert(library, source, "c.mp4")
        #expect(model.playlist == [a.id, b.id])  // nothing outside touches it

        model.refreshQueue()
        try await settle(model)
        #expect(model.playlist.count == 3)
        #expect(model.item?.id == a.id)
    }

    @Test func aRefreshThatDropsTheShownItemLeavesItPlayingAndWalksFromTheEnds() async throws {
        let (library, source) = try await makeLibrary()
        let a = try await insert(library, source, "a.mp4")
        let b = try await insert(library, source, "b.mp4")
        let model = PlayerModel(
            request: PlayerRequest(libraryID: UUID(), itemID: a.id, playlist: [a.id, b.id], name: "Pair"),
            library: library, appDatabase: nil)
        try await settle(model)

        try await library.writer.write { db in _ = try MediaItem.deleteOne(db, key: a.id) }
        model.refreshQueue()
        try await settle(model)
        #expect(model.playlist == [b.id])
        #expect(model.item?.id == a.id)  // still the shown item

        model.goNext()
        try await settle(model)
        #expect(model.item?.id == b.id)  // from the top of what is left
    }
}
```

- [ ] **Step 2: Run** — errors on `isRefreshingQueue` / `refreshQueue`.

- [ ] **Step 3: Model.** Replace the `playlist` declaration with:
```swift
    /// This player's queue: a snapshot with a definition. Nothing outside
    /// the player replaces it; Refresh re-runs the definition.
    let queue: PlayQueue
    /// The queue's ids — what ←/→ walk.
    var playlist: [UUID] { queue.ids }
    /// The queue's rows — the strip's data.
    var queueItems: [MediaItem] { queue.items }
    private(set) var isRefreshingQueue = false
```
In `init`: replace `self.playlist = request.playlist` with `self.queue = PlayQueue(definition: request.definition, items: [])`, and replace the trailing `loadQueueItems()` with `loadSnapshot(request.playlist)`.

Replace the whole `// MARK: - Play queue` section (the `queueItems` declaration, `updatePlaylist`, `loadQueueItems`) with:
```swift
    // MARK: - Play queue

    /// The opening snapshot's rows, in the given order, off the main
    /// actor — the request carries ids so the player starts at once.
    private func loadSnapshot(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let library = library
        Task.detached(priority: .userInitiated) { [weak self] in
            let rows: [MediaItem] = (try? await library.writer.read { db -> [MediaItem] in
                try MediaItem.fetchAll(db, keys: ids)
            }) ?? []
            let position = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
            let ordered = rows.sorted { (position[$0.id] ?? 0) < (position[$1.id] ?? 0) }
            await MainActor.run { [weak self] in
                self?.queue.apply(ordered)
                self?.publishToSession()
            }
        }
    }

    /// Re-run the queue's definition. The shown item keeps playing
    /// whether or not it is still in the result — a Refresh is not a
    /// stop — and ←/→ then start from the ends of what is left.
    func refreshQueue() {
        guard !isRefreshingQueue else { return }
        isRefreshingQueue = true
        let library = library, definition = queue.definition
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result { try PlayQueue.run(definition, library: library) }
            await MainActor.run { [weak self] in
                guard let self else { return }
                switch result {
                case .success(let rows): self.queue.apply(rows)
                case .failure(let error): self.loadError = "Refresh failed: \(error)"
                }
                self.isRefreshingQueue = false
                self.publishToSession()
            }
        }
    }

    /// The library window's Refresh: the grid's current definition first,
    /// so the queue catches up with what the grid shows.
    func refreshQueue(listing definition: QueueDefinition) {
        queue.replaceDefinition(definition)
        refreshQueue()
    }
```
Keep `queueFileURL(for:)` as is.

`step(_:)` becomes:
```swift
    private func step(_ delta: Int) {
        guard let item else { return }
        if let index = playlist.firstIndex(of: item.id) {
            let next = index + delta
            guard playlist.indices.contains(next) else { return }
            load(itemID: playlist[next])
        } else if let edge = delta > 0 ? playlist.first : playlist.last {
            // A refresh dropped the shown item: walk in from the end.
            load(itemID: edge)
        }
    }
```
Delete the `updatePlaylist` doc comment on `playlist` if any remains; `publishToSession` already reads `playlist`.

- [ ] **Step 4: View.** Delete the `.onChange(of: browse.visibleItems.map(\.id)) { ... }` block in `PlayerView`. In `PlayerView.handle(_:)`, before the Esc handling add:
```swift
        // ⌘R re-runs the queue's definition. In the library window the
        // grid's current filter and order come along, so the queue
        // catches up with what the grid shows.
        if press.modifiers.contains(.command), press.characters.lowercased() == "r" {
            refreshQueue(model)
            return true
        }
```
and a helper on `PlayerView`:
```swift
    private func refreshQueue(_ model: PlayerModel) {
        if case .listing = model.queue.definition {
            model.refreshQueue(listing: .listing(
                filter: browse.filter, kinds: browse.kinds, ordering: browse.ordering))
        } else {
            model.refreshQueue()
        }
    }
```
The Refresh button lives in `QueuePanel`, which has no `browse`; give `QueuePanel` a `let onRefresh: () -> Void` and pass `{ refreshQueue(model) }` from `PlayerContent` — `PlayerContent` needs `@Environment(BrowseModel.self) private var browse` for that; add it and move the helper there (the key handler in `PlayerView` can call a small duplicate or route through a closure; keep ONE implementation by putting `refreshQueue(listing:)` decision in `PlayerModel`: add
```swift
    /// The listing definition to use on Refresh when this queue is a
    /// listing — installed by the view that knows the grid.
    var currentListing: () -> QueueDefinition? = { nil }
```
and make `refreshQueue()` start with `if case .listing = queue.definition, let listing = currentListing() { queue.replaceDefinition(listing) }`. Then `PlayerView.task` sets `model.currentListing = { [weak browse] in browse.map { .listing(filter: $0.filter, kinds: $0.kinds, ordering: $0.ordering) } }` right after creating the model, the key handler calls `model.refreshQueue()`, and `QueuePanel`'s button calls `model.refreshQueue()`. Drop `refreshQueue(listing:)` and the view helper.)

`QueuePanel`: wrap the existing `ScrollViewReader` in a `VStack(spacing: 0)` with this header above it:
```swift
            HStack(spacing: 8) {
                Text(model.queue.title)
                    .font(Theme.ui(10.5, .semibold))
                    .foregroundStyle(Theme.Text.secondary)
                    .lineLimit(1)
                Text("\(model.queueItems.count)")
                    .font(Theme.mono(10))
                    .foregroundStyle(model.queueItems.isEmpty ? Theme.Text.zeroCount : Theme.Text.quaternary)
                Spacer(minLength: 6)
                if model.isRefreshingQueue {
                    ProgressView().controlSize(.mini)
                }
                Button {
                    model.refreshQueue()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(Theme.ui(11))
                        .foregroundStyle(Theme.Text.tertiary)
                }
                .buttonStyle(.plain)
                .disabled(model.isRefreshingQueue)
                .help("Refresh — re-run this queue's definition (⌘R)")
            }
            .padding(.horizontal, 8)
            .frame(height: Self.headerHeight)
```
with `static let headerHeight: CGFloat = 22`, `thumbHeight = max(24, height - 18 - metadataHeight - Self.headerHeight)`, the frame height `thumbHeight + metadataHeight + 18 + Self.headerHeight`, and when `model.queueItems.isEmpty && !model.isRefreshingQueue` the strip shows `Text("Nothing matches — Refresh again later.")` in `Theme.Text.disabled` instead of the scroll view. `queueMinHeight` in `PlayerContent` becomes `QueueCell.metadataHeight(for: ...) + 42 + QueuePanel.headerHeight` (make `QueuePanel` and its constant visible to `PlayerContent`: both are in the same file; drop `private` from the constant's struct only if needed).

Also `LibraryWindowView.swift` line ~157: help text becomes `"Order the listing — a player opened from it takes this order"`.

- [ ] **Step 5: Build, run** `swift test --filter "PlayerQueueTests|PlayQueueTests"`. **Commit** `Player: the queue is a snapshot the player owns, refreshed on demand`.

---

### Task 4: Docs, verification, PR

- [ ] `docs/superpowers/specs/2026-09-08-play-queues-design.md` Keys: replace "Refresh: F5 and ⌘R in a player." with "Refresh: ⌘R in a player, and the strip's button. (F5 is a bindable tag key already.)"
- [ ] `docs/design/03-player.md`: in the left-column paragraph change "queue drawer, 146 pt" to "queue drawer, 146 pt (a header names the queue and counts it, with Refresh; the queue is a snapshot the player owns — see the play-queues spec)". `docs/design/02-browse-window.md`: after the "Add to queue" mention or in §5's list add one sentence: "A player opened from the grid takes the listing as a snapshot; the grid stays live and the player's Refresh catches its queue up."
- [ ] Verify: zero-warning build, `swift test`, both guards, bundle launch. Commit `Play queues: spec and docs for the snapshot queue`, push `feature/play-queues`, PR against dev via `github-putty` with Why / What / Verification / After merging ("open a Tag Pivot window and confirm its strip stays the tag's items; tick a sidebar tag while playing in the library window and confirm the strip holds until ⌘R"). Report the URL and stop.
