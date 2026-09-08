# Queue Rail (PR 3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A per-player rail that lists only the tags on the queue's items, with counts over the queue, and narrows what the strip and the arrows walk without touching the snapshot.

**Architecture:** A Kit query returns each queue item's tag ids. `PlayQueue` keeps that membership, derives per-tag counts, and applies `requiredTagIDs` before the sort in `visible`. `PlayerModel` recounts after its own tag edits and on the library change broadcast. A `QueueRailView` on the player's left toggles tags; a `rail` panel flag is per window (on for Tag Pivot and other aux players, off in the library window), not persisted, because one global default cannot hold two.

**Tech Stack:** Swift 6, SwiftUI, GRDB (Kit), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-09-08-play-queues-design.md` (delivery item 3). Branch `feature/queue-rail`, stacked on `feature/queue-sort` (#223).

## Global Constraints

- Worktree only; zero-warning build; `swift test`; both guards; a bundle launch before pushing.
- Copy verbatim: rail heading "Narrow"; count line "`n` of `m`"; "Clear"; empty rail "No tags on this queue."
- Zero-count tags are absent from the rail, not struck.

---

### Task 1: Kit — tag membership for a set of items

**Files:** Modify `Sources/SightsAndSoundsKit/Filtering/BrowseCounts.swift` (append). Test `Tests/SightsAndSoundsKitTests/QueueTagMembershipTests.swift`.

**Produces:** `LibraryDatabase.tagIDsByItem(forItems ids: [UUID]) throws -> [UUID: Set<UUID>]` — every given item present (empty set when untagged), nothing else.

- [ ] Tests → compile failure → implement → `swift test --filter QueueTagMembershipTests` → commit `Kit: tag membership for a set of items`.

### Task 2: PlayQueue narrows

**Files:** Modify `Sources/SightsAndSoundsApp/Player/PlayQueue.swift`. Test `Tests/SightsAndSoundsAppTests/PlayQueueRailTests.swift`.

**Produces:**
```swift
extension PlayQueue {
    var requiredTagIDs: Set<UUID> { get set }
    private(set) var tagIDsByItem: [UUID: Set<UUID>]
    var tagCounts: [UUID: Int]                       // over `items`
    var visible: [MediaItem]                          // items with every required tag, then sorted
    func apply(membership: [UUID: Set<UUID>])         // drops required tags that no longer occur
    static func narrowed(_ items: [MediaItem], requiring: Set<UUID>, membership: [UUID: Set<UUID>]) -> [MediaItem]  // pure
}
```
`apply(_ items:)` (a refresh) keeps `requiredTagIDs` until the next `apply(membership:)` prunes them.

- [ ] Tests → failure → implement → pass → commit `Player: a queue narrows its view by required tags`.

### Task 3: The player recounts, and the rail panel

**Files:** `PlayerModel.swift` (`recountQueue()`; call after `loadSnapshot`, `refreshQueue`, `toggleTag`, `applyTag`; observe `.sasLibraryDataChanged` for this library in `init`, remove in `shutdown`; `panels.rail` default from the request), `PlayerView.swift` (left rail in `PlayerContent.body`, ceiling math, `PanelToggles`), `PlayerModel.swift` `PlayerPanel` enum + `PlayerPanels` subscript, `AppSettings.swift` `PlayerPanels.rail` (Codable-tolerant, default false, NOT written back — see below), new `Sources/SightsAndSoundsApp/Player/QueueRailView.swift`.

- `PlayerPanels.rail` is added for the subscript's sake but the view's `onChange(of: model.panels)` persists `layout.panels` with `rail` forced to its stored value, so the per-window default never leaks. Default in `PlayerModel.init`: `panels.rail = { if case .listing = request.definition { false } else { true } }()`.
- `recountQueue()` runs `tagIDsByItem(forItems: queue.items.map(\.id))` off the main actor and calls `queue.apply(membership:)`.
- `QueueRailView`: `model.panelVocabulary` categories in order, each with tags whose `queue.tagCounts[id] > 0`, name order; a row is a button showing the tag name (category hue) and the count; required rows fill amber. Header: "Narrow" · "`visible.count` of `items.count`" · Clear (when any required). Width 200 pt, `Theme.Surface.sidebar`, a 1 pt rule on its right.
- Layout: `HStack(spacing: 0) { if model.panels.rail { QueueRailView() }; leftColumn; ... }`; `effectiveRailWidth`'s ceiling subtracts 200 when the rail is on.
- `PanelToggles` gains `toggle(.rail, "Rail")` first.

- [ ] Build → commit `Player: the queue rail narrows the walk`.

### Task 4: Docs, verification, PR

- [ ] `docs/design/03-player.md`: add after the queue-drawer sentence: "A left **rail** panel (on by default in Tag Pivot and other aux players) lists only the tags on the queue's items with their counts; clicking narrows the strip and the arrows without touching the snapshot."
- [ ] Verify; commit; push `feature/queue-rail`; PR against `feature/queue-sort` (stacked on #223). Report the URL and stop.
