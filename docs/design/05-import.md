# 05 — Import

**Comp:** `Mac Import Window.dc.html`
**Swift:** `Browse/ImportView.swift`, `Ingest/ImportJob.swift`, `Browse/BrowseModel.swift`
(`addSource` ~387, `importSource` ~401)

## What changes

Today `ImportView` is a grouped `Form` — sources with reachability and counts, Scan / Scan
All, the effective extension lists, recent history — and `addFolder()` calls `addSource`
then **immediately** `importSource`. One `ImportJob` discovers, probes and inserts in a
single pass; the user never sees the file list.

It becomes a four-step window — **Source › Scan › Review & Stage › Import** — where scanning
produces a *list* and nothing enters the library until the list is confirmed. The tag
staging boxes from the web import tool come with it.

## Decisions

1. **Adding a source registers and scans; it does not import.** Pointing at an unreviewed
   drive should cost a file list, not four thousand rows you then have to un-import — and
   there is no un-import, because §1 of the shared decisions means nothing is destroyed.
   `addSource` stops calling `importSource`; it opens this window on the scan result.

2. **Scan is cheap; probing is lazy.** The comp's table shows duration, resolution and size
   per candidate. Size comes free from the enumeration — **duration and resolution do not**:
   `MediaProbe.probe` per file is most of what makes an import slow, so probing 4,000
   candidates up front would make Scan take as long as the import it is meant to precede.
   Scan lists path, extension and size; **probe only the rows on screen**, fill the two
   columns in as they resolve, and show `—` until then. The insert probes for real.

3. **The scan reports what it did not list.** An extension histogram of everything skipped is
   free during enumeration and answers the question the file list provokes: *why are there
   38 files in this folder and 36 here?* Surfaced as a one-line action —
   `2 files skipped — enable .m2ts` — writing to the library's extension override
   (`LibraryInfo.videoExtensionsOverride`), not the app-wide list.

4. **Selection is per file, scoped by folder.** The left rail is the scan scope: folders with
   new/known counts, checkable, one focused. The table is the files under the checked
   folders, filterable by **New only / All / Already imported**. Already-imported rows stay
   **visible but unselectable** — seeing that a folder is 19-of-23 known is the information;
   hiding them makes a partial re-scan look empty.

5. **Staging replaces post-hoc tagging.** The right rail holds an assignment box per
   configured category — the web import tool's model, carried across. Values staged there
   apply to every file in the import. **Whole import / Per folder** is one control, because a
   drive of shows is one Band per folder and one Recording Type overall; forcing the whole
   import to share a single value is what sends people back to the grid afterwards.

6. **Sticky is per box, not a mode.** A `sticky` toggle on a box keeps its value for the next
   import (Venue, Year, Show Date usually; Band never). Explicit per box beats a global
   "remember my last import" that nobody can predict.

7. **Folder names are suggestions, not parsers.** The autocomplete offers words from the
   focused folder's name as `folder`-badged rows beneath the real tags. Suggest, never
   auto-apply — a filename parser that silently invents tags is unpickable-apart later.

8. **Running is not modal, but it starts that way.** The progress sheet shows the file being
   probed, count, percentage, and two exits: **Cancel** (the job's existing cooperative
   cancellation) and **Run in background**, which dismisses to the grid and leaves the job in
   the tasks window. A long import must not hold a window hostage; a short one should not
   make you go looking for it.

9. **The insert stays idempotent, and re-checks.** The list is a snapshot; the disk is not.
   Keep the `(sourceID, relativePath)` NOCASE comparison at insert time even though the scan
   already classified each row — the guard lives in the write, not in the UI's opinion of it.
   Everything else in `ImportJob`'s standing rules is unchanged: serialized queue, offline
   sources fail with a message, files missing from disk are never removed, sidecars are not
   consumed.

## Model changes

| Change | Why | Where |
|---|---|---|
| Split the job: `ScanJob` (enumerate + classify + extension histogram, inserts nothing) and `ImportJob` (insert a named list) | Review is impossible while discovery and insertion are one pass. | `Ingest/` |
| `ImportJob.Payload` gains `relativePaths: [String]` and a staging block | The import has to know *which* files and *what to apply*. | `Ingest/ImportJob` |
| `ImportStaging`: `tags: [categoryID: [tagID]]`, `flags`, `fields: [fieldID: String]` | One value applied to every inserted row, through `assignTag` so single-select is enforced. Per-folder staging is several payloads, one per folder — not a second code path. | `Ingest/` |
| Import box configuration: which categories/flags appear, in what order, and which are sticky | Per library, saved. | `Models/LibraryInfo` |
| Lazy probe API for candidate rows | Duration/resolution for visible rows only. | `Ingest/MediaProbe` |

`needsReview: true` on insert stays: it is what the browse `Missing` filters and the triage
pass are for.

## Layout

Window `1320 × 872`. Step strip at the top (done green, current amber, pending dim) with the
scan path in mono at the right. Toolbar row: source chip with its online dot, Rescan, status
segmented control, name filter, **Configure boxes…**.

Three columns. **Scan scope, 264 pt**: folder rows with checkbox, name, mono `<n> new · <n>
known`, and an amber dot when that folder carries staging of its own; the extensions block
sits at the foot. **Table**: `34 / 1fr / 92 / 68 / 76 / 118` — checkbox, filename (mono) over
folder, duration, resolution, size, status pill (`New` green, `In library` neutral, `ext off`
orange). **Stage rail, 340 pt**: scope tabs, one box per configured category, flags, fields,
and a pinned **WILL APPLY** summary at the foot.

Footer, 62 pt: mono counts (`<n> new`, `<n> already in library`, `<n> extension off`),
selection note, and the primary button naming its count.

## Copy — verbatim

| Element | String |
|---|---|
| Steps | `Source` · `Scan` · `Review & Stage` · `Import` |
| Status filters | `New only` · `All` · `Already imported` |
| Extension action | `<n> files skipped — enable .<ext>` |
| Scope note, whole | `Staging applies to every selected file in this import.` |
| Scope note, folder | `Staging applies to the highlighted folder only. Pick a folder on the left.` |
| Will apply, empty | `Nothing staged yet — files import untagged.` |
| Configure blurb | `Check the tag categories and flags to show as assignment boxes, and set their order. Values staged there apply to every file in the import.` |
| Primary button | `Import <n> Files` / `Nothing selected` |
| Progress | `<n> of <n> probed and inserted` |
| Running actions | `Cancel` · `Run in background` |
| Finished | `Import finished` · `<n> media items inserted` · `<n> skipped — already in library` · `<n> skipped — extension not enabled` |
| Finished note | `Thumbnails and content hashes are queued as background jobs and will fill in on their own.` |
| Finished actions | `Import more` · `Open in Library` |
| Empty table | `No files match this scope and filter.` |
| Scans are additive | `Scans are additive: new files are imported, known files are skipped, and files missing from disk are never removed.` *(existing)* |
| Offline source | `source '<Name>' is offline — import will pick it up when it returns` *(existing)* |
| No sources | `No sources yet — add a folder to import from.` *(existing)* |

## Keep from the existing view

The source row as it stands — online dot, `disabled` chip, middle-truncated root path, item
count, relative "scanned …" — it moves into the Source step unchanged. The generation-guarded
`reload()` that gathers counts, reachability, history and effective extensions off the main
actor. The effective-extensions footer naming *where* to change them (app-wide vs this
library's override). Recent Imports reading `JobRecord.summary` verbatim rather than
re-deriving it. And `ImportError`'s three cases: they already say the useful thing.
