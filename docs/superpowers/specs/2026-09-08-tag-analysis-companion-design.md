# Tag Analysis as a companion to the player

Date: 2026-09-08. Status: design, awaiting review. Supersedes the window
described in `docs/design/14-tag-analysis.md` §Layout (Candidates rail
and queue strip); that spec is rewritten in the delivering PR.

## Goal

Tag Analysis stops being a self-contained window with its own player,
queue and basket. It becomes a companion window that follows one player
window: the video plays there, tagging happens there, and the companion
shows the evidence and the decisions for whatever that player is
showing. The player's tag panel gains a "Tag Analysis Results" field
that applies the tags the analysis found, from the keyboard.

## Decisions (already made)

- **Follows the player it was opened from.** One companion per player
  session; opening Tag Analysis from another player re-points it. If the
  followed player closes, the companion says so and offers Close.
- **Analysis runs only while the companion is open.** With it closed, no
  scan runs on load, and the player's results field is dimmed with a hint.
- **Accepting applies immediately.** No basket, no commit step, in the
  companion or in the player's field. The player's next/previous simply
  moves on.
- **Entry points open the player first.** The player's toolbar gets a Tag
  Analysis button. The browse toolbar button, the tile's right-click
  entry, the command palette and the View menu open the player at that
  item, then the companion.
- **Removed from the companion:** the preview player and its transport,
  the numpad monitor, the Universal field, Applied tags, Candidate tags,
  the queue thumbnail strip, the basket and This pass's basket rows.
- **Numpad 8 focuses the Universal field** (own PR, before this work):
  top-row 8 and numpad minus keep seeking to near the end.

## Architecture

### TagAnalysisSession (new, `Sources/SightsAndSoundsApp/TagAnalysis/`)

An `@Observable @MainActor` object the player creates when the companion
is requested and registers in `AppModel` under a fresh `UUID`.

```
final class TagAnalysisSession {
    let id: UUID
    let libraryID: UUID
    let library: LibraryDatabase
    // Written by the player:
    private(set) var itemID: UUID?          // what the player is showing
    private(set) var position: (Int, Int)?  // "3 of 41" from the playlist
    private(set) var playerIsOpen: Bool
    var apply: (Tag) -> Void                // installed by the player
    var step: (Int) -> Void                 // ±1: the player's next/previous
    // Written by the companion:
    private(set) var analysis: ItemAnalysis // .empty when closed
    private(set) var companionIsOpen: Bool
}
```

- The player updates `itemID`/`position` on every load and playlist
  change; sets `playerIsOpen = false` in `shutdown()`.
- `apply` calls a new `PlayerModel.applyTag(_ id: UUID)`: assign (not
  toggle), record in the session history, `refreshTagging()`. Every apply
  from either window goes through it, so the panel and the up-arrow
  history stay right without a broadcast.
- The companion sets `analysis` after each reload and clears it and
  `companionIsOpen` on close.
- `AppModel.analysisSessions: [UUID: TagAnalysisSession]`. A session is
  removed when both sides are closed. A restored companion window whose
  id is unknown (relaunch) shows "The player this window follows has
  closed" and Close; it never creates a player.

### AuxWindowRequest

`Kind.tagAnalysis` gains `sessionID: UUID?`. `itemIDs`/`startIndex` are
no longer used for this kind (kept decodable for saved window state).

### TagAnalysisModel (rewritten around the session)

Loses: `queue`, `index`, `currentItem` walking, the preview player and
every `preview*` member, `handlePreviewKey`, the basket (`basket`,
`stage`, `unstage`, `updateStaged`, `discardBasket`, `commitBasket`,
`isStaged`), `tagSearchIndex`, `appliedTags`.

Keeps: `analysis`, rules, categories, table rows, filters, search text,
selection, Reader I/O, ignore/hidePrefix/alias rules, sweep on demand,
`tagsCommittedThisPass` (renamed `tagsAppliedThisPass`),
`videosVisitedThisPass`, `markCurrentAnalyzed`.

Gains: `init(session:)`; observes `session.itemID` (withObservationTracking
loop, or `onChange` in the view calling `model.follow()`); on change:
mark the departed item analyzed, bump visited, clear selection/search,
reload. `applyNow(_ tag: Tag)` → `session.apply(tag)`, bump the tally,
reload so "Already applied" chips update. `applyNew(value:categoryID:)`
→ `library.ensureTag` then `applyNow`. Reload writes `session.analysis`.

### The companion window (TagAnalysisView)

- Header: mode control (Candidates · Rules · Schemas), headline, and the
  position text "3 of 41" from the session. Shift+← / Shift+→ call
  `session.step(∓1)`.
- Rail: evidence sources, Reader I/O, status filters, This pass (tags
  applied · videos visited). Width still persisted (`tagAnalysisRailWidth`).
- Centre: the table and the decide pane unchanged, except: the primary
  button reads "Apply" and applies at once; "Apply existing" applies;
  quick-accept applies. No "In basket" state; "Already applied" stays.
- No queue strip. No numpad monitor.
- Player gone: a centred state "The player this window follows has
  closed." with a Close button, replacing the content.

### The player: "Tag Analysis Results" field (TagPanelView)

- A pseudo-field row like Universal: heading "Tag Analysis Results" with
  the ≡ grip, position persisted as `AppSettings.analysisResultsFieldPosition`
  (Int, default: after Universal), part of the Tab walk via a second
  sentinel id in `advanceTagField`.
- Data: `session.analysis.existing` findings not already applied,
  deduplicated by tag, grouped by category order, each row showing the
  tag name and its category as the Universal rows do.
- Behaviour: empty field + ↓ lists every candidate; typing filters with
  the shared fold (all terms must hit name or alias); ↑/↓ move; Enter
  applies via `session.apply`; the list drops the applied tag. Esc clears
  the query, then releases to the video as everywhere else.
- Unavailable: no session, or `companionIsOpen == false` — the row stays,
  dimmed, placeholder "Open Tag Analysis to see results", field disabled.
- A pure `AnalysisResultsField.candidates(analysis:appliedIDs:query:)`
  does the dedupe/filter, tested in the app test target.

### Entry points

- `PlayerView` toolbar: "Tag Analysis" button (and the existing menu item
  moves to it). It creates or reuses the player's session and opens the
  aux window with `sessionID`.
- Browse toolbar, tile right-click, command palette, View menu: set the
  library window's `playerRequest` at the item (toolbar/menu/palette: the
  first visible item; tile: that item), then open the companion for the
  player's session once the player has created it. Implementation: the
  `BrowseModel` carries `pendingAnalysisOpen = true`; `PlayerView` reads
  it on model creation and opens the companion.
- The Tag Pivot player windows get the same toolbar button.

### Keys

- Numpad 8 → `PlayerAction.focusUniversalField` (own PR). In the player:
  open the tag panel if closed, zone = tags, `tagFieldCategoryID =
  universalFieldFocusID`. Unchanged in the companion (no video there).
- The companion's Shift+arrows forward to the player. Nothing else.

## Data flow

1. Player loads item → `session.itemID` changes.
2. Companion model observes → marks previous analyzed → reload (rules,
   categories, `analyzeItem` off the main actor) → `session.analysis`.
3. Player's results field reads `session.analysis` and `itemTags` → rows.
4. Enter in the field, or Apply in the companion → `session.apply(tag)`
   → `PlayerModel.applyTag` → `refreshTagging` → rows recompute; the
   companion reloads so its chips update.
5. Companion closes → `session.analysis = .empty`, `companionIsOpen =
   false` → field dims. Player closes → `playerIsOpen = false` →
   companion shows the closed state.

## Error handling

- Reload errors show in the companion as today (`loadError`).
- Apply errors surface in the player's `loadError` banner path, and the
  companion shows the same message in its header.
- A stale `sessionID` (relaunch, or the player closed before the window
  opened) renders the closed state, never a crash or an empty analysis.

## Testing

App test target (`SightsAndSoundsAppTests`):
- Session: item change on the session triggers exactly one reload in a
  companion model; `analysis` lands on the session; close clears it.
- `applyNow` calls the installed hook once and bumps the tally.
- `AnalysisResultsField.candidates`: dedupe, applied exclusion, category
  grouping, term filtering with aliases, empty query lists all.
- `advanceTagField` walks Universal → categories → Results in the
  persisted order.

Kit tests: `PlayerKeyMap` numpad 8 → `.focusUniversalField`; top-row 8
and numpad minus still `.seekToNearEnd`.

Everything else (window wiring, drag positions) is verified by the
zero-warning build, both guard scripts and a launch of the bundle.

## Delivery

1. `fix/numpad-8-focus-universal` — the key map change and the player
   handling. Independent.
2. `feature/tag-analysis-companion` — the session, the companion rewrite,
   the entry points, `docs/design/14-tag-analysis.md` rewritten, this spec.
3. `feature/player-analysis-results-field` — the panel field, stacked on
   2 until it merges, then retargeted to dev.

## Out of scope

- Running the analysis with the companion closed.
- A per-companion queue or navigation of its own.
- The grid's queue/order model (parked separately).
