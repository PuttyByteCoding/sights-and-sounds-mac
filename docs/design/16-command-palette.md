# 16 — Command palette

**Comp:** `Mac Command Palette.dc.html`
**Swift:** net-new.

⌃K over the library window. One field reaching windows, filters, tagging, operations and saved
tile views — so a command used twice a year does not need a menu anyone can find.

## Decisions

1. **One list, every window.** Windows, filters, tagging, operations and views share the field.
   The five groups (**GO TO · FILTER · TAG THE SELECTION · DO · VIEW**) are headings in the
   results, not modes to switch between — typing searches all of them at once, and typing a
   group name (`filter`, `do`) narrows to it.

2. **Every command's name is the name it already has.** `Optimize (Faststart)`,
   `Export Copy Without Hidden Blocks`, `Scan On-Screen Text (OCR)` come from
   `ItemGridView`'s context menu; `Categories & Fields`, `Background Tasks`, `Tag Analysis` are
   window titles; `Missing — no Band tag` is the browse filter row (spec 02 §3). The palette
   must not paraphrase, or it becomes a second vocabulary for the same actions.

3. **Scoped to the selection, and unavailable rather than hidden.** A command needing two items
   is listed and greyed with the requirement **where its description goes** — the same rule as
   the operations sidebar (spec 08 §3) and the shared decisions. Changing the selection changes
   what is reachable; that relationship is only learnable if the greyed rows stay visible.

4. **Arguments are a second step, never a guess.** `Add a Band tag…` and `Encode a Copy…` drill
   into a second level scoped to that command — the ellipsis means it. Escape steps back one
   level before it closes, so a wrong turn costs one key.

5. **Empty means recent.** With no query, the field shows what was last used, not an
   alphabetical dump. The palette should reward the second use of a command more than the
   first.

6. **The user's own vocabulary is searchable.** Tag names and category names are results, not
   just command names — typing `cedar` should find the Venue. That is what makes it faster than
   the sidebar rather than a keyboard-shaped copy of it.

7. **Clearing the field is a DOM write, not just state.** Noted in the comp because it bit
   there: after a drill, the field must be emptied explicitly or the second level inherits the
   text that opened it. The same trap exists with an `NSTextField` bound to a value that did
   not change.

## Command inventory

Ship these; every one already exists somewhere in the app.

**Go to** — Browse `⌘1` · Categories & Fields `⌘2` · Tag Analysis `⌘3` · Import `⌘I` ·
Review `⌘4` · Organise by template · Background Tasks `⌘0` · Devices · Library Properties ·
Open Library… `⇧⌘O` · Settings ▸ Repair

**Filter** — Clear the filter `⇧⌘K` · Missing — no `<Category>` tag (one per category) ·
★ Favourites · Needs review · Playback issue · Hide offline items · `<Category>` is… (drills)

**Tag the selection** (needs 1) — Add a `<Category>` tag… (drills) · Mark reviewed `R` ·
Mark playback issue `W` · Mark for deletion `D`

**Do** (needs 1, Join needs 2) — Encode a Copy… (drills to preset) · Optimize (Faststart) ·
Repair Container · Join Files · Export Clip to File · Export Copy Without Hidden Blocks ·
Scan On-Screen Text (OCR) · Write Tags to File · Add to queue

**View** — Tile view · `<name>` (one per saved view, `V` cycles) · Fit tiles to media aspect

Category-derived commands are **generated from the library's vocabulary**, not hard-coded — a
new category gets its filter and tagging commands for free, which is the point of building it
this way.

## What has to be built

| Piece | Notes |
|---|---|
| A `Command` registry: id, group, title, icon, key equivalent, required selection count, optional argument provider | One source per command, shared with the menu bar so a shortcut is never defined twice. |
| Fuzzy match over titles + tag and category names | §6. |
| Recents, persisted per library | §5. |
| Drill state with Escape stepping back one level | §4. |

Stable ids matter: recents store ids, so generate them from the title once (as the comp does)
rather than writing them by hand in two places.

## Layout

A centred sheet over the window — field at the top with the drill breadcrumb when one level
deep, results beneath grouped by heading, a legend at the foot.

Rows: icon, name, the requirement note when unavailable (row at ~50%), and the key equivalent
right-aligned in mono. The highlighted row takes amber. Drill rows show `›` and the argument
name alone.

Legend: `↑↓ move` · `⏎ run` · `esc back` / `esc clear` · `⌃K close`.

## Copy — verbatim

| Element | String |
|---|---|
| Placeholder | `Search commands, tags and windows…` |
| Placeholder, drilled | `Pick a <argument>` |
| Group headings | `GO TO` · `FILTER` · `TAG THE SELECTION` · `DO` · `VIEW` |
| Unavailable note | `needs at least <n> items selected` |
| Empty, no query | `Commands, windows, filters and your own tag names — all from this one field.` |
| Empty, with query | `Tag names, category names and every window are searchable from here.` |
| Legend | `↑↓ move` · `⏎ run` · `esc back` · `esc clear` · `⌃K close` |
