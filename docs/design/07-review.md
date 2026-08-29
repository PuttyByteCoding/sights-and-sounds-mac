# 07 — Review

**Comp:** `Mac Review Window.dc.html`
**Swift:** `Browse/DuplicatesView.swift`, `Organization/MoveService.swift` (staging ~134,
purge ~207), `Browse/LibraryMaintenanceViews.swift` (`PurgeButton` ~73),
`Duplicates/DuplicateReview.swift`

## What changes

Three things exist today and are scattered: `DuplicatesView` (pending candidates, side-by-side
compare, `QualityScore` breakdown, tag carry-over — all good and all kept), `PurgeButton` (a
count in a confirmation dialog, no list), and the playback-issue flag (settable from the
player and the grid, with nowhere to go afterwards).

They become one window with three queues — **Duplicates · Delete list · Playback issues** —
because all three are the same shape: a flagged queue, evidence, a decision, and a batch
confirm.

## Decisions

1. **Judging and deleting are separate questions, and they meet at one list.** Duplicates asks
   *which copy survives*; answering it stages the loser. The delete list asks *are you done,
   shall these go*. Everything marked `D` during a triage pass is already waiting there, so
   the two paths converge on one button — which is exactly what `decide()` already does:
   it merges tags, confirms the candidate, then stages the loser `.toDelete`. **The compare
   screen never deletes anything.**

2. **`PurgeButton`'s count becomes a list.** "Permanently delete 47 marked items?" is not
   reviewable — you cannot see what the 47 are, and the mark could be four months old. The
   list shows each file, why it is on the list (`triage pass` / `duplicate`), its size, a
   running reclaimable total, per-row **Restore**, and per-row selection so a partial purge is
   possible. `purgeDeleted()` purges **everything flagged**, so unticking a row must actually
   unstage it (`unstage(.toDelete,)`) rather than filter the view — otherwise the confirmation
   lies.

3. **Playback issues get the queue they never had.** `W` stages a file under `_PlaybackIssue`
   and sets the flag; today the only affordance is "Clear Playback Issue" in the grid's
   context menu. The queue shows the captured probe output — **captured at the moment of
   failure, not re-run now** — and the fixes that address *that* failure kind, cheapest first,
   with the command visible.

4. **Repair recipes are data, not a switch statement.** A recipe is a match (failure kind or
   probe signature), a tool, a command template, an estimated duration and a risk label. Then
   adding "untrunc for truncated MP4s" is a settings change rather than a release, and the
   Settings ▸ Repair pane (spec 13) has something to edit. Ship three or four; do not hard-code
   them into the view.

5. **A repair runs on a copy and re-probes before replacing anything.** This is `RemuxJob`'s
   existing discipline — write to temp, verify, move the original to `_Replaced/<path>` — and
   every recipe inherits it. That is what lets a fix be offered without a confirmation dialog
   in front of it: the original is never the thing at risk.

6. **Re-encoding is labelled a last resort where it is offered.** Remuxing a `moov` atom is a
   stream copy and costs nothing but time; salvaging by re-encode loses a generation and may
   lose material. Both are legitimate; only one should be reached for first, and the row says
   which.

7. **The matcher proposes.** Keep `QualityScore`'s labelled breakdown and add a `BEST QUALITY`
   marker plus metric-by-metric comparison (the better value green, the other neutral).
   Keep **Not Duplicates** and add **Keep both** — a pro-shot and an audience capture of the
   same set match at 94% and are both worth having; the matcher does not know that.
   Show *why* they matched — fingerprint confidence, duration delta, hash identity — including
   the 25-second reliability floor where it is the reason a pair is absent.

8. **`decide()`'s honest failure stays visible.** `skippedSingleValue` explains that a tag
   could not carry over because the keeper already holds one in that single-value category.
   It is currently appended to the outcome string; keep it, and keep it per tag.

9. **Nothing happens until it does.** Decisions stage in the inspector and apply together;
   deletions go to the purge list; repairs archive the original. Both leave an entry in the
   operation log (`FileMoveLog` already outlives the item it moved — names are snapshotted
   precisely so a purged file stays labelled).

## Model changes

| Change | Why | Where |
|---|---|---|
| `RepairRecipe`: match, tool, command template, estimate, risk label | §4. Also feeds Settings ▸ Repair. | new app-level table |
| Capture probe output on the item when playback fails | The queue shows evidence; re-probing at review time answers a different question than the one that failed. | `Models/MediaItem` or a side table |
| `purgeDeleted(itemIDs:)` — an explicit set, not "everything flagged" | A reviewed subset must purge exactly what was ticked. Keep the flag check as the guard inside it. | `Organization/MoveService` |
| Reclaimable bytes for the flagged set | The list's headline number; a `SUM(fileSize)` over flagged rows. | `Organization/MoveService` |

## Layout

Window `1440 × 918`. Mode segmented control with live counts, a mono headline, and a
right-aligned safety line that changes per mode.

**Queue rail 262 pt** (`#17130E`): duplicate groups / delete-list filters / issue queue, each
row with a kind dot, title, mono meta, and a green ✓ once resolved (resolved rows stay,
dimmed — a queue that empties as you work gives you nowhere to go back to). A **THIS PASS**
block pins to the foot with three counts, **counted per queue** — the two share one resolved
map and must never borrow each other's numbers.

**Centre**, per mode: compare cards side by side with metric rows and a `WHY THESE MATCHED`
block; the delete table (`30 / 1fr / 150 / 84 / 108` — check, file, marked by, size, restore);
or the issue detail — thumbnail beside mono probe output on `#0F0C07`, then the fix list.

**Inspector 300 pt**: how these got here · pending decisions (removable) · a fixed safety
block.

Footer 62 pt: the consequence sentence on the left, actions on the right. The destructive
button is `#8A3428` on `#FFEDE8`; **Restore selected** and **Keep both** are neutral.

## Copy — verbatim

| Element | String |
|---|---|
| Modes | `Duplicates <n>` · `Delete list <n>` · `Playback issues <n>` |
| Safety lines | `Resolving a group only moves the losing copy to the delete list.` · `Files leave disk only when you delete them here.` · `Every fix archives the original first.` |
| Group blurb | `Pick the one to keep. The others move to the delete list — this screen never deletes anything itself.` |
| Duplicates footer | `Keeping one copy sends the rest to the delete list. Nothing is removed from disk here.` |
| Delete-list blurb | `Everything marked with D during triage, plus the losing copy of every duplicate you have resolved. Nothing here has been touched yet.` |
| Delete list, empty | `Nothing marked for deletion` / `Press D during a triage pass, or resolve a duplicate group, and the files land here.` |
| Delete list, nothing ticked | `Nothing selected. Tick the files you want gone.` |
| Confirm | `Delete <n> files?` · `<n> files removed from disk` · `<size> space reclaimed` · `0 tags or field values lost — a kept duplicate inherits them` |
| Confirm note | `Files move to the purge list and are removed on the next maintenance pass. The operation log keeps a revert entry until then.` |
| Issue footer, fix picked | `Runs on a copy. The original is archived and the result is re-probed before it replaces anything.` |
| Issue footer, none picked | `Pick a fix to run against this file.` |
| Repair done | `Repaired and re-probed — plays cleanly` |
| Safety block | `Deleting moves files to a purge list; they leave disk on the next maintenance pass.` · `Every repair works on a copy, archives the original, and re-probes before replacing anything.` · `Both are written to the operation log and revert from there.` |
| No pending | `Nothing staged. Decisions collect here and apply together, so a batch can be reviewed before anything touches a file.` |
| No candidates | `No Pending Duplicates` / `The sweeps flag identical files and fingerprint matches here.` *(existing)* |
| Carry-over | `Carry these tags from the file being removed:` *(existing)* |
| Purge result | `<n> items removed, <n> files deleted.` (+ `<n> files could not be deleted and their items were kept.`) *(existing)* |

## Keep from the existing view

`QualityScore.compute` and its per-component breakdown with `note` as help text — it is the
evidence, not decoration. `mergeableTags` / `decide` semantics: the **library** decides what
can merge and recomputes it inside the transaction, never trusting the caller's list. The
tags-before-staging ordering in `decide()` (there is a comment explaining why the physical
`_ToDelete` move comes last). The off-main-actor candidate fetch. `Play` swapping the window
to the player in place. And `purgeDeleted`'s two rules: an offline source's items are skipped
entirely so file and row leave together later, and a file that will not delete keeps its row.
