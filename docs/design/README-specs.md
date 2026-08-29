# Handoff — design specs for the macOS app

Comps live in this project as `.dc.html` files. They are browser design comps, not code:
nothing here ports into the repo. What ports is in these specs.

Each spec carries the **decisions** (the expensive part), the **copy** (verbatim, where it
is new), and the **Swift files** it touches. `github.md` in this project holds the full
screen map.

`00-what-changed-and-why.md` is the companion: every place a spec departs from its comp or
asks the code to change, in plain terms, plus the judgement calls worth revisiting. Read it
first if a spec's reasoning is not obvious.

## How to continue this in a new chat

Everything needed is in this project — nothing depends on the conversation that produced it.

**To revise a spec:**

> Read `handoff/README.md`, `handoff/design-tokens.md` and `handoff/<spec>.md`. Then open its
> `.dc.html` comp in this project and re-read the Swift files named in its header before
> changing anything.

**The rule every spec here was written under, and any revision must keep:** read the existing
Swift view first. Six times in this project the surrounding code changed the answer once
actually read — `SettingsView` is a TabView not a sidebar, `BackgroundTasksView` already maps
job kinds to human names, `LibraryRef` holds only four fields, `ItemGridView` already names
every operation, `ValidationView` is per-finding not per-kind, and `purgeDeleted()` purges
everything flagged rather than a passed set. A spec written from the comp alone invents labels
that already exist and misses the constraint that decides the design.

## Order to implement

Ordered by dependency, not by size.

| # | Spec | Comp | Phase | Swift touched |
|---|---|---|---|---|
| 1 | `01-library-picker.md` | Mac Library Picker | 1 | `SightsAndSoundsApp.swift` (`LibraryListView`, `LibraryRow`) |
| 2 | `02-browse-window.md` | Mac Browse Window | 3 | `Browse/SidebarView`, `ItemGridView`, `LibraryWindowView`, `GridDisplaySettings` |
| 3 | `03-player.md` | Mac Player Window | 3/4 | `Player/PlayerView`, `TagPanelView`, `OcrLinesPanel`, `KeyBindingsEditor`, `Playback/PlayerKeyMap` |
| 4 | `04-categories-and-fields.md` | Mac Categories and Fields | 4 | `Browse/CategoryManagerView`, `Models/TagCategory`, `FieldDefinition`, `Tagging/TagEditing` |
| 5 | `05-import.md` | Mac Import Window | 5 | `Browse/ImportView`, `Ingest/ImportJob`, `BrowseModel.addSource` |
| 6 | `06-background-tasks.md` | Mac Background Tasks | 5 | `BackgroundTasksView`, `Jobs/JobRunner`, `Jobs/JobRecord` |
| 7 | `07-review.md` | Mac Review Window | 6/8 | `Browse/DuplicatesView`, `Organization/MoveService`, `LibraryMaintenanceViews` |
| 8 | `08-operations.md` | Mac Operations | 7 | `Browse/ItemGridView` context menu, `Operations/*` |
| 9 | `09-organise.md` | Mac Organise | 7 | `Browse/ReorganizeView`, `Organization/OrganizeTemplate`, `MoveService`, `MoveHistoryView` |
| 10 | `10-maintenance.md` | Mac Writeback Backup Validation | 8 | `Browse/ValidationView`, `LibraryMaintenanceViews`, `Writeback/*` |
| 11 | `11-new-library.md` | Mac New Library | 2 | `SightsAndSoundsApp.swift` (`NewLibraryFlow`), `Templates/LibraryPlan`, `LibraryTemplate` |
| 12 | `12-library-properties.md` | Mac Library Properties | — | `LibraryPropertiesView`, `Models/LibraryInfo` |
| 13 | `13-settings.md` | Mac Settings Repair, Mac Settings Category Order | — | `SettingsView` |
| 14 | `14-tag-analysis.md` | Mac Tag Analysis Window | 4 | `Domain/TagAnalysis` port, `Models/AnalysisRule` |
| 15 | `15-devices.md` | Mac Devices | 9 | net-new — no Swift view yet |
| 16 | `16-command-palette.md` | Mac Command Palette | — | net-new |

All sixteen specs are written. Each carries its decisions, its verbatim copy, and the Swift it
touches; the model-change table below is the cross-cutting work they assume.

## Model changes the design assumes

These are schema or type changes, not view work. Worth landing before the views that need
them.

| Change | Why | Where |
|---|---|---|
| `displayAsCheckboxes: Bool` → `displayStyle: enum { search, checkboxes, radio }` | A single-select category rendered as checkboxes is the wrong control. Migrator maps `true` → `.checkboxes`, `false` → `.search`. | `Models/TagCategory` |
| Drop `isDefaultFocus` | Focus is the first visible category by `sortOrder`. Removes a setting, a validation rule, and an unrepresentable-conflict cascade. | `Models/TagCategory` |
| `separatorCharacters: String` (default `-._`) | Library-wide, feeds `separatorsToSpaces`. A category chooses whether to apply separators, never which. | `Models/LibraryInfo` |
| Per-surface category order + a global order with a lock | Browse filters by one order, the player tags in another. Locked = every surface follows global; unlocked = global seeds each. | new app-level setting |
| Cache a per-library summary on close | The picker shows counts without opening every file and waking every drive at launch. | `Database/AppDatabase` (`LibraryRef`) |
| Repair recipes + external tools as data | A recipe is a match, a tool and a command template, so adding one is a settings change rather than a release. | new app-level tables |
| `colorIndex` on `TagCategory` | The tokens fix a hue per category, and pills, swatches and filter chips in three windows read it — but no colour is stored, so every surface invents one. Index into a fixed palette. | `Models/TagCategory` |
| `segmentRole` on the child item; `keyMap` app setting | A song and a clip are both named ranges under `createEmbeddedClip`; only the label differs. The key map is four rows of disagreement, so it is one enum, not two code paths. | `Models/MediaItem`, `Settings/AppSettings` |
| Vocabulary writes: `mergeTags`, `tagUsageCounts`, alias-aware `ensureTag`, bulk `setSortOrder` | The Categories window needs all four and none exist; the only merge today is duplicate-item resolution, which is a different operation. | `Tagging/TagEditing` |
| Split scan from insert; staged assignments on the import payload | Nothing can be reviewed while discovery and insertion are one pass, and staging on import is what stops tagging becoming a second trip through the grid. | `Ingest/ImportJob`, new `ScanJob` |
| `deleteFinished`, `retry`, job `priority` (Run next reorders the queue, never pre-empts a running job), per-runner paused state | Clear finished, Retry and Run next have nothing to call today. | `Jobs/JobRunner`, `Jobs/JobRecord` |
| `purgeDeleted(itemIDs:)`; captured probe output per failed item | A reviewed subset must purge exactly what was ticked, and the issue queue shows the evidence from the moment of failure. | `Organization/MoveService`, `Models/MediaItem` |
| `OcrSettings` (recognition level, min text height, region, correction, collapse repeats); per-job cost estimates; `JoinJob` dry-run check | The operations window states what an operation costs before it runs, and OCR's knobs are hard-coded in the job today. | `Settings/AppSettings`, `Operations/*` |
| `sessionID` on `FileMoveLog`; `revertSession` | History groups by run because that is the unit people undo in; grouping by template + timestamp breaks on two runs a minute apart. | `Organization/FileMoveLog`, `MoveService` |
| Write-back **dry run** returning per-file, per-field `(new, previous, status)`; backup enumeration | The write-back preview must show the value it is about to overwrite without writing, and nothing lists the backups on disk. | `Writeback/WritebackJob`, `BackupService` |
| Snapshot reader producing a `LibraryPlan`; post-create verification counts | Migration from the web app's export shares the creation flow's review screen, and ends by reading the new library back. | new `Templates/SnapshotImport`, `LibraryCreator` |
| `ExternalTool` + `RepairRecipe` tables; per-surface `categoryOrder` with a lock | Repair recipes as data (specs 07, 13a); the parked per-location category order (13b). Category order is keyed by category ID, so it belongs in the **library file**, not `settings.json`. | new tables, `Settings/AppSettings` |
| `EmbeddedMetadataPair` table; typed matcher/action enums over `matchJSON`/`actionsJSON`; candidate query and decisions | The tag-analysis engine is storage-only today — no parser, no queue, no dry run. | new `Domain/TagAnalysis` |

## Decisions that apply everywhere

A library file is `<Name>.sqlite` — no custom extension (decided Aug 2026): the archive should
open in any SQLite tool without explaining itself first. The comps show `.sasl`; ignore them.

1. **Every operation is additive.** Encode writes beside the original, join leaves the
   parts, clip export marks the clip rather than deleting it, block removal makes an
   edited copy. There is no in-place edit anywhere, which is why there is no undo to
   design — the original never stopped existing.
2. **Unavailable, not hidden.** A command that needs two items stays visible and greys,
   with the requirement where its description goes. Hiding it teaches nothing.
3. **Say what a thing costs before it runs.** Frame counts for OCR, reclaimable bytes for
   a purge, output sizes for an encode, files written for every operation.
4. **The guard lives in the query.** Media-kind scoping, offline scoping, library scoping
   go through one function each. Relaxing a rule in the UI must not remove its guard.
5. **Destructive things stage.** Deletions go to a purge list, repairs run on a copy with
   the original archived, moves log per file and revert individually.
6. **Read the existing view before designing its replacement.** Five times in this project
   the surrounding Swift changed the answer materially once read — `SettingsView` is a
   TabView not a sidebar, `BackgroundTasksView` already maps job kinds to human names,
   `LibraryRef` holds four fields, `ItemGridView` already names every operation,
   `ValidationView` is per-finding not per-kind.
