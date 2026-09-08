# History Queue (PR 4) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every video a player loads, even briefly, lands in the watch history at once, and a History player's queue re-runs when another player loads something — never on its own plays.

**Architecture:** A Kit call stamps `lastWatchedAt` on load without touching resume or completion. The player posts a load notification carrying its library and its own token; a player whose queue is the history definition refreshes on that notification unless the token is its own. Refresh (button, ⌘R) works as before.

**Tech Stack:** Swift 6, Foundation notifications, GRDB (Kit), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-09-08-play-queues-design.md` (delivery item 4, "History"). Branch `feature/history-queue`, stacked on `feature/queue-rail` (#224).

## Global Constraints

- Worktree only; zero-warning build; `swift test`; both guards; a bundle launch before pushing.
- Embedded clips are not stamped on load, matching `persistProgress`, which skips them.

---

### Task 1: Kit — stamp the history on load

**Files:** `Sources/SightsAndSoundsKit/Playback/PlaybackProgress.swift` (append `recordPlaybackStart`); test in `Tests/SightsAndSoundsKitTests/WatchHistoryTests.swift`.

**Produces:** `LibraryDatabase.recordPlaybackStart(itemID: UUID, at date: Date = Date()) throws` — sets `lastWatchedAt` only.

- [ ] Test → failure → implement → `swift test --filter WatchHistoryTests` → commit `Kit: a load stamps the watch history`.

### Task 2: The player posts loads; a History queue follows other players

**Files:** `Sources/SightsAndSoundsApp/Player/PlayerModel.swift` (`apply(loaded:url:)`, `init` observer, `shutdown`); test `Tests/SightsAndSoundsAppTests/HistoryQueueTests.swift`.

**Produces:** `Notification.Name.sasPlaybackDidLoad` with userInfo `libraryID: UUID`, `sender: UUID`; `PlayerModel.playerToken: UUID`.

- [ ] Test → failure → implement → `swift test --filter HistoryQueueTests` → commit `Player: the History queue follows other players' loads`.

### Task 3: Docs, verification, PR

- [ ] `docs/design/03-player.md`: after the rail sentence add "A History queue (Recently Watched) is the one live queue: every load anywhere stamps the history at once, and the History player's queue re-runs when another player loads something — never on its own plays — and on Refresh."
- [ ] Verify; commit; push `feature/history-queue`; PR against `feature/queue-rail` (stacked on #224). Report the URL and stop.
