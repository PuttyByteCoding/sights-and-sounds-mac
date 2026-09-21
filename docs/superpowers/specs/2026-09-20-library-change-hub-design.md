# Library change hub

*2026-09-20. Follows the under-the-hood review of the same week.*

## The problem

Nothing in the app says "this library's data changed". Every window learns
about a change one of two ways:

1. It made the change itself and then calls `BrowseModel.refreshAll()`.
   There are 37 such calls. Each one reloads the whole library: sources and
   a reachability check per source, the vocabulary, every alias, a folder
   tree per source, the counts, the saved filters and a count per saved
   filter, and then the listing with its faceted counts.
2. Another `BrowseModel` finished a `refreshAll()` and posted
   `sasLibraryDataChanged`. So the signal means "a browse model refreshed",
   not "data changed".

What follows from that:

- **Writes that are not made by a browse model are invisible.** The player
  writes tags, flags, aliases and category order and never posts, so the
  sidebar beside the player is stale until Back is pressed. A standalone
  player window never tells the main grid anything. A background import
  adds items and the grid does not move until something else refreshes it.
- **Non-writes broadcast.** Toggling media kinds is view state, but it runs
  `refreshAll()`, which posts, which makes every other window reload.
- **Forgetting the call is a silent bug.** Every new write site has to
  remember it. Several views that write directly (`TagActions`,
  `CategoryInspector`) get it right only because a closure was threaded
  through to them.
- **Cost scales with windows.** Each auxiliary window builds its own
  `BrowseModel` with a full listing it never draws, and each of those
  reloads on every broadcast.

## The idea

Let the database say what changed. SQLite knows, per committed transaction,
which tables and columns were written, and GRDB exposes that as
`DatabaseRegionObservation`. One observer per library, in the kit, turns
commits into a small vocabulary of *domains* and hands them to whoever
subscribed. No write site has to do anything, including the ones that do
not exist yet, and including jobs.

```
any write, anywhere ──commit──▶ LibraryChangeHub ──(coalesced)──▶ subscribers
  (model, view, job, player)     domains: [.tagging]               BrowseModel, PlayerModel, …
```

## Domains

A domain is "a kind of thing a window might be showing". They map to tables:

| Domain | Tables | Who cares |
|---|---|---|
| `items` | `mediaItem`, listed columns only | listing, counts, folder trees |
| `tagging` | `mediaItemTag`, `mediaItemFieldValue` | listing pills, counts, faceted counts, the player's tag panel |
| `vocabulary` | `tagCategory`, `tag`, `tagAlias`, `fieldDefinition`, `tagKeyBinding` | sidebar, tag panel, Tag Manager |
| `sources` | `source` | sidebar sources, online state, folder trees |
| `savedFilters` | `savedFilter` | sidebar saved filters |
| `duplicates` | `duplicateCandidate` | pending count, tile duplicate flags |
| `itemDetails` | `videoBlock`, `embeddedTagSnapshot`, `ocrTextLine` | tile menu facts, the player's blocks |

Deliberately **not** observed: `job` (progress is written many times a
second and has its own polling surface), `fileMoveLog`, `pendingMove`, the
sweep bookkeeping tables, `libraryInfo`.

### The listed columns of `mediaItem`

`mediaItem` is written constantly by things no listing shows: the hash
sweep sets `contentHash` per file, and the player writes
`resumePositionSeconds`, `lastWatchedAt` and `watchCount` on every pause
and load. Observing the whole table would turn a background sweep into a
refresh storm. GRDB tracks regions at column granularity for `UPDATE`, so
the `items` domain observes every column **except** those four. The list
is computed from the table at start-up (all columns minus the excluded
set), so a column added by a later migration is observed by default.
Inserts and deletes always count.

`History` is the one surface that shows `lastWatchedAt`; it already has its
own signal (`sasPlaybackDidLoad`) and keeps it.

## Coalescing

A reorganize commits thousands of transactions. The hub unions the domains
of every commit into a pending set and delivers it once, 100 ms after the
first change of a burst, then starts again. A subscriber therefore sees at
most ten deliveries a second however fast the writer goes. Delivery is on a
private serial queue; subscribers hop to their own actor.

## Subscribers

### `BrowseModel`

Subscribes at init; the subscription ends with the model.

- **Step 1 (this PR):** any relevant domain schedules one `refreshAll`. The
  NotificationCenter broadcast, its self-sender token and the `broadcast:`
  parameter go. Explicit `refreshAll()` calls after a write stay for now:
  they give an immediate refresh, and the hub's delivery that follows is
  dropped when a refresh has *begun since the change was committed* (it
  necessarily read that commit). So a model's own write costs one refresh,
  as today, and everyone else's costs one where it used to cost none.
- **Step 2:** `refreshAll` splits by domain. `sources` reloads sources,
  online state and trees. `vocabulary` reloads vocabulary, aliases, counts.
  `items` and `tagging` reload counts, trees and the listing. `savedFilters`
  and `duplicates` reload just those. Kind toggles reload what depends on
  kinds and broadcast nothing, because nothing was written.
- **Step 3:** the explicit calls after writes are deleted, site by site,
  each with the hub as its replacement. Mount/unmount still calls a sources
  refresh directly: a drive appearing is not a database change.

### `PlayerModel`

`vocabulary` and `tagging` refresh the tag panel and recount the queue;
`itemDetails` refreshes blocks. This replaces its `sasLibraryDataChanged`
observer, and is what finally lets a Tag Manager rename reach an open
player.

### Auxiliary windows

Out of scope here, but the hub is what makes it possible: a window that
draws no grid can hold a light model that subscribes to only the domains
it shows, instead of a full `BrowseModel`.

## What this does not do

- It does not make refreshes cheaper by itself. Step 2 does that.
- It does not observe other processes. One app, one pool per library.
- It is not `ValueObservation`. That re-runs a fixed query and hands back
  values; the browse queries depend on the filter, kinds and ordering of
  each window, so the hub only says *that* something changed and each
  window asks its own question.

## Testing

Kit tests drive the hub with real writes on an in-memory library:

- a tag assignment delivers `tagging` and nothing else;
- a vocabulary edit delivers `vocabulary`;
- writing a content hash or a resume position delivers nothing;
- an insert into `mediaItem` delivers `items`;
- fifty commits in a burst arrive as one or two deliveries whose union is
  right;
- a cancelled subscription hears nothing more;
- a job table write delivers nothing.

App tests: a `BrowseModel` sees an item that was inserted behind its back,
and a tag assigned through the kit directly, without anyone calling
`refreshAll`.

## Risks

- **Refresh storms from a domain I have misjudged.** Mitigated by
  coalescing and by the generation guards the models already have; visible
  in the existing `browse` timing log lines.
- **A missed domain** means a window that does not update, which is
  today's behaviour for that write, not a regression.
- **Ordering.** The hub delivers after commit, and a refresh reads after
  that, so a refresh never reads a state older than the change it answers.
