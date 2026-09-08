# Queue Sort (PR 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Sort menu on the queue strip re-orders the snapshot in place — the browse Sort menu's choices plus Shuffle — without re-running the definition.

**Architecture:** `PlayQueue` gains `sort: QueueSort` and `visible`, the snapshot sorted in memory (stable seeded shuffle for `.random`). `PlayerModel.playlist`/`queueItems` read `visible`, so the walk and the strip follow the sort. The strip header gains the menu.

**Tech Stack:** Swift 6, SwiftUI, Observation, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-09-08-play-queues-design.md` (delivery item 2). Branch `feature/queue-sort`, stacked on `feature/play-queues` (#222).

## Global Constraints

- Worktree only; zero-warning build; `swift test`; both guards; a bundle launch before pushing.
- Sort choices and labels mirror the browse Sort menu: Name, Path, File Size (largest first), Duration (longest first), plus "Queue order" (the definition's) and Shuffle / Reshuffle. Full Path is not offered: the snapshot has no source names to group by.
- `.random` is stable for a seed; Shuffle deals a new seed.

---

### Task 1: `QueueSort` and `visible`

**Files:** Modify `Sources/SightsAndSoundsApp/Player/PlayQueue.swift`. Test `Tests/SightsAndSoundsAppTests/PlayQueueSortTests.swift`.

**Interfaces (produces):**
```swift
enum QueueSort: Hashable, Sendable {
    case definition, fileName, relativePath, largestFirst, longestFirst
    case random(seed: Int)
    var label: String
    static func shuffled() -> QueueSort      // fresh seed
    var isShuffled: Bool
}
extension PlayQueue {
    var sort: QueueSort { get set }          // default .definition
    var visible: [MediaItem]                 // items under sort
    var ids: [UUID]                          // visible ids (was items)
    static func sorted(_ items: [MediaItem], by sort: QueueSort) -> [MediaItem]   // pure
}
```

- [ ] Step 1: tests (below). Step 2: watch the compile failure. Step 3: implement. Step 4: `swift test --filter PlayQueueSortTests` passes. Step 5: commit `Player: a queue sorts its snapshot in place`.

### Task 2: The player and the strip menu

**Files:** `PlayerModel.swift` (`playlist`/`queueItems` read `queue.visible`; `publishToSession` unchanged), `PlayerView.swift` (`QueuePanel` header: a Sort menu before the Refresh button).

- [ ] The menu: `Menu { Picker("Order", selection: sortBinding) { Text("Queue order").tag(QueueSort.definition); Text("Name").tag(.fileName); Text("Path").tag(.relativePath); Text("File Size (largest first)").tag(.largestFirst); Text("Duration (longest first)").tag(.longestFirst) }.pickerStyle(.inline); Divider(); Button(model.queue.sort.isShuffled ? "Reshuffle" : "Shuffle") { model.queue.sort = .shuffled() } } label: { Image(systemName: "arrow.up.arrow.down") }` with help "Order this queue — re-sorts the snapshot without re-running it". `sortBinding` maps `.random` to itself so the Picker shows no selection while shuffled.
- [ ] Build, zero warnings; commit `Player: the queue strip's Sort menu`.

### Task 3: Docs, verification, PR

- [ ] `docs/design/03-player.md`: extend the queue-drawer sentence with "and a Sort menu (Name · Path · File Size · Duration · Shuffle) that re-orders the snapshot in place".
- [ ] Verify (build, tests, guards, launch); commit; push `feature/queue-sort`; PR against `feature/play-queues` (stacked on #222, say so). Report the URL and stop.
