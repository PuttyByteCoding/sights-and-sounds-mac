# Copy audit — the verbatim strings, against the code

Run 30 August 2026 against `dev` at `47220ed`, covering the fourteen built specs
(01–13 and 16). Specs 14 and 15 are deliberately unbuilt and were skipped.

Each spec's *Copy — verbatim* section marks exact strings. This checks whether they
are actually in `Sources/`.

## Method, and what it cannot tell you

Every backticked string in a *Copy — verbatim* section, of at least fourteen
characters and containing a space, was compared against the concatenated Swift
sources with whitespace collapsed — so a literal broken across lines by the
formatter still matches.

Three limits worth knowing before acting on the numbers:

- **A string assembled from fragments reads as missing.** Swift building a
  sentence from two literals, or through a helper, cannot match.
- **Templates cannot match literally.** A spec line like `<n> songs · <n> clips`
  is interpolated in Swift. Those are checked by their longest placeholder-free
  run instead, and a run under fourteen characters is not checked at all.
- **Presence is not correctness.** A string can exist and be shown in the wrong
  place, or never be shown.

So the exact-match count is a floor, not a verdict. The clustered absences below
are the part that is load-bearing.

## Headline

| | count |
|---|---|
| Strings checked | 280 |
| Present exactly | 211 (75%) |
| Case-only difference | 2 |
| Absent entirely | 42 |
| Templates whose fixed fragment is also absent | 25 |

| Spec | checked | absent | template |
|---|---:|---:|---:|
| 01 — library picker | 8 | 2 | 0 |
| 02 — browse window | 10 | 0 | 2 |
| 03 — player | 16 | 2 | 2 |
| 04 — categories and fields | 24 | 0 | 5 |
| 05 — import | 21 | 0 | 1 |
| 06 — background tasks | 22 | 0 | 1 |
| 07 — review | 29 | 6 | 5 |
| 08 — operations | 33 | 2 | 2 |
| 09 — organise | 22 | 2 | 3 |
| 10 — maintenance | 28 | 3 | 1 |
| 11 — new library | 27 | 11 | 0 |
| 12 — library properties | 12 | 1 | 0 |
| 13 — settings | 22 | 15 | 2 |
| 16 — command palette | 6 | 0 | 1 |

## 1. Two sub-features of built specs were not built

This is the finding. Twenty-two of the forty-two absences are not drifted wording —
they are copy for screens that do not exist.

**Spec 11's migration flow.** Eleven strings, and `NewLibraryView.swift` contains no
occurrence of "migrate" in any case. The spec covers both creating a library and
migrating an old one; the commit that landed it (`f41e22e`) is titled *"New library:
configure at creation, not after it"*, and the migration half went with it.

> `Migrate Library` · `Map the old root to a source` · `Verify the counts` ·
> `Name the library the snapshot becomes` · `Nothing has been written yet.` ·
> `quality analyses` · `Rename or exclude anything. Nothing is written until Create.` ·
> `One SQLite file, its own vocabulary, never shared with another library.` ·
> `Ownership is a foreign key now, not a path prefix — so relocating this folder later updates one row instead of every item under it.` ·
> `Read back from the new library and compared against the snapshot. A mismatch here means the migration is wrong, and it is cheaper to know now than after you have used it.` ·
> `All of it recomputes from disk on first run. Analysis rules are authored rather than derived, so those do migrate.`

**Spec 13's category-order pane.** Eleven strings, and no `categoryOrder`,
`globalOrder`, or "Category Order" symbol exists anywhere in `Sources/`. There is a
comp for it — `Mac Settings Category Order.dc.html`. Spec 12 also points at it
(*"View the full configuration in Settings → Tag Category Configuration"*), which is
itself one of the absences, so the dangling reference is visible from two directions.

> `On. Every surface follows the global order and cannot be rearranged on its own. Divergent orders are remembered, not discarded — unlock to get them back.` ·
> `Off. The global order is a starting point; any surface can be dragged into an order that suits the work done there.` ·
> `Locked. Each surface shows the global order and cannot be rearranged here.` ·
> `Drag within a surface to give it its own order. The browse sidebar and the player rarely want the same one — you filter by Venue and tag by Band.` ·
> `filter panel — ordered by what you filter on most` · `tagging — ordered by what you type first` ·
> `pre-staged on a batch — ordered by what a whole folder shares` · `creating or migrating a library` ·
> `following global` · `all matching global` · `locked to global`

Neither is a defect in what was built. Both are scope that the spec claims and the
code does not have, which is worth recording before the specs are read as done.

## 2. Spec 07's operation-log promise is not kept

Four of spec 07's six absences are the safety block, and one of them states a
behaviour that does not exist:

> `Both are written to the operation log and revert from there.`

The operation log is `FileMoveLog` (spec 07 line 71). Only `moveFile(itemID:to:)`
writes an entry. `RepairJob` calls `LibraryDatabase.moveWithRetries` directly, twice,
so a repair's archive move never reaches the log and cannot be reverted from it.
`RemuxJob` calls it the same way. There is no `OperationLog` type — the only log
types in the Kit are `FileMoveLog` and the diagnostic `AppLog`.

Also absent from spec 07: `Repaired and re-probed — plays cleanly`,
`Every repair works on a copy, archives the original, and re-probes before replacing anything.`,
`0 tags or field values lost — a kept duplicate inherits them`, and
`Nothing staged. Decisions collect here and apply together, so a batch can be reviewed before anything touches a file.`

## 3. The Repair pane shows labels without their explanations

`RepairRecipe.Risk.displayName` gives `Lossless — stream copy` and
`Last resort — re-encodes`, both present. The sentences spec 13 pairs with them are
not:

> `Nothing is re-encoded — the fastest and only lossless option. Prefer these first.` ·
> `Rewrites the affected stream. Costs time and a generation of quality.` ·
> `Salvages what decodes and loses the rest. The queue shows these last and never auto-selects them.` ·
> `Added, disabled until you have tested it`

The pane names the risk without saying what it costs, which is the half that decides
whether someone runs the fix.

## 4. Case drift — two, and one of them is the spec's fault

| Spec says | Code says | Where |
|---|---|---|
| `No Pending Duplicates` | `No pending duplicates` | `ReviewView.swift:248` |
| `Restore embedded tags` | `Restore Embedded Tags` | `ItemGridView.swift:212` |

The second is a **menu item**, and macOS capitalises menu items in title case. The
code is right and the spec should change. The first is an empty-state title where
either reading is defensible. Neither was changed here — a mechanical sweep that
overrides platform convention is worse than the drift.

## 5. Remaining scattered absences

- **01** — the two side-by-side/reuse explanations from the second-library prompt.
- **03** — `A bound key toggles its tag on the playing item. Only keys the fixed map leaves free are offered.` and the hide-block hint.
- **08** — `Name order. Rename the files if you need a different one.` and the join-codec refusal.
- **09** — `empty folder name`, and the token help text.
- **10** — `the row exists, the file is gone`, `on disk, no row — never imported`.

## 6. Templates worth a manual look

Most template misses are short interpolations the checker cannot validate. These
five have a fixed fragment that is genuinely absent:

- **02** — both offline-source sentences (`— tags, fields and thumbnails are local and current…`, `are hidden. Their tags, fields and thumbnails are local and still current.`)
- **04** — the window title `Categories & Fields — <Library>`
- **07** — `<n> files removed from disk`, `<size> space reclaimed`
- **09** — `No category called "<Name>" — check the spelling, or create it in Categories & Fields.`

## What this does not cover

Presence only. Nothing here checks that a string is shown on the right screen, at
the right moment, or at all. A pass that reads each spec's *Layout* section against
the view would catch a different and probably larger class of drift.
