# 11 — New library

**Comp:** `Mac New Library.dc.html`
**Swift:** `SightsAndSoundsApp.swift` — `NewLibraryFlow` (~294), `Templates/LibraryPlan.swift`,
`Templates/LibraryTemplate.swift`, `Templates/LibraryCreator.swift`

## What changes

`NewLibraryFlow` is two steps in a sheet: name + template picker, then a review `List` where
each category is a checkbox, a name field and a one-line summary. The plan model underneath is
far richer than the screen — `PlannedCategory` carries `allowMultiple`,
`displayAsCheckboxes`, `sortOrder`, `hiddenFromBrowse`, `sectionLabel`, `textFormat`,
`separatorsToSpaces`, `writebackEnabled`, `writebackField`, its tags (with aliases, favourite,
hidden) and its tag fields. None of that is editable at creation, so a new library is created
and then immediately reconfigured in another window.

It becomes a four-step window — **Name · Vocabulary · Review · Source** — where the review
step edits the whole plan, and the same window serves migration from the web app's snapshot.

## Decisions

1. **One review screen, two ways in.** A template seeds the plan; a snapshot produces the same
   plan from what the old app held. Both end in the same editable review, so a library made
   either way is configured identically and the screen is built once. The mode switch is at
   the top of the step rail; only steps 1 and 4 differ.

2. **Excluding is not deleting.** An unchecked category is **never created** — its tags and
   fields simply never exist, rather than being written and then removed. `LibraryCreator`
   already honours `include`; the review should say what the checkbox means, because "delete"
   and "never make" feel different when you are about to commit.

3. **Order carries the meaning, so make it draggable.** Categories appear in the tag editor in
   `sortOrder`, and per the model change in the README **focus is the first visible category**
   — there is no `isDefaultFocus` any more. Dragging to reorder therefore *is* setting the
   focus, which is one fewer setting and one fewer unrepresentable conflict. Say it under the
   heading: `Categories appear in the tag editor in this order — the first one takes the
   cursor.`

4. **Configure at creation, not after it.** Each category card exposes the plan's real fields:
   multiple/single, display style, browse visibility, name formatting, separators, write-back
   with its field. Tags are chips — click to edit name, aliases, favourite, hidden — and tag
   fields sit beneath with name, type and required. This is the same vocabulary the Categories
   & Fields window (spec 04) edits later; it should not be a different, poorer set now.

5. **Validation is continuous and lives at the button.** Empty and duplicate category names
   block the final step from the moment they occur, shown in the footer beside the action —
   not collected into a dialog that appears after Create is pressed.

6. **The folder picker is the system's.** Choosing a location or a source is `NSOpenPanel`
   (`canChooseDirectories`, `canCreateDirectories`) and Create is `NSSavePanel`, exactly as
   `NewLibraryFlow.create` already does. The comp draws a picker only because a browser cannot
   open one — **do not build it.**

7. **Adding a source at creation does not import.** It registers the folder and scans; the
   import window (spec 05) confirms. So the last step is genuinely skippable, and says so.

8. **A migration ends by verifying itself.** Read the new library back and compare counts
   against the snapshot — items, tags, categories, fields, analysis rules. Recomputable data
   (hashes, quality analyses, fingerprints, thumbnails) is skipped **on purpose and listed
   plainly**; analysis rules are authored rather than derived, so they migrate. A mismatch is
   cheaper to know now than after a week of tagging.

9. **The extension is `.sqlite` — decided, Aug 2026.** The comps show `.sasl`; ignore that. A
   library file stays a plainly-named SQLite database, openable by any SQLite tool without
   explaining an extension to it first, which matters more for a personal archive meant to
   outlive the app than a document icon does. The filename preview in step 1 reads
   `<Name>.sqlite`.

## Model changes

| Change | Why | Where |
|---|---|---|
| Drop `isDefaultFocus` from `PlannedCategory` | Follows the README's model change; §3 replaces it with order. | `Templates/LibraryPlan` |
| `colorIndex` on `PlannedCategory` | Categories carry a hue everywhere (spec 04); a template should seed it rather than leaving the first window to invent one. | `Templates/LibraryPlan` |
| Snapshot reader producing a `LibraryPlan` + a row payload | The whole migration mode. Nothing in the repo reads the web app's export today. | new `Templates/SnapshotImport` |
| Post-create verification counts | §8 — read back and compare, per entity. | `Templates/LibraryCreator` |

## Layout

Window `1280 × 884`. **Step rail 250 pt** (`#17130E`): mode tabs, then four numbered steps
(current amber, done green `#2F4A2F`/`#8FCF8F`, pending dim) each with a one-line subtitle, and
a pinned **WILL CREATE** summary — categories, tags, field definitions — that updates as the
plan is edited.

Step 1: name field, location row with **Choose…** and the resulting filename in mono beneath;
in migrate mode, the snapshot row with its version, table and row counts.

Step 2: template cards in a 2-up grid, each with a hue dot, category count, summary and the
first four category names as chips.

Step 3: one card per category — drag handle, include box, name field (with `was <old name>`
when renamed), a labelled config grid, then tags and tag fields with inline editors on
`#1C1710` / `#4A3C24`. Media item fields follow in their own block beneath.

Step 4: source rows with a green dot and remove, plus a dashed **+ Add a source folder…**; in
migrate mode, the verification table (`1fr / 110 / 110 / 74`) and the not-carried-over chips.

Footer: validation error with a red dot, or the reassurance hint; **Back** and the primary,
which reads `Continue` until the last step.

## Copy — verbatim

| Element | String |
|---|---|
| Window titles | `New Library` · `Migrate Library` |
| Step 1, new | `Name the library` / `Each library is one file with its own categories, tags and sources. Cross-library leakage is structurally impossible rather than merely forbidden.` |
| Step 1, migrate | `Name the library the snapshot becomes` / `One SQLite file, its own vocabulary, never shared with another library.` |
| Step 2, new | `Choose a starting vocabulary` / `A template only seeds the review screen. Everything it proposes can be renamed, reconfigured or dropped before anything is written.` |
| Step 2, migrate | `Map the old root to a source` / `Ownership is a foreign key now, not a path prefix — so relocating this folder later updates one row instead of every item under it.` |
| Step 3 | `Review the vocabulary` / `Rename, reconfigure, reorder or exclude anything here. This is the same screen migration uses, so a library made either way is configured the same way.` |
| Step 3 order note | `Categories appear in the tag editor in this order — the first one takes the cursor.` |
| Step 4, new | `Add a source` / `A source is a folder this library watches. You can skip this and add one later.` |
| Step 4 source note | `Adding a source registers the folder and runs a scan. Nothing enters the library until you confirm the import, so you can add these later without committing to anything.` |
| Step 4, migrate | `Verify the counts` / `Read back from the new library and compared against the snapshot. A mismatch here means the migration is wrong, and it is cheaper to know now than after you have tagged for a week.` |
| Not carried over | `stream hashes` · `quality analyses` · `fingerprints` · `thumbnails` |
| Migration note | `All of it recomputes from disk on first run. Analysis rules are authored rather than derived, so those do migrate.` |
| Footer hints | `Nothing is written until the last step.` · `You can add sources later.` · `Nothing has been written yet.` |
| Primary | `Continue` · `Create library` · `Migrate` |
| Existing review copy | `Rename or exclude anything. Nothing is written until Create.` *(existing)* |
| Template summaries | `Live music: bands, recording types with aliases, venues, years with metadata write-back.` · `Courses and lessons: subject and course categories, lesson ordering, watch state.` · `Family footage: people, occasions and places.` · `No categories — build the vocabulary from scratch.` *(all existing — `LibraryTemplate.summary`)* |

## Keep from the existing view

`LibraryTemplate.summary` verbatim as the card text — one string, one place. The plan being
**fully editable and written by nothing until Create**. `LibraryCreator.create(at:plan:registerIn:)`
as the single write, registering the library in `AppDatabase` in the same call. Defaulting the
name to the template's display name when the field is left empty. The save panel with
`canCreateDirectories`. And `categorySummary`'s shape — `multiple · checkboxes · N tags →
ARTIST` — as the collapsed summary line, since it already reads well.
