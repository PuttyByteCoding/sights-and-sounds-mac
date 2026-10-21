# Design review — the macOS app against its own specs

Run 20 October 2026 against `dev` at `8b0ec80`, over every app-styled surface
(picker, browse, player, Tag Manager, Import, Background Tasks, Review,
Operations, Organise, Maintenance, New Library, Library Properties, Command
Palette, Tag Analysis, Log) plus the Settings window's own conventions.

**Method and its limit.** This was a read of the SwiftUI views against
`design-tokens.md`, `Theme.swift`, the sixteen specs and their comps — not a
look at the running app, because this session could not take screenshots
(Screen Recording is not granted to it). Every line reference below was
verified in the source; ten of the highest-impact claims were re-checked by
hand after the per-window passes. What a read cannot judge is rendered
density, motion, and how the windows feel together at real sizes. A second
pass with the app open would be worth doing for the browse window and the
player.

The companion `spec-audit.md` (30 August) checked copy strings and
measurements and found them largely present. This review asks a different
question: is what was built *usable, legible, and one system*?

---

## Overall impression

The system is strong and the discipline is real: one token file, two faces
used for what they are for, custom controls reused across windows,
"unavailable, not hidden" implemented better than most apps manage, and
destructive paths that name their count and their alternative. The comps'
reasoning carried into the code.

The biggest opportunity is a single, app-wide one. The tokens file records a
rule "learned the hard way": `#6E6659` (3.4:1) is for non-informational text
only, because sub-AA greys shipped on load-bearing data three times. The code
has `Theme.Text.disabled` in 251 places, and a large share of them are exactly
that data — sidebar counts, relative paths, segment time ranges, validation
details, repair commands, "was …" rename markers, use counts, queue depths —
often at 9–9.5px, under the type scale's 10px floor. The rule is written down
and the implementation drifted past it anyway. Fixing this one thing moves the
whole app more than any per-window change.

---

## Systemic findings (every window)

### S1 · Critical — the "disabled only" tone carries decisions

`Theme.Text.disabled` is documented as "3.4:1 — non-informational only. Never a
value someone reads." Verified load-bearing uses, by window:

| Window | What is drawn in `disabled` | Where |
|---|---|---|
| Browse sidebar | every tag/source/folder count, 10.5px mono | `Browse/SidebarView.swift:804-806` |
| Browse | "+ Add Source…" (a live action reading as disabled); the legend footnote that is the only cycle hint; empty-state guidance | `SidebarView.swift:425, 646`, `ItemGridView.swift:231` |
| Picker | last-opened timestamp (also not in mono) | `LibraryPickerView.swift:523-525` |
| Player | segment time range, 9.5px mono — the value a "which range is this" decision depends on | `Player/PlayerView.swift:1339-1341` |
| Player | the footer "where do my keys go" hint; `N songs · N clips`; `N applied` | `PlayerView.swift:1167, 1273`, `TagPanelView.swift:80` |
| Watched | relative path 10px mono; watch count | `Browse/WatchedView.swift:104-106, 117-119` |
| Import | `N new · N known` per folder (the scope decision), 9.5px; candidate folder path 9.5px; `N already in library` | `Browse/ImportView.swift:426-428, 1045-1051, 571-573` |
| Background Tasks | queue depth; raw job kind (the string the spec says you grep the log for), 9px; lane progress and state; elapsed | `BackgroundTasksView.swift:440-470, 516-551, 638-641` |
| Tag Manager | `N uses` (what the delete confirm depends on), 9.5px; Aliases column; category meta line, 9px | `Browse/CategoryInspector.swift:226-228`, `CategoryTagTable.swift:214-216`, `CategoryManagerView.swift:221-223` |
| Review | delete-list folder path, 9.5px; repair command and time estimate; the safety line itself | `Browse/ReviewView.swift:383-385, 834-845, 133-135` |
| Maintenance | validation finding detail ("row says a, disk says b"); write-back skip reason and field name; backup and run timestamps | `Browse/MaintenanceView.swift:378-380, 251-260, 310, 453` |
| Organise | move-history from/to paths; plan source folder | `Browse/OrganiseView.swift:415-431, 241-243` |
| New Library | `was <original name>` rename marker 10px; collapsed category summary 9.5px; aliases 9px; the order note carrying decision §3 | `NewLibraryView.swift:515-522, 573, 267-269` |
| Library Properties | the three notes the spec says prevent a misunderstanding (overrides, separators, coverage) | `LibraryPropertiesView.swift:154-157, 237-240, 321-324` |

**Recommendation.** Add `Theme.Text.meta` as an alias of `quaternary` (5.0:1,
the documented floor for 10–12px) and sweep every `disabled` that sits on a
value, a path, a count, a hint or an instruction over to it. Reserve `disabled`
for controls that are actually disabled. At the same time lift every
`Theme.mono(9)` / `mono(9.5)` / `ui(9)` to 10 — nothing in `TypeScale` is
below 10, and the comps do not measure anything smaller.

### S2 · Moderate — hit targets and labels on icon-only controls

A recurring shape: a bare glyph at 8–10px in a `.plain` button, no frame, no
`contentShape`, often no `accessibilityLabel`. Verified: filter-row remove ×
at 8pt (`SidebarView.swift:278-284`); segment play/remove at `ui(9)`
(`PlayerView.swift:1345-1354`); pill remove at `ui(8)` (`TagPanelView.swift:717`);
transport icons framed to width 20 with no height (`PlayerView.swift:969`);
drawn 13×13 checkboxes with no label or toggle trait in Operations
(`OperationsView.swift:257-274`), the tag table (`CategoryTagTable.swift:187-199`)
and Import (`ImportView.swift:395-406, 1026-1037`); the favourite `★` that
VoiceOver reads as "black star" (`CategoryTagTable.swift:226-234`); move
arrows at `ui(9)` in New Library, Library Properties, Tag Analysis and the
recipe editor; the running job's in-row **Cancel** as 10.5px plain text
(`BackgroundTasksView.swift:555-559`) — an irreversible action on a ~12pt
target. Review's delete-list checkbox (`ReviewView.swift:371-375`) is the
model: label, value, trait.

**Recommendation.** One `IconButton` helper that applies
`.frame(minWidth: 22, minHeight: 22).contentShape(Rectangle())` and requires a
label; adopt it in the places above. Sort glyphs at `ui(7)` and `mono(8)`
(`CategoryTagTable.swift:167-173`) go to 10.

### S3 · Moderate — status, error and success are one colour in several windows

Operations writes a failed enqueue into `status` and paints it amber, the same
as "Queued" (`OperationsView.swift:374-377, 468`). Tag Manager writes the merge
success into `errorText` and paints it red (`CategoryManagerView.swift:185-190, 739`).
Library Properties shows "Rename failed" and "Backup failed" in the amber
success strip (`LibraryPropertiesView.swift:54-56, 406-484`). Review and
Operations put errors in the footer; Organise and Maintenance put them in the
header.

**Recommendation.** One `StatusLine` with `notice` / `error` cases, in one
place per window, red for errors and the Background Tasks toast pattern for
successes.

### S4 · Moderate — first paint is a false empty state

Review, Maintenance, Organise and Operations all draw their empty state ("No
pending duplicates", "No Findings", "No Moves Yet", every operation
"unavailable for this selection") until the first read returns
(`ReviewView.swift:310-314`, `MaintenanceView.swift:345-353`,
`OrganiseView.swift:363-372`, `OperationsView.swift:379`). On a large library
over a slow drive that is a visible lie for a moment.

**Recommendation.** A `loaded` flag per window; the empty state only appears
once it is true, with nothing (or a quiet placeholder) before.

### S5 · Minor — the exemption list has grown without being written down

`Theme.swift` names three deliberate exemptions from the tokens (Settings, the
recipe editor, symbol sizing). Four more places use system styling and are not
on the list: the browse window's own status strip (`.font(.caption)`,
`.secondary`, `.background(.bar)` — `LibraryWindowView.swift:321-326`), the
Watched window footer (`WatchedView.swift:175-181`), the Log window as a whole
(`LogView.swift:60-73`), and the key-bindings editor and search-recipe panel
inside the player (`KeyBindingsEditor.swift:57-167`, `SearchPanel.swift:123-142`).
The `.bar` material and the Log window track the system appearance and will
open light beside charcoal windows. Two hex literals also live outside the
token file (`BackgroundTasksView.swift:774-775`), one of them borrowing the
player's song colour for ingest jobs.

**Recommendation.** Theme the browse status strip, Watched footer and the two
player sheets (they are inside charcoal windows); either theme the Log window
or add it to the exemption list with `.preferredColorScheme(.dark)`; add a
`Theme.JobFamily` palette.

### S6 · Minor — selection and radius have more variants than the tokens define

Five selected-row treatments (sidebar: `selectedRow` + inset; tag table and
Import: `selectedRow` without inset; tasks: `selectedSegment` + inset;
category suggestions: hue at 16%; universal suggestions: `selectedRow` on a
chip radius). Radii 3, 5 and 8 appear beside the token scale of 4/6/7/9.

**Recommendation.** One `selectedRow()` modifier and one `highlightedSuggestion()`
modifier; map stray radii to the nearest token.

---

## Per-window findings

Severity: 🔴 Critical · 🟡 Moderate · 🟢 Minor. Systemic items above are not
repeated here.

### Library picker

| Finding | Sev | Where | Recommendation |
|---|---|---|---|
| Button row mixes three idioms: two themed compact secondaries, three unstyled system `Button(…, systemImage:)` with icons the themed ones lack, and a `.caption` busy label — seven controls where the comp has three | 🟡 | `LibraryPickerView.swift:239-247`, `SightsAndSoundsApp.swift:873, 938, 1017` | Apply `SecondaryButtonStyle(compact:)` to all; fold Demo / Signal Samples / Connect into one **More…** menu |
| Rows are `onTapGesture` views — no combined accessibility element, no button or selected trait, no arrow-key movement; the only keyboard path is Return on the default | 🟡 | `LibraryPickerView.swift:529-535`, `ClickGesture.swift:19-26` | Button-backed rows with `.isSelected`, ↑↓ moves the selection (the sidebar already did this) |
| "This window" dot is orange where the spec says amber; the note is ad-hoc `ui(12)` beside `TypeScale.body`; the remote-host header hand-rolls a section label | 🟢 | `LibraryPickerView.swift:213, 217, 355-357` | `Accent.amber`, `TypeScale.body`, `Theme.sectionLabel()` |

### Browse window

| Finding | Sev | Where | Recommendation |
|---|---|---|---|
| Right-click does not step the filter cycle backwards — the spec's "a four-state cycle with no reverse is a guessing game"; right-click opens the tag menu and no caller passes `reverse: true` | 🟡 | `SidebarView.swift:1083-1105` | Put explicit Required / Optional / Excluded / Clear items at the top of the tag menu so any slot is one click |
| The keyboard features (V, X, Space, Return, ⌘A, ⌃K) have one on-screen hint, inside the View Options popover, in 10px `disabled` | 🟡 | `LibraryWindowView.swift:266-270`, `ItemGridView.swift:132-177`, `GridViewOptions.swift:98` | Use the always-present status strip's empty left half for a short key legend; expose ⌃K in a menu |
| Bulk bar has nine equal-weight controls in three idioms (compact buttons, system borderless menus in the system font, a plain-text "Deselect · esc") against the spec's five | 🟡 | `ItemGridView.swift:584-646` | One **Mark…** menu for Review / Deletion / Won't play; a themed menu label |
| Category header embeds its count in the Archivo section label while every other count is mono; empty-slot arrows use a border token as text colour | 🟢 | `SidebarView.swift:1061`, `GridViewOptions.swift:225` | Trailing `CountText`; `Text.disabled` for the arrows |
| The sidebar search field never changes stroke on focus while the rename and save-filter sheets do; deleting a saved view has no confirm while deleting a saved filter does | 🟢 | `SidebarView.swift:903-906, 1241-1246`, `GridViewOptions.swift:142-151` | Same focused stroke everywhere; confirm both or neither |

Not a defect: the spec's chip bar above the grid was replaced by a pinned
filter block in the sidebar, with a stated reason (it stays visible while the
player owns the column). It reads as a sound trade; spec 02 should be updated.

### Player

| Finding | Sev | Where | Recommendation |
|---|---|---|---|
| Sheets are keyboard dead ends: the key-map sheet's only exit is a Done button with no `.cancelAction`, and the search field takes focus on open, so `?` lands you somewhere Esc cannot leave; the OCR sheet's Cancel likewise | 🔴 | `PlayerView.swift:2060-2070`, `OcrLinesPanel.swift:312` | `.keyboardShortcut(.cancelAction)` on every Cancel/Done; `.defaultAction` on Done |
| The `?` cheat sheet is buried in the "More" menu rather than the comp's standalone toolbar button; and because the first tag field takes focus on load, `?` types a question mark instead of opening the sheet | 🟡 | `PlayerView.swift:762-778, 237, 316`, `TagPanelView.swift:817-819` | Visible `?` toolbar button; let `?` through the text-input guard like the F-keys |
| Segment rows are `onTapGesture` — no button trait, no accessibility action; rename is double-click only with no `.help`, menu item or key | 🟡 | `PlayerView.swift:1374-1383` | `onTapAsButton` traits on the row plus a **Rename** context-menu item |
| The tag panel opens with an "all tags" search field above the rows that duplicates the Universal row's find-in-any-category — two bordered wells doing one job are the first thing the eye lands on | 🟡 | `TagPanelView.swift:156-199, 906-952` | Fold the toggle behaviour into Universal and remove the extra field |
| Mono rule inverted: History sets the filename in Archivo; the applied-tags strip sets tag names in mono while the same tags are Archivo in the panel pills | 🟡 | `HistoryPanel.swift:87-89`, `AppliedTagsStrip.swift:30`, `TagPanelView.swift:710-712` | Mono for the filename, UI face for both pill sets |
| Spec'd segment duration is not drawn beside the range | 🟢 | `PlayerView.swift:1339` | Append `· <duration>` |
| Mode signalling is uneven: triage is announced only by its toolbar button; the Queue panel has a zone ring but no Tab badge; the footer says "numpad seek" to laptop users whose seek layer is off | 🟢 | `PlayerView.swift:1077, 1189-1202, 1784-1854` | "Triage · N done" in the footer; Tab badge on the queue header; name ⌃⌃ in the base hint |

### Tag Manager

| Finding | Sev | Where | Recommendation |
|---|---|---|---|
| The "Similar only" cluster header applies the uppercase section-label modifier to the winner's name, so a case-only drift (`northlight sessions` vs `Northlight Sessions`) is invisible in the header that exists to show it | 🟡 | `CategoryTagTable.swift:111-112`, `Theme.swift:280` | Render VARIANTS as the label and the name as a separate `Text` without `textCase` |
| Three commit models in one inspector with no affordance: toggles save on change, Name saves on Enter only (click away loses the edit), Notes debounce-save | 🟡 | `CategoryInspector.swift:31, 149-156, 239, 299-312, 401` | Commit text on focus loss as well as Enter, or show the "Enter to save" hint `TagSheet` already has |
| Delete Category is styled identically to the Add button three lines above it; Delete Tag sits inside a section titled "Instead of deleting" | 🟡 | `CategoryInspector.swift:116-117, 413, 435-436` | Divider + spacer, red outline, Delete outside the "convert instead" section |
| The sidebar's drag handle does nothing; reorder is a context-menu Move Up/Down | 🟢 | `CategoryManagerView.swift:203-205, 240-243` | Remove the handle or wire it |
| Mixed segmented idioms (system `.segmented` and `ThemeSegmentedControl`) and mixed "new" affordances (`plus` glyph vs typed `+ Tag`) in one window | 🟢 | `CategoryManagerView.swift:125, 487-493`, `CategoryTagTable.swift:44-55` | One of each |

### Import

| Finding | Sev | Where | Recommendation |
|---|---|---|---|
| Step strip distinguishes done/current/pending by 7pt dot colour and weight only, pending names in `disabled`; the comp uses numbered markers | 🟡 | `ImportView.swift:979-1009` | Numbered markers with a check on done |
| Stage rail lacks the spec's Whole import / Per folder control and per-folder dot; the copy describes a different model; no Resolution column | 🟢 | `ImportView.swift:453-460, 507` | Build or write the deviation into spec 05 |
| `N selected` and `scanned <relative>` are the two counts in the UI face | 🟢 | `ImportView.swift:587-589, 1123-1125` | `Theme.mono` |

### Background Tasks

| Finding | Sev | Where | Recommendation |
|---|---|---|---|
| The sweeps panel sits between toolbar and lanes and takes ~320pt of a 560pt minimum window, so the lanes and table — "the state of the machine at a glance" — are below the fold; spec 06 has no sweeps block there | 🔴 | `BackgroundTasksView.swift:59-70`, `SweepPanel.swift:56-144` | Collapse Sweeps into a disclosure closed by default, or move it under the table / into the inspector's no-selection state |
| Progress bars are the stock `ProgressView` — system accent blue on charcoal, the only system-tinted control in the app (no `.tint` anywhere); a running row shows the bar with no `current/total`; the inspector has no progress at all | 🟡 | `BackgroundTasksView.swift:458, 536, 631-689`, `ImportView.swift:228, 618, 625`, `SweepPanel.swift:123` | A `ThemeProgressBar` (well track, amber fill, striped when running); numbers beside the bar |
| Inspector actions are hidden rather than greyed when unavailable, against the house rule | 🟢 | `BackgroundTasksView.swift:692-698` | Disable with a `.help` reason |

### Review

| Finding | Sev | Where | Recommendation |
|---|---|---|---|
| The delete list's reclaimable bytes are for the whole flagged set, not the ticked set, and the confirm names no bytes — Maintenance's purge button does | 🟡 | `ReviewView.swift:148, 458, 467-472`, `MaintenanceView.swift:538` | Sum sizes over the ticked set for button and dialog |
| Spec 07's 300pt inspector (how these got here · pending decisions · the three-bullet SAFETY block) has no counterpart; the one safety line is in `disabled` | 🟡 | `ReviewView.swift:133-135` | At least `tertiary`; ideally the three-bullet block Maintenance's sidebar already has |
| Operations' join order says "Drag to reorder" but there is no drag; the ↑↓ are 9pt icon-only buttons | 🟡 | `OperationsView.swift:179, 192-201` | "Use the arrows to reorder" and 22pt labelled arrows, until drag ships |
| Write-back is reachable from Operations without the prior-value preview spec 10 makes mandatory; its cost is a hard-coded 0.5s per file | 🟡 | `Operation.swift:203, 247-251` | Route `.writeTags` to Maintenance's preview, or add an "existing values replaced" cost row |
| Two purge confirms differ in shape (short question + unlabelled "Delete" vs two-sentence title + "Delete N Items" + Cancel) | 🟢 | `ReviewView.swift:466-472`, `MaintenanceView.swift:548-554` | One shape: titled question, count and bytes in the body, count-bearing destructive button |

### Maintenance and Organise

| Finding | Sev | Where | Recommendation |
|---|---|---|---|
| Write-back's safety bullet promises "A run can be reverted whole" and spec 10 puts **Restore embedded tags** on every history row; the history shows scope + timestamp only and no restore action exists in the window | 🔴 | `MaintenanceView.swift:447-462, 492` | Add the per-run restore and its applied / reverted chip, or drop the promise until it exists |
| The overwritten value is distinguished by strikethrough alone, which VoiceOver does not read | 🟢 | `MaintenanceView.swift:272-276` | Prefix a mono "was" label |
| Reverted history rows stack `.opacity(0.6)` on paths already in `disabled` (≈2:1); "Put back" is a 10.5px text link; "Put all back" is hidden rather than greyed | 🟢 | `OrganiseView.swift:402-405, 436-448` | Full opacity with the strike and the word carrying state; compact secondary button that disables with a reason |

### New Library, Library Properties, Settings, Command Palette, Tag Analysis, Remote

| Finding | Sev | Where | Recommendation |
|---|---|---|---|
| Configuration can remove separators and extensions but never add one — no add field for either (spec 12 draws both); `newExtension` state is declared and unused | 🟡 | `LibraryPropertiesView.swift:29, 210-241, 294-319` | Add the two fields |
| Command palette halves the whole unavailable row, so the requirement note (orange at 50% on the dialog surface, ≈2.3:1) is the least legible thing on the row | 🟡 | `Browse/CommandPalette.swift:223-244` | 50% on icon and title only; the note at full opacity |
| Remote Access is the last Settings tab, after the three per-library panes, breaking the app-wide-then-per-library order the window promises; nine tabs at 560pt | 🟡 | `SettingsView.swift:10-30` | Move it after Repair; shorten "Tag Category Configuration" |
| Pairing's code stage has no countdown; the sheet simply closes when the host drops the code, so the "used or run out" copy is unreachable and nothing afterwards says what happened | 🟡 | `Remote/RemoteAccessSettingsPane.swift:140-175` | A text remaining-time line; a status line in Pair a Mac after dismissal |
| Repair pane says recipes are offered "in this order" but gives no way to reorder them; no add-recipe / add-tool action; two risk cases where the spec names three cost labels | 🟢 | `SettingsView.swift:858-901` | ↑↓ per recipe at minimum; note the third label is unmodelled |
| Template hue dot keyed off `hashValue`, which is seeded per launch — a template changes colour each run | 🟢 | `NewLibraryView.swift:219-221` | Index by `allCases.firstIndex(of:)` |
| The candidate → rule loop works but none of the spec's bridging copy appears ("New rule from "x" — add an action…" / "Already covered — showing it"); `makeRule`'s made-vs-found result is discarded | 🟢 | `TagAnalysisView.swift:276-282`, `RulesTabView.swift:176-179` | One status line driven by the result |
| Remote Access hand-rolls its scope line instead of `ScopeHeader`; the connect sheet uses system rounded fields on the app dialog surface where sibling dialogs use the well style; the selectable candidate text is the one mono value not in JetBrains Mono | 🟢 | `RemoteAccessSettingsPane.swift:20-26`, `ConnectToAnotherMacSheet.swift:53, 148-153`, `TagAnalysis/SelectableValueText.swift:987` | `ScopeHeader`; the app field style; `Fonts.monoFamily` for the NSTextView |

---

## What works well

- **The filter vocabulary is never colour-only.** Glyph + hue + strikethrough on
  the row, an outlined chip at rest, an `accessibilityValue` of
  required/optional/excluded/not filtering, and a tooltip that says "12 of 70
  survive" (`FilterSlotStyle.swift:48-68`, `SidebarView.swift:1137-1192`).
- **Tiles are first-class for VoiceOver**: name, state value, button + selected
  traits, a default Play action and a named Select action; keyboard focus and
  selection are visually distinct (`ItemGridView.swift:277-332`, `TileAccessibility.swift`).
- **One key table feeds every hint in the player** — tooltips, the marking
  indicator, the empty-segments copy and the footer all read
  `model.keyMap.labels`, so the chooser and the cheat sheet cannot drift
  (spec 03 decision 3, done exactly). The focus model is visible three ways
  without a keypress: zone ring, footer chips, Tab badges.
- **Operations' "unavailable, not hidden" is the best implementation of the
  rule in the app**: the requirement replaces the description, the primary
  button repeats it as its label, the cost chip sits on every row, and the
  inspector's costs recompute from the ticked set.
- **Irreversibility is handled with care where it matters most.** Delete
  confirms name the count and the alternative; Convert-to-alias is offered
  above Delete; Paste List shows `n new / n already exist`; Import's primary
  names its count or says Nothing selected; Review's delete checkbox is fully
  labelled and ticks survive reloads; unsaved segments interrupt the purge
  before the confirm.
- **Background Tasks tells the truth in its states**: family colour and state
  pill are two encodings of two facts, "not answering" is distinct from idle,
  toasts say what actually happened, the error block is full-text and
  copyable, elapsed is derived from the clock.
- **Library Properties applies layout rule 1 exactly**: a fixed 76pt action
  column that coverage rows fill with clear space, so a row with a button
  never drags the columns above it.
- **Shared chrome is consistent where it counts**: `PrimaryButtonStyle`,
  `SecondaryButtonStyle`, `ThemeSegmentedControl`, `ThemeBadge`, `PathText`
  (middle-truncated, full path in `.help`), `CountText` dimming zeros instead
  of hiding them, 62pt toolbar footers with a 1pt rule.

---

## Priority recommendations

1. **The contrast sweep (S1 + S2).** One mechanical pass: `disabled` → a new
   `meta` alias of `quaternary` wherever the text is a value, path, count,
   hint or instruction; every 9–9.5px size → 10; a shared `IconButton` with a
   22pt target and a required label. This touches most files but is low
   judgement and fixes the single largest accessibility problem, which the
   tokens file itself predicted.
2. **The player's two keyboard traps.** `.cancelAction` on every sheet's exit,
   and `?` reachable from a focused tag field with a visible toolbar button.
   The player is the window where the keyboard model is the product; a sheet
   Esc cannot leave undermines the whole "Esc unwinds one layer" promise.
3. **Background Tasks' first screen.** Collapse the sweeps panel so lanes and
   table are above the fold, theme the progress bars (the only system-blue
   control in the app), and put `current/total` beside a running row's bar.
4. **One status line, one empty-state gate (S3 + S4).** Errors in red and in
   one place per window; success never in `errorText`; empty states only
   after the first read lands.
5. **Keep the promises or retract them.** Maintenance's "revert a run whole"
   and Operations' "Drag to reorder" describe affordances that do not exist;
   either build the restore action and the drag, or change the copy today.

Two spec updates fall out of this rather than code changes: spec 02 should
record the pinned filter block replacing the chip bar, and spec 05 the import
stage rail as built.
