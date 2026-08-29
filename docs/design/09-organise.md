# 09 — Organise

**Comp:** `Mac Organise.dc.html`
**Swift:** `Browse/ReorganizeView.swift`, `Organization/OrganizeTemplate.swift`,
`Organization/MoveService.swift`, `Organization/FileMoveLog.swift`,
`Browse/LibraryMaintenanceViews.swift` (`MoveHistoryView` ~5)

## What changes

Both halves exist and are correct: `ReorganizeView` validates a template, previews a plan,
and names a skip reason per item; `MoveHistoryView` lists every logged move with a Revert.
They are two separate sheets, and neither shows the shape of the result.

They become one window with two tabs — **Reorganise** and **Move history** — because the
history is the reason the plan is safe to run, and they should not be two things to find.

## Decisions

1. **The preview is the feature.** Every item resolves live as the template is typed. An item
   that cannot resolve says **which tag it is missing** and stays where it is —
   `OrganizeTemplate` already returns `missingToken` for exactly this, and there is no
   `Unknown/` folder anywhere in the design. Skipped items need nothing undone: tag them and
   run again.

2. **Show the plan two ways.** The row list answers "what happens to this file"; a **folders
   this creates** list, with a count per folder, answers "what will my drive look like" —
   which is the actual question a template is being written to answer. Same plan, grouped.

3. **Skip reasons aggregate; skipped rows do not disappear.** The sidebar counts reasons
   (`6 · no Band tag`, `2 · source offline`) so a template's weakness reads at a glance,
   while the row list still shows every item so an individual one can be found.

4. **Tokens are inserted, not memorised.** A chip per category writes `%Band` (underscores for
   spaces) into the field. An unknown token is a validation error naming the category and
   pointing at Categories & Fields — `OrganizeTemplate.validate` already produces the error;
   this gives it somewhere useful to point.

5. **Every move is logged individually — never a capped log.** `moveLogs(limit: 200)` is a
   display default; the *rows* must be complete, or a large run contains moves that happened
   and cannot be put back. This is what makes a bad template one session to undo rather than a
   restore from backup.

6. **History groups by session, and reverts either way.** A run is the unit a person thinks
   in ("that `%Venue` thing I did on Monday"), so the card carries the template, when, a
   summary and **Put all back**; individual rows keep their own **Put back**. `FileMoveLog`
   has no session column today — group by template + a movedAt window, or add one (below).

7. **Reverting is one-shot, and the record survives it.** A reverted row keeps its from → to
   with the destination struck through, because the log is the evidence the move happened,
   not a description of where the file is now. Sessions read **applied · partly reverted ·
   fully reverted**, so a half-undone run is never mistaken for a clean one. `revertMove`
   already refuses a second attempt (`alreadyReverted`).

8. **Scope is the current filter, and it says so.** `previewReorganize` runs against
   `model.items` — the filtered listing. State that in the header (`applies to the N items in
   the current filter`) rather than leaving someone to discover that their filter was the
   selection.

## Model changes

| Change | Why | Where |
|---|---|---|
| `sessionID` on `FileMoveLog` (nullable) | §6. Grouping by heuristic works until two runs share a template within a minute. Staging moves carry none, and read as their own single-move sessions. | `Organization/FileMoveLog` |
| Folder-shape summary from a plan | `[folder: count]` derived once from the plan, not recomputed per render. | `Organization/OrganizeTemplate` |
| `revertSession(_:)` | Put all back, one transaction, skipping already-reverted rows rather than throwing on the first. | `Organization/MoveService` |

Standard-field tokens (`%ARTIST` resolving through write-back mappings) are noted as a Phase 8
follow-on in `OrganizeTemplate`'s header. Not this spec — but the token chips should not
imply the set is complete either; they list categories, which is what they are.

## Layout

Window `1240 × 842`. Tabs plus a mono headline that changes per tab.

**Reorganise.** Template block at the top: the field in mono amber at 14 px on `#0F0C07` with
a `#4A3C24` border (it is the most important control in the window and reads as one), token
chips beneath, the rule as a one-liner, and the validation error inline with a red dot.

Plan table `20 / 1fr / 1fr` — status dot, filename over its current folder, destination.
Movable rows: destination in `#8FCF8F`. Skipped rows: `stays where it is` in grey on a
`#151109` band, with the reason beneath in `#C9884A`. Header and body both
`scrollbar-gutter: stable`.

Sidebar 300 pt: **THIS PLAN** (three counts, mono, sized 15 px), **WHY ITEMS ARE SKIPPED**,
**FOLDERS THIS CREATES** (mono paths, count right), then the apply button and the one-line
promise about logging.

**Move history.** One card per session: template in mono amber, when, summary, state chip,
**Put all back**. Rows `1fr / 190 / 18 / 190 / 92` — name, from, arrow, to, action. Reverted
rows at 60% with the destination struck through.

## Copy — verbatim

| Element | String |
|---|---|
| Tabs | `Reorganise` · `Move history` |
| Headline, plan | `applies to the <n> items in the current filter` |
| Headline, history | `<n> sessions · <n> moves logged` |
| Template note | `A token names a category; underscores stand in for spaces. Anything else is literal, and a slash makes a level.` |
| Unknown token | `No category called "<Name>" — check the spelling, or create it in Categories & Fields.` |
| Literal chip help | `Anything not starting with % is used literally — Shows/%Year works` |
| Plan stats | `items would move` · `skipped, left untouched` · `folders created` |
| Skip reasons | `no <Category> tag` · `source offline` · `empty folder name` |
| Skip note | `A skipped item is left exactly where it is. Tag it and run the plan again — nothing has to be undone first.` |
| Destination, skipped | `stays where it is` |
| Apply | `Move <n> items` / `Nothing to move` |
| Apply note | `Runs as a background job. Each move is logged individually, so a bad template is one session to put back rather than a restore from backup.` |
| Applied toast | `<n> moves queued — each one logged and revertible` |
| Session states | `applied` · `partly reverted` · `fully reverted` |
| Revert buttons | `Put all back` · `Put back` |
| Revert note | `Reverting is one-shot per move — a move that has been put back cannot be put back again, and the entry stays as the record that it happened.` |
| History empty | `No Moves Yet` / `Staging, reorganization and manual moves appear here, each revertible.` *(existing)* |
| Existing blurb | `Tokens name your categories (%Band, %Year — underscores for spaces). Applies to the current filtered items; every move is revertible from Move History.` *(existing)* |

## Keep from the existing view

`OrganizeTemplate`'s ported rules, all of them, and the reasons in its header comment:
first-value-**ordinally** for multi-value tags (locale-independent on purpose — the same tags
must build the same path on every machine), per-segment sanitisation, the 200-character cap,
and the extension staying the caller's business. `MoveService`'s move discipline: through the
`FileAccess` boundary, never overwriting (collisions take a timestamp suffix), six retries for
transient IO, path triplet updated, log row written. `FileMoveLog` having **no foreign key** and
a snapshotted `fileName`, so history outlives a purged item. Validation blocking apply, and
apply moving only the resolvable subset.
