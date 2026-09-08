# Play queues: snapshots per window, rails that narrow the view

Date: 2026-09-08. Status: design, awaiting review.

## Goal

Every player owns its own queue, taken as a snapshot when it opens and
changed only by an explicit Refresh. A Tag Pivot window can narrow and
re-sort what it walks without touching the queue in the window it was
opened from, and the reverse. The grid stays live.

## Decisions (already made)

- **The grid keeps re-querying on every filter click.** Only players
  freeze. Today's live-following player queue goes away.
- **A queue belongs to its window.** Close the window and its queue,
  narrowing and sort are gone. In memory only; no database changes for
  queues.
- **A rail narrows the view, never the queue.** Hiding items is view
  state; the snapshot underneath is intact until Refresh.
- **Reorder is a sort picker on the snapshot**, the browse Sort menu's
  choices plus Shuffle, re-sorting in place without re-running the
  definition. (This answers the parked "reorder like the tags grid"
  question.)
- **History is the one live queue.** It re-runs on other players' loads
  and on its own Refresh; plays inside the History player never reorder
  it.

## The defect this replaces

`PlayerView` watches its window's browse listing and replaces the
player's playlist whenever it changes. A Tag Pivot window's browse model
has no filter and loads the whole library on creation, so a moment after
the window opens its queue becomes every item. Any player in an aux
window suffers the same. Snapshot queues remove the mechanism rather
than patching it.

## Architecture

### PlayQueue (new, `Sources/SightsAndSoundsApp/Player/PlayQueue.swift`)

```
enum QueueDefinition: Equatable {
    case listing(filter: MediaFilter, kinds: MediaKinds, ordering: MediaOrdering)
    case tag(id: UUID, name: String)
    case history
    case explicit(name: String)          // Review compare, Recently Watched rows, selections
}

enum QueueSort: Equatable {
    case definition                      // the order the definition produced
    case fileName, relativePath, fullPath
    case fileSize(ascending: Bool), duration(ascending: Bool)
    case random(seed: Int)
}

@Observable @MainActor final class PlayQueue {
    let definition: QueueDefinition
    let title: String
    private(set) var items: [MediaItem]          // the snapshot, definition order
    var sort: QueueSort = .definition
    var requiredTagIDs: Set<UUID> = []           // the rail's narrowing (AND)
    private(set) var tagCounts: [UUID: Int]      // over `items`, for the rail
    var visible: [MediaItem]                     // items ∩ narrowing, sorted
    func refresh(using library: LibraryDatabase) throws     // re-run definition; keeps sort + narrowing
    func recount(using library: LibraryDatabase) throws     // tags changed; counts + narrowing follow
    static func make(_ definition: QueueDefinition, title: String, library: LibraryDatabase) throws -> PlayQueue
}
```

- `refresh` re-runs the definition: `.listing` → `mediaItems(matching:kinds:orderedBy:)`
  with the stored filter/kinds/ordering; `.tag` → `items(withTag:)`;
  `.history` → `recentlyWatched()`; `.explicit` → re-fetch the same ids,
  dropping any that no longer exist. Narrowing tags that no longer occur
  are dropped from `requiredTagIDs` after a refresh.
- `visible` sorts in memory over `items`; `.random` uses the stored seed
  so the order is stable until Shuffle is chosen again.
- `recount` runs a new Kit query `tagCounts(forItems: [UUID]) -> [UUID: Int]`
  (`BrowseCounts.swift`), and re-derives `visible`. Called on
  `.sasLibraryDataChanged` for the queue's library and after the
  player's own tag edits.

### PlayerRequest and PlayerModel

- `PlayerRequest` gains `definition: QueueDefinition` and `title`; the
  `playlist` array stays as the snapshot's initial ids so existing
  callers keep working, but the player never receives a new playlist
  from outside again.
- `PlayerModel` owns `let queue: PlayQueue`. `playlist` becomes
  `queue.visible.map(\.id)`; `queueItems` becomes `queue.visible`.
  `updatePlaylist(_:)` is deleted, and `PlayerView`'s
  `.onChange(of: browse.visibleItems)` with it.
- Walking: next/previous move within `visible`. If the playing item is
  hidden by the narrowing it keeps playing; next goes to the first
  visible item after its position in `items`, previous to the last
  before it.
- `refreshQueue()`: `queue.refresh`; if the playing item is no longer in
  `items` it keeps playing (a Refresh is not a stop), and next/previous
  start from the top/bottom of `visible`.
- The analysis session's `position` reads from `visible`.

### The queue panel (PlayerView)

The existing strip gains a header row: the queue title, `n of m` when
narrowed, a Sort menu (`QueueSort` choices, Shuffle / Reshuffle), a Refresh button (also ⌘R while the player owns the window), and a
Rail toggle. The strip shows `visible`, the current item ringed as now.

### The rail (new `QueueRailView`, a left panel of the player)

A compact version of the sidebar's category sections: categories in
sort order, each listing only the tags that occur on `items`, with the
count over `items`; zero-count tags are absent, not struck (a tag not on
the queue is not a choice). Clicking a tag toggles it in
`requiredTagIDs`; the section header shows the active count and a Clear.
Counts and membership recompute on `recount`, so a tag applied in this
player appears in the rail at once. No sources, folders, saved filters,
status or media-type sections: those define queues, they do not narrow
one.

Panel state: `PlayerPanels.rail`, persisted like the others, default on
in aux player windows and off in the library window (whose sidebar
already occupies the left; it drives the grid, and Refresh takes the
grid's current definition into the player's queue).

### Definitions per entry point

| Entry point | Definition | Title |
|---|---|---|
| Grid double-click, Play selection | `.listing(filter, kinds, ordering)` at that moment; `playlist` = visible ids | the library window's filter summary, or "All items" |
| Tag Pivot ("show all with this tag") | `.tag(id, name)` | "Tag: name" |
| Recently Watched row | `.history` | "Recently Watched" |
| Review compare, Operations preview | `.explicit(name)` | as today |

Refresh in the library window re-reads the browse model's current
filter/kinds/ordering into a new `.listing` definition first, so the
player's queue catches up with what the grid shows. Everywhere else
Refresh re-runs the stored definition.

### History

The History player's queue re-runs `recentlyWatched()` when another
player loads an item (the change broadcast carries a sender token; a
History queue ignores its own player's token) and on Refresh. The
database keeps one row per item, so a video watched twice is one row
carrying its latest date; a per-viewing timeline is a separate table and
out of scope here.

## Keys

- Refresh: ⌘R in a player, and the strip's header button. (F5 is a
  bindable tag key already.) Sort and Shuffle: the panel header menu only.
- Existing playlist keys (arrows, Shift+arrows) walk `visible`.

## Error handling

- A definition that fails to run leaves the previous snapshot in place
  and shows the error in the player's existing banner path.
- A queue whose refresh returns nothing keeps the playing item playing
  and shows an empty strip with "Nothing matches — Refresh again later."

## Testing (app test target unless noted)

- `PlayQueue`: snapshot taken once; `visible` under narrowing and each
  sort; random sort stable for a seed; refresh keeps sort and narrowing
  and drops vanished narrowing tags; recount after a tag change.
- `PlayerModel` walking under narrowing: next/previous skip hidden
  items; a hidden playing item keeps playing.
- Kit: `tagCounts(forItems:)` counts only the given items.
- The clobbering defect: a player opened with an explicit queue in a
  browse model whose listing later changes keeps its queue (regression
  test on the model; today it fails).

## Delivery

1. `feature/play-queues` — `PlayQueue`, `QueueDefinition`, the
   `PlayerModel` switch to a snapshot, Refresh (button, ⌘R), the
   regression test. This alone fixes the clobbering and freezes queues.
2. `feature/queue-sort` — the Sort menu and Shuffle on the snapshot.
3. `feature/queue-rail` — `tagCounts(forItems:)`, `QueueRailView`, the
   panel toggle, recount on change.
4. `feature/history-queue` — the History player's live re-run rules.

Each off dev, in order; 2–4 depend on 1 having merged.

## Out of scope

- Named or persisted queues; queues outliving their window.
- A per-viewing history timeline table.
- Drag-to-reorder within a queue.
