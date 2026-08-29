# 10 — Maintenance: write-back, backup, validation

**Comp:** `Mac Writeback Backup Validation.dc.html`
**Swift:** `Browse/ValidationView.swift`, `Browse/LibraryMaintenanceViews.swift`
(`PurgeButton` ~73), `Writeback/WritebackJob.swift`, `TagWriters.swift`, `StandardFields.swift`,
`WritebackModels.swift`, `BackupService.swift`, `ValidationJob.swift`

## What changes

These are the three things that touch **files** rather than the database, and today they are
three unrelated affordances: a validation sheet, a backup button in Settings, a write-back
command in the grid's context menu. One window, three tabs, one shared shape — scope, a
preview of what would change, the cost, the guarantee, and a history with a way back.

`ValidationView` is already right about the thing most easily got wrong: findings are
**per finding, not aggregated by kind**, each with one honest action. Keep that.

## Decisions

1. **Write-back is a wipe-and-rewrite, so the preview must show the prior value.** `TagWriters`
   replaces a file's tag set with exactly the fields given — that is why a pre-write snapshot
   is mandatory. The preview shows, per file per field, the value going in and **what was
   there before**, struck through, with an amber row when a non-empty value is being replaced.
   The count of overwrites is a headline figure, not a footnote.

   The tokens file lists this as one of the three places a sub-AA grey was shipped on
   load-bearing data — the prior embedded value being overwritten. It is `#8C8478` or lighter.

2. **The mapping is visible where the writing happens.** Which categories write, and to which
   field, is `TagCategory.writebackEnabled` / `writebackField` — editable in Categories &
   Fields (spec 04) and **shown here** as the plan's premise, with the resolved Vorbis name
   and MP4 shape. Same picker over `StandardFields.all`, not free text, for the same reason.

3. **Skipped is a first-class outcome, listed by name.** `WriteRunFileStatus` is
   `written · failed · skipped`. A container the tool ladder cannot write is skipped, never
   rewritten — say which files and why, in the plan and in the result.

4. **A run is the unit of undo.** `TagWriteRun` + `TagWriteRunFile` already model it, with the
   path denormalised so history survives moves and deletes. History rows offer **Restore
   embedded tags**, which is `RestoreTagsJob` — and that takes its own pre-restore snapshot,
   so the restore is itself undoable. Say so; it is the reason this is safe to try.

5. **Backup is one file, and the sentence that matters is what it does not include.** A library
   is a single SQLite file; a backup is a copy of it. Media is never included. Restore
   **archives the current file first** — never deletes it — and needs the library's windows
   closed. All three lines belong on screen, not in a help page.

6. **A sweep observes; it never repairs.** Findings are the latest run only, recomputed
   cheaply — not history. Each kind keeps exactly one action, and the actions stay the honest
   ones the existing view chose: a missing file offers **Mark for Deletion** (flag-only —
   the file is already gone), an orphan offers **Import**, a size mismatch offers **Accept
   Disk Size** (trust the disk, clear the stale hash so the sweep recomputes).

7. **Purge lives here, with the list from spec 07.** `PurgeButton`'s count belongs beside the
   findings — validation is where "these rows no longer match disk" is already the subject.
   The destructive button carries the count and the reclaimable size; the review list itself
   is the Review window's delete tab. Two entry points, one confirmation, one `purgeDeleted`.

8. **Offline is skipped, whole, everywhere — and that is a feature.** A sweep skips offline
   sources entirely (absence of a drive is not absence of files). A purge skips their items
   entirely so file and row leave together, later. Write-back cannot touch them. State it
   rather than letting an unplugged drive look like data loss.

9. **Middle-truncate every path.** Volume and filename identify a file; the centre is what can
   be lost. Never `direction: rtl` — the leading `/` reorders (tokens, layout rule 3). Matches
   `.truncationMode(.middle)` in the source.

## Model changes

| Change | Why | Where |
|---|---|---|
| Write-back **dry run** producing per-file, per-field `(new, previous, status)` | The preview in §1 cannot come from the job's own execution — it has to be computable without writing. `TagWriters.readTags` + `WritebackMapping.fieldWrites` already do both halves. | `Writeback/WritebackJob` |
| Backup list with item count and size per file | `backup(into:)` writes dated files and `verify` opens one; nothing enumerates them for display. | `Writeback/BackupService` |
| Sweep schedule (the comp shows `Today at 06:00`) | Either a real schedule setting or drop the recurring-sweep implication. Do not show a time the app does not keep. | `Settings/AppSettings` |
| Reclaimable bytes for flagged rows | Shared with spec 07. | `Organization/MoveService` |

## Layout

Window `1280 × 858`. Tabs (**Write-back · Backup · Validation**) with a mono headline; title
and blurb below; an optional **SCOPE** strip (selection vs whole library) for write-back.

Centre: the mapping block (checkbox, category hue dot, name, arrow, field, resolved-name hint)
then the main list — `16 / minmax(0,1fr) / minmax(0,1fr) / 96` — dot, name over meta, value
over struck-through previous value, action. Green `#8FCF8F` for a value being added, amber
`#E9A23B` for one being replaced, grey for skipped.

Sidebar 310 pt: counts, then history rows with their state chip and a restore action, then a
**SAFETY** block of three bullets — different per tab, always three, always specific.

Footer 62 pt: the plan sentence, then actions. Write-back: **Preview only** · **Write tags**.
Backup: **Reveal in Finder** · **Back up now**. Validation: **Purge N staged rows**
(`#8A3428`) · **Run Sweep**. When nothing is staged the purge button is inert and reads
`Nothing staged` rather than vanishing.

## Copy — verbatim

| Element | String |
|---|---|
| Write-back title | `Write tags into the files` |
| Write-back blurb | `Copy what the library knows into the media files themselves, so another player — or you, in ten years, without this app — can still read it.` |
| Write-back safety | `Every file's existing embedded tags are snapshotted before it is touched.` · `A run can be reverted whole, restoring the tags each file had before it.` · `Files whose container will not accept a tag are skipped and listed, never rewritten.` |
| Write-back footer | `<n> items · <n> tags · <n> existing values replaced` |
| Write-back actions | `Preview only` · `Write tags` · `Restore embedded tags` |
| Backup title | `Back up the library` |
| Backup blurb | `A library is one file, so a backup is a copy of it. This does not touch your media — only the database holding tags, fields and history.` |
| Backup footer | `Backing up copies one file. Your media is never included.` |
| Backup safety | `Restoring archives the current file first; it is never deleted.` · `Close this library's windows before restoring.` · `Media files are untouched by both backup and restore.` |
| Validation title | `Validate the library` |
| Validation blurb | `Compare what the database believes against what is actually on disk. Findings are reported, never fixed silently.` |
| Finding details | `the row exists, the file is gone` · `on disk, no row — never imported` · `row says <a>, disk says <b>` |
| Finding actions | `Mark for Deletion` · `Import Now` · `Accept Disk Size` *(existing)* |
| Validation footer | `<n> findings · a sweep only observes, it never repairs` |
| Validation safety | `A sweep only reads. Findings are the latest run, recomputed cheaply — not a history.` · `Purging touches only rows already flagged for deletion, and reports files it could not delete rather than assuming.` · `Items on an offline source are skipped by a purge entirely, so an unplugged drive cannot lose anything.` |
| Validation empty | `No Findings` / `Run a sweep to compare the library against the disk.` *(existing)* |
| Purge confirm | `Permanently delete <n> marked items and their staged files? This cannot be undone.` *(existing)* |
| Purge result | `<n> items removed, <n> files deleted.` (+ `<n> files could not be deleted and their items were kept.`) *(existing)* |

## Keep from the existing view

Findings **per finding**, never rolled up by kind — the path is the information. One action per
kind, and the reasoning behind each: a missing file flags without moving because there is
nothing to move. `acceptDiskSize` clearing the hash. `ValidationJob` replacing the previous
run's findings rather than accumulating. `BackupService.verify` opening and migrating a backup
before anything is swapped. `WritebackJob` clearing the content hash after a fallback remux,
because the bytes changed. `TagWriters`' tool ladder — metaflac / AtomicParsley first, ffmpeg
`-c copy` remux as the coverage floor, temp file and atomic swap — and the fact that the
essence is untouched by construction.
