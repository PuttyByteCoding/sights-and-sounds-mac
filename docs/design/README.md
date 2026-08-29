# Handoff: Sights and Sounds — native macOS app

## Overview

Sights and Sounds is a self-hosted personal media library and player for ~10,000 home
videos and recorded concerts. A web app (.NET + SvelteKit + Postgres) is being replaced by a
**native macOS app** (SwiftUI + GRDB/SQLite), with iOS, iPadOS and tvOS behind it.

This package covers **eighteen designed surfaces** for the Mac app — browse, playback,
tagging, import, vocabulary management, tag analysis, duplicate and playback-issue review,
operations, organisation, maintenance, background work, devices, settings, the library
picker and the command palette — plus a multi-platform layout canvas.

The macOS app already exists in a repository (`sights-and-sounds-mac`, SwiftUI + GRDB) with
most of these surfaces implemented in a plain, unstyled form. **This is a design pass over
existing code**, not a greenfield build. Every screen section below names the Swift file it
corresponds to.

## About the Design Files

The `.dc.html` files in this bundle are **design references created in HTML**. They are
prototypes showing intended look and behaviour — not production code, and not intended to be
copied into the app.

The task is to **recreate these designs in the target codebase's existing environment**:
SwiftUI, against the existing `SightsAndSoundsApp` / `SightsAndSoundsKit` packages, using
their established patterns (`@Environment` models, `NavigationSplitView`, GRDB reads off the
main actor, the `Job` protocol for background work).

Each HTML file carries **note cards beneath the window** explaining the reasoning behind its
decisions. Those cards are the most valuable part of the package — they record *why*, which
is the expensive thing to rediscover.

To view a design: open the `.dc.html` file in a browser. `support.js` must sit alongside
them. They are interactive — click, drag, type, and use the keyboard.

## Fidelity

**High fidelity.** Final colours, typography, spacing, states and interactions. Recreate the
UI faithfully using SwiftUI, matching the exact values in `design-tokens.md`.

Two qualifications:

- **The app owns its appearance.** Warm charcoal surfaces with an amber accent, not system
  materials. macOS window chrome and standard controls, warm charcoal content. This was an
  explicit decision (Aug 2026), so do not substitute `.background` / `.secondary` semantic
  colours for the specified hex values.
- **Placeholder imagery.** All thumbnails are neutral gradient placeholders. Real
  thumbnails come from `AVAssetImageGenerator` via the existing `ThumbnailProvider`.

## Screens / Views

**Every screen has a full spec** — `01-library-picker.md` through `16-command-palette.md`.
Each carries the decisions behind the design, its verbatim copy, the model changes it assumes,
and a list of things in the existing Swift that must not be changed. The summaries below are
an index; the spec is the source of truth, and `00-what-changed-and-why.md` explains every
place a spec departs from its comp.

### 1. Library picker — `Mac Library Picker.dc.html`
**Swift:** `SightsAndSoundsApp.swift` (`LibraryListView`, `LibraryRow`)
**Purpose:** choose which library to open. Appears at launch and from File ▸ Open Library….
**Layout:** 620pt centred dialog — title, scrolling list, placement band (menu context only),
button row. Rows: 34pt icon · name + `OPEN`/offline badges · cached summary (mono) · path
(mono) · last-opened right-aligned.
**Key decisions:** it is a *dialog* that dismisses on choice, not a persistent window. At
launch cancel reads `Quit`. From the menu, an `Open in — A new window / This window` band
appears; new window is the default. An already-open library offers `Bring Forward`. Removing
is *forgetting* — neutral confirm button, because nothing is deleted.
**Full spec:** `01-library-picker.md`

### 2. Browse window — `Mac Browse Window.dc.html`
**Swift:** `Browse/SidebarView.swift`, `ItemGridView.swift`, `LibraryWindowView.swift`
**Purpose:** the main workspace — filter and play.
**Layout:** 262pt sidebar + toolbar + filter-chip bar + offline banner + tile grid + floating
bulk bar. Grid `repeat(auto-fill, minmax(168|208|262px, 1fr))`, 16px gap, `align-items: start`.
**Key decisions:** three-way filter vocabulary (green `+` required / blue `~` optional / red
`−` excluded, struck through); a `Missing — no <Category> tag` row per category; media type
as multi-select checkboxes with the kind guard moved into the query; offline tiles badged and
desaturated rather than blocked, with a banner and a real hide/show toggle; uniform frames per
kind with 9:16 pillarboxed; eleven-slot configurable tile overlays with saved, `V`-cyclable views.
**Full spec:** `02-browse-window.md`

### 3. Player window — `Mac Player Window.dc.html`
**Swift:** `Player/PlayerView.swift`, `TagPanelView.swift`, `KeyBindingsEditor.swift`
**Purpose:** playback, tagging, segment authoring and queue in one window.
**Layout:** info bar · video stage · transport with waveform scrubber (song bars above, clip
bars below) · optional OCR strip · queue strip (146pt) · 352pt right rail split between tags
and segments · 30pt focus-zone status bar.
**Key decisions:** the player owns playback only; tagging, segments and OCR are separate
panels — the web player was a 4,382-line god component. **Press `?` to compare two keyboard
maps side by side and switch between them live.** Tab walks video → tags → segments → queue;
**Esc releases to the video**, which is what makes bare single-key shortcuts safe. Numpad
seeking never yields, even mid-word in a tag field. OCR lines offer Copy / + Tag / + Alias,
all scoped to the playing item only.
**Full spec:** `03-player.md`

### 4. Import — `Mac Import Window.dc.html`
**Swift:** `Browse/ImportView.swift`, `Ingest/ImportJob.swift`
**Purpose:** review what a scan found before anything enters the library.
**Key decisions:** adding a source no longer ingests everything — it scans, and this window
is the review gate. Four steps: Source → Scan → Review & Stage → Import. Folder-tree scope,
per-file status (New / In library / extension off), and configurable tag-staging boxes with
per-folder or whole-batch scope. Sticky values persist across imports.
**Full spec:** `05-import.md`

### 5. Categories & Fields — `Mac Categories and Fields.dc.html`
**Swift:** `Browse/CategoryManagerView.swift`, `Models/TagCategory.swift`, `FieldDefinition.swift`
**Purpose:** author the library's vocabulary.
**Key decisions:** three panes — categories, tag table, inspector. Carries over the web app's
merge mode (target is an existing pick *or* a new tag the picks become aliases of), bulk
paste-create, multi-column sort, and a **Similar only** view clustering near-duplicate names.
Tag-scope and item-scope fields are both here. Terminology: **TagCategory**, **Field** — never
TagGroup or Property (CI-enforced).
**Full spec:** `04-categories-and-fields.md`

### 6. Tag Analysis — `Mac Tag Analysis Window.dc.html`
**Swift:** port of `Domain/TagAnalysis`, `Models/AnalysisRule.swift`
**Purpose:** mine candidates across the library and author the rules that fold them in.
**Key decisions:** two modes — Candidates and Rules. Three evidence sources (embedded
metadata, on-screen text, paths) in one queue. Rules use the real matcher/action vocabulary
(`keyEquals`, `valueStartsWith`, `numericRange`, `pathRootStartsWith` → `ignore`, `setKind`,
`stripPrefix`, `onlyIfTrue`, `assignCategory`, `hidePrefix`); both rule order and action order
are significant and drag-sortable. An always-visible **preview pane** in the left rail scales
with the pane; the evidence strip shows every matching frame, at the OCR read timestamp.
**Full spec:** `14-tag-analysis.md`

### 7. Review — `Mac Review Window.dc.html`
**Swift:** `Browse/DuplicatesView.swift`, `Organization/MoveService.swift`
**Purpose:** resolve duplicates, work a delete list, repair unplayable files.
**Key decisions:** **three queues, because judging and deleting are different acts.**
Duplicates asks which copy survives and sends the losers to the delete list; the delete list
is the flat batch view with one button; playback issues offers per-failure fix recipes.
Nothing is deleted outside the delete list.
**Full spec:** `07-review.md`

### 8. Operations — `Mac Operations.dc.html`
**Swift:** `Browse/ItemGridView.swift` context menu, `Operations/*.swift`
**Purpose:** run media operations against a selection.
**Key decisions:** **every operation is additive** — nothing is edited in place, so there is
no undo to design. Stream-copy vs re-encode is on the operation list, not buried. The item
list *is* the selection (per-row checkboxes); operations needing more than one file grey out
with the requirement stated. Join takes a selected, drag-ordered set or a whole folder, and
**refuses** with ffmpeg's own output when codecs mismatch. OCR has a full tuning panel —
sample interval down to 0.5s, recognition level, minimum text height, region — with a live
frame-count and time estimate.
**Full spec:** `08-operations.md`

### 9. Organise — `Mac Organise.dc.html`
**Swift:** `Browse/ReorganizeView.swift`, `Operations/ReorganizeJob.swift`
**Purpose:** move files into folders named by their own tags.
**Key decisions:** the preview is the feature — every item resolves live as you type a
template (`%Band/%Year`), and one that cannot says which tag it is missing rather than
inventing an "Unknown" folder. Move history logs every move individually; reverting is
one-shot and the row keeps its `from → to` as the record.
**Full spec:** `09-organise.md`

### 10. Maintenance — `Mac Writeback Backup Validation.dc.html`
**Swift:** `Browse/ValidationView.swift`, `LibraryMaintenanceViews.swift`, `Writeback/*`
**Purpose:** write tags into files, back up the library, validate against disk.
**Key decisions:** three tabs, grouped because each archives what it is about to change.
Write-back shows a per-file diff with the prior embedded value struck through, and the
category → field mapping is **editable here**. Validation is one row per finding across the
three real kinds (`missingFile`, `orphanFile`, `sizeMismatch`), latest sweep only. Purge
reports `rowsDeleted` / `filesDeleted` / `fileFailures` separately and disarms afterwards.
**Full spec:** `10-maintenance.md`

### 11. Background tasks — `Mac Background Tasks.dc.html`
**Swift:** `BackgroundTasksView.swift`, `Jobs/JobRecord.swift`
**Purpose:** every job across every open library.
**Key decisions:** **one lane per library**, because the runner is serialized per library.
Job kinds show their human names (`Thumbnail generation`, not `thumbnails.sweep`) with the
identifier beside them. Per-state icons. Pausing is visible state — a banner, not just a
toggled button — and a paused lane banks its elapsed time so progress freezes where it
reached rather than rewinding.
**Full spec:** `06-background-tasks.md`

### 12. New library — `Mac New Library.dc.html`
**Swift:** `SightsAndSoundsApp.swift` (`NewLibraryFlow`), `Templates/LibraryPlan.swift`
**Purpose:** create a library from a template, or migrate the web app's v8 snapshot.
**Key decisions:** one review screen serves both flows. Categories are drag-reorderable and
**order carries focus** — the first included category takes the cursor, so `isDefaultFocus`
disappears. Four labelled config rows per category, each with a worked example. Excluding is
not deleting. Migration ends by verifying counts against the snapshot.
**Full spec:** `11-new-library.md`

### 13. Library properties — `Mac Library Properties.dc.html`
**Swift:** `LibraryPropertiesView.swift`
**Purpose:** Get Info for a library.
**Key decisions:** two tabs — **Info** stays facts-only (Identity, Contents, Coverage with
progress bars, History); **Configuration** holds only what this library alone can own
(name, separator characters with an editable live preview, extension overrides that
*replace* rather than extend the app-wide list).
**Full spec:** `12-library-properties.md`

### 14. Settings · Repair — `Mac Settings Repair.dc.html`
**Swift:** `SettingsView.swift` (a `TabView`, not a sidebar)
**Purpose:** the repair recipes the playback-issue queue offers, and the tools they run.
**Key decisions:** external tools registered once with path and version — a recipe whose
tool is missing is flagged in place. A recipe is a match, a tool and a command template, so
adding one is a settings change rather than a release. Drag order *is* offer order; cost
tags (Stream copy / Re-encode / Last resort) drive how the queue presents each.
**Full spec:** `13-settings.md (13a)`

### 15. Settings · Tag Category Configuration — `Mac Settings Category Order.dc.html`
**Swift:** `SettingsView.swift`
**Purpose:** the global category order and each surface's own.
**Key decisions:** four surfaces each remember their own order; a global order seeds them.
The lock forces every surface to follow global — and **locking hides divergence rather than
erasing it**, so unlocking restores each surface's arrangement.
**Full spec:** `13-settings.md (13b)`

### 16. Devices — `Mac Devices.dc.html` (net-new — no Swift view yet)
**Purpose:** pair and authorise clients (Phase 9).
**Key decisions:** Bonjour discovery, a six-digit single-use code with a live countdown,
**fingerprint confirmation** before trust (pinned, never a trust store). Roles are per
library. **Pairing is not access** — a new device arrives with every library set to None and
reads as `Requesting access` until granted. A known fingerprint refreshes its device rather
than creating a second identity.
**Full spec:** `15-devices.md`

### 17. Command palette — `Mac Command Palette.dc.html` (net-new)
**Purpose:** ⌃K over any window.
**Key decisions:** one list spanning Go to / Filter / Tag / Do / View, with the tag
vocabulary searchable too. Commands are **scoped to the selection** — greyed with the
requirement, not hidden. Commands needing an argument drill into a second level.
**Full spec:** `16-command-palette.md`

### 18. Platform canvas — `Platform Canvas.dc.html`
**Purpose:** macOS / iPadOS / iOS / tvOS side by side with a **rev switcher** (1–4) that
drives every panel and the capability matrix. Library creation and vocabulary authoring stay
Mac-only on every rev; iOS stops at Rev 3; tvOS is complete at Rev 1 because viewing is all
it will ever do.

## Interactions & Behavior

Beyond the per-screen notes above, these recur:

- **Esc unwinds one layer**, never two — an open popover before a selection; the player's
  panels before the window.
- **Tab walks focus zones** in the player (video → tags → segments → queue), shown in a
  status bar. Zone rings are a subtle 1px inset amber, not a hard border.
- **Drag to reorder** wherever order is meaningful (categories, join parts, repair recipes,
  rule actions). Lists reorder *live* on dragover so the drop confirms what you already see.
- **Right-click steps a three-way filter backwards**; left-click cycles forward.
- **`V` cycles saved tile views**; `?` opens the player's keyboard map.
- **Unavailable, not hidden** — any command whose preconditions are unmet stays visible,
  greys, and states the requirement where its description goes.
- **Progress is derived from a clock** that accounts for paused spans, never an accumulating
  tick. Three separate bugs came from getting this wrong.

## State Management

Per window, the state that matters:

- **Browse:** filter slot map (tagID → required|optional|excluded), media-kind set, folder
  selection, search text, selection set, saved tile views + active index, thumbnail size,
  true-aspect flag, hide-offline flag.
- **Player:** playhead, playing, focus zone, applied tags per category, segments (kind,
  start, end), mark-in point, flags, triage mode, panel visibility, active keyboard map.
- **Operations / Review / Analysis:** included-item set, per-operation settings, staged
  decisions, resolved/handled sets, job progress derived from `startedAt` + `total`.
- **Devices:** paired devices with per-library roles, pairing session (`code`, `startedAt`,
  fingerprint), serving flag.

Data fetching follows the existing patterns: GRDB reads off the main actor with generation
counters to drop superseded results (the PR #38 pattern already in `CategoryManagerView`),
and a 1s poll for job state in `BackgroundTasksView`.

## Design Tokens

In **`design-tokens.md`** — surfaces, text tones with measured contrast ratios, accent and
status colours, the five fixed tag-category hues, type scale, geometry, and five layout
rules that cost real iterations (shared column grids and scrollbar gutters, `box-sizing`,
never `direction: rtl` for path truncation, clock-derived progress, one name in one place).

Fonts: **Archivo** (UI) and **JetBrains Mono** (every filename, path, count, duration, size,
timestamp, job kind, command). Both Google Fonts. In SwiftUI, register both and never set a
count or filename in the UI face.

## Model changes the design assumes

Listed with rationale in `README-specs.md` and in each spec's own **Model changes** table.
Worth landing before the views that depend on them — notably `displayAsCheckboxes: Bool` → a `displayStyle` enum adding radio,
dropping `isDefaultFocus` in favour of order, and a cached per-library summary so the picker
need not open every file at launch.

## Assets

None. No icons, images or fonts ship in this package.

- **Thumbnails** are CSS gradient placeholders standing in for `AVAssetImageGenerator` output.
- **Icons** are Unicode glyphs standing in for **SF Symbols**. Where the existing Swift already
  names a symbol (`clock`, `checkmark.circle.fill`, `xmark.circle.fill`, `minus.circle`,
  `scissors`, `bolt`, `bandage`, `link`, `eye.slash`, `text.viewfinder`), use those.
- **Fonts** are loaded from Google Fonts in the prototypes; bundle them in the app.

## Files

**Screenshots** — `screenshots/`, one per design, numbered to match the screen sections
above. Each is the whole design scaled to fit, note cards included. Useful for a quick read;
the `.dc.html` files are the reference, since they are interactive.

`screenshots/archive-2026-08-28/` holds the previous set, captured before the specs were
finished. Kept for history only — where the two differ, the current set is right.

**Designs** (open in a browser; `support.js` must be alongside):

`Mac Library Picker.dc.html` · `Mac Browse Window.dc.html` · `Mac Player Window.dc.html` ·
`Mac Import Window.dc.html` · `Mac Categories and Fields.dc.html` ·
`Mac Tag Analysis Window.dc.html` · `Mac Review Window.dc.html` · `Mac Operations.dc.html` ·
`Mac Organise.dc.html` · `Mac Writeback Backup Validation.dc.html` ·
`Mac Background Tasks.dc.html` · `Mac New Library.dc.html` ·
`Mac Library Properties.dc.html` · `Mac Settings Repair.dc.html` ·
`Mac Settings Category Order.dc.html` · `Mac Devices.dc.html` ·
`Mac Command Palette.dc.html` · `Platform Canvas.dc.html`

**Documentation:**

- `design-tokens.md` — all values, plus layout rules
- `00-what-changed-and-why.md` — every departure from a comp, and why; the judgement calls
  worth revisiting
- `01-library-picker.md` … `16-command-palette.md` — the sixteen full specs
- `README-specs.md` — implementation order, the model changes, cross-cutting decisions

**Superseded** (pre-replatform web-app designs, kept for reference only — terminology is
stale): `Sights and Sounds Prototype.dc.html`, `Library + Player Explorations.dc.html`

## One instruction above the rest

**Read the existing SwiftUI view before implementing its replacement.** Six times during
this design pass, reading the surrounding code materially changed the answer: `SettingsView`
is a `TabView` not a sidebar and has no Sources tab; `BackgroundTasksView` already maps job
kinds to human names and uses per-state icons; `LibraryRef` holds only four fields;
`ItemGridView` already names every operation; `ValidationView` is per-finding, not per-kind;
and `purgeDeleted()` purges everything flagged rather than a set you hand it, which decides
how the delete list's checkboxes have to work. A screen built from the design alone will
invent labels and structures that already exist, and miss the constraint that shapes it.

Each spec's **Keep from the existing view** section lists what that view already gets right.
Treat it as a do-not-touch list.
