# Spec audit — copy and layout, against the code

Run 30 August 2026 against `dev` at `47220ed`, covering the fourteen built specs
(01–13 and 16). Specs 14 and 15 are deliberately unbuilt and were skipped.

Two passes, with opposite results. **Part A** checks each spec's *Copy — verbatim*
strings and finds two sub-features that were never built. **Part B** checks each
spec's *Layout* measurements and colours and finds essentially nothing wrong.

---

# Part A — Copy

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

## What Part A does not cover

Presence only. Nothing here checks that a string is shown on the right screen, at
the right moment, or at all.

---

# Part B — Layout

The *Layout* sections carry two things a machine can check: **pt measurements**
(`Queue rail 262 pt`) and **hex colours** (`#17130E`). Each spec's measurements were
checked against the Swift files that **that spec's own landing commit touched** —
so spec 07's numbers are checked against spec 07's files, not the whole app.
Colours were checked against all of `Sources/`, because the palette is central:
specs write `#17130E`, `Theme.swift` writes `Color(hex: 0x17130E)`.

Thirteen of the fourteen specs have a `## Layout` section. Spec 02 does not — it
predates the five-part template, as doc 00 records ("specs 01 and 02 were written in
an earlier session"), and organises its content as numbered decisions instead. That
is a format difference, not a gap.

## Result

| | |
|---|---|
| pt measurements checked | 25 |
| absent from the spec's own files | **0** |
| hex colours checked | 46 |
| present verbatim | 38 |
| not verbatim, but near an existing token | 8 |

**Layout adherence is high.** Every measurement a spec names appears in the files
that spec's commit produced, and no colour is missing because an element was never
built — which is exactly the failure Part A found on the copy side.

## The eight colours

None is absent. Each is close to a colour already in `Theme.swift`, which is what a
token pass looks like: the comps carry per-screen hexes and the theme normalises
them into one palette.

| Spec | Spec hex | Nearest in `Theme.swift` | Distance |
|---|---|---|---:|
| 04 | `#141109` | `0x131009` | 1 |
| 09 | `#151109` | `0x151209` | 1 |
| 11 | `#1C1710` | `0x1A1610` | 2 |
| 08 | `#251512` | `0x221D16` | 9 |
| 06 | `#3E2A22` | `0x3A2C18` | 10 |
| 08 | `#4A2A24` | `0x4A3C24` | 18 |
| 08 | `#C9857A` | `0xD07A6A` | 20 |
| 11 | `#2F4A2F` | `0x443E34` | 24 |

The first five are rounding — the spec and the token are the same colour to the eye.
The last three are worth a glance rather than a change: two are spec 08's destructive
pair, and `#2F4A2F` is a dark green whose "nearest" neighbour is a brown, because
straight RGB distance crosses hues freely. The palette does have greens
(`Theme.Status.green = 0x6FB86F`), so the question there is which treatment the
success chip actually got, not whether green exists.

## What Part B does not cover

The measurement check is weak in one direction on purpose: finding `262` somewhere in
a spec's files does not prove it is the width of the queue rail. **Absence is the
signal; presence is only weak evidence.** Structural claims — element order, what
pins to which edge, which panel is where — are not checked at all and would need
reading each view against its spec by hand.

One method note, recorded because it nearly produced a false report: the first run
of this check flagged *all 46* colours as missing. The comparison uppercased the
Swift source, turning `0x` into `0X`, so no hex could ever match. It was caught only
because `#17130E` had already been confirmed by hand. A tool that reports everything
as broken is usually broken itself.
