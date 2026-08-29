# 04 — Categories & Fields

**Comp:** `Mac Categories and Fields.dc.html`
**Swift:** `Browse/CategoryManagerView.swift`, `Models/TagCategory.swift`,
`Models/FieldDefinition.swift`, `Tagging/TagEditing.swift`, `Writeback/StandardFields.swift`

## What changes

`CategoryManagerView` is a sheet — `HSplitView`, `minWidth: 640`, config `Form` on the left,
the selected category's tags on the right, Done at the bottom. It becomes **its own window**
with three panes, and it gains the two surfaces the model has always supported and the UI has
never shown: **field definitions** and **write-back mapping**.

Read the existing view before starting. Two things in it are load-bearing and easy to break:
the generation-guarded async fetches (fast clicks through a big category must not publish
stale rows), and the comment explaining why `.id(category.id)` must come from the **parent's**
selection — an `.id` inside the detail read its own stale state and every category edited the
first one.

## Decisions

1. **A window, not a sheet.** Authoring a vocabulary is a task, not a preference: it wants to
   stay open beside the grid, be resized, and be returned to. It stays **Mac-only on every
   platform rev**, per the brief — one implementation of the schema-editing surface.

2. **Three panes, one job each.** Sidebar: what exists, in its order — drag to reorder, which
   is a bulk `sortOrder` write, not a per-row save. Table: the tags, with the numbers that
   make a vocabulary judgeable. Inspector: configuration of whatever is selected, tabbed
   **Category / Tag**, always present so a click never costs a sheet.

3. **The tag table is the surface that is missing today.** A name and an ellipsis menu per row
   is enough to fix a typo and nothing else. The table adds use count (mono, right-aligned),
   aliases, favourite, and sortable headers — shift-click adds a secondary sort, with the
   sort position numbered in the header mark. **Counts come from one grouped query per
   category**, never a count per row.

4. **"Similar only" is the drift finder.** Cluster the category's tags by a normalized key
   (lowercase, strip non-alphanumerics, strip a trailing `s`) and show only clusters of two
   or more, most-used first, under a `<n> VARIANTS · <winner>` header. `Ash & Ember` /
   `Ash and Ember`, `Broadside` / `The Broadside`. This is the entire reason the window
   exists for a migrated library.

5. **Merging keeps the discarded spellings as aliases.** Pick two or more tags, then either
   one of the picks as the target or a new name they all fold into. Taggings re-point, source
   names become aliases of the target, sources are deleted — one transaction. Single-select
   categories collapse duplicates rather than doubling up: an item that carried two of the
   merged tags ends with one.

   This does not exist yet. `DuplicateReview.mergeableTags` merges tags **between two media
   items** during duplicate resolution; it is a different operation and must not be
   overloaded. Add `mergeTags(_ sourceIDs:into:keepNamesAsAliases:)` to `TagEditing`, the
   single write path, so normalization and single-select enforcement cannot be bypassed.

6. **Delete is the last resort.** Deleting a tag drops its taggings; converting it to an alias
   folds the name into another tag and keeps them. The tag inspector offers **Convert to alias
   of…** above **Delete Tag…**, and the delete confirmation names the count it is about to
   drop and points at the alternative.

7. **The behaviour list follows the model changes in the README.** `displayAsCheckboxes`
   becomes a three-way **Display style** (Search / Checkboxes / Radio) — a single-select
   category rendered as checkboxes is the wrong control, and radio is the missing one.
   **Default focus disappears**: focus is the first visible category by `sortOrder`, which
   removes the toggle, its exclusivity cascade in `updateCategory`, and the unrepresentable
   conflict behind both.

8. **Write-back is configuration, and it is currently invisible.** `writebackEnabled` and
   `writebackField` exist on every category, are read by `WritebackJob`, are summarized in two
   read-only views — and cannot be set anywhere. Put them in the inspector.

   **Not as free text.** `StandardFields.all` is a fixed table of thirteen keys; anything else
   silently falls back to an uppercased custom field, so a typo looks like it worked and
   writes `ARTSIT`. Make it a picker: **Auto (custom field)** plus the thirteen, with the
   resolved names underneath from `StandardFields.effectiveVorbisName` — the one function that
   computes it. The comp shows a text input; this replaces it.

9. **Two field scopes, two homes.** The schema `CHECK` says a field attaches to every tag in
   one category or to every media item, never both. So `mediaItem` fields are their own
   sidebar entry below the categories, and `tag` fields live inside the category inspector.
   Show the data type as a mono chip, and say next to the type picker why it matters: number
   fields also store a numeric value so ordering is numeric, dates normalize to ISO 8601.
   Lesson ordering in a Learning library is the requirement that settled this.

10. **Paste List is the bulk path.** One name per line, normalized by the category's rule,
    deduped case-insensitively against existing **names and aliases**, with live *new* /
    *already exist* counts before anything is written. It runs `ensureTag` per name in one
    transaction.

## Model changes

Beyond the two in the README's table (`displayStyle`, dropping `isDefaultFocus`):

| Change | Why | Where |
|---|---|---|
| `colorIndex: Int` on the category | The tokens fix a hue per category — Band indigo, Venue teal — and pills, swatches and filter chips in three windows read it. There is no colour on `TagCategory` today, so every surface is inventing one. An index into a fixed palette, defaulting to `sortOrder`, not a free colour picker. | `Models/TagCategory` |
| `mergeTags(_:into:keepNamesAsAliases:)` | §5. The only merge today is duplicate-item resolution. | `Tagging/TagEditing` |
| `tagUsageCounts(inCategory:)` → `[UUID: Int]` | One grouped query behind the Uses column. | `Tagging/TagEditing` |
| `ensureTag` resolves aliases | An alias is a name. Creating a tag whose name matches an existing alias should return that tag, not a rival spelling of it — which is exactly what import and paste keep producing. | `Tagging/TagEditing` |
| Bulk `setSortOrder([UUID])` | Drag-reorder is one write of every row's order, not N saves. | `Tagging/TagEditing` |

Separator characters stay library-wide (`LibraryInfo.separatorCharacters`, README table). The
category owns *whether* separators are converted; the inspector links to Library Properties
for *which*, and does not restate them.

## Layout

Window `1320 × 880`, three columns.

**Sidebar 246 pt**, `#151209`. Category rows: drag handle, hue swatch, name, mono meta line
(`<n> tags · multiple · checkboxes`), `hidden` chip. Selected row `#2A2118` with
`inset 2px 0 0 #E9A23B`. A divided block at the foot holds **Media Item Fields** as a peer
entry with its own count.

**Centre.** Header: category name at 17 px with mono stats beside it, then filter field,
All / Similar only segmented control, and Merge tags · Paste List… · **+ Tag**. Below it a
sticky 31 pt header row on `#141109` over the scrolling table. Columns
`1fr / 150 / 66 / 40 / 34` — name, aliases, uses, favourite, menu — with a 30 pt checkbox
column prepended in merge mode. Both header and rows carry the same grid string and
`scrollbar-gutter: stable`; a header outside the scroller with rows inside it is how these
columns come apart. Merge mode adds a raised bar at the foot: instruction, picked count,
target picker, new-name field, Merge.

**Inspector 326 pt**, `#151209`, two tabs. Category: Name · Behavior (checkbox rows with a
one-line consequence each) · Name formatting (segmented, with a live
`"dave-matthews-band" → "Dave Matthews Band"` preview) · Metadata write-back · Tag fields ·
Delete. Tag: Name with usage · Favourite / Hidden · Aliases as removable chips with an
Enter-to-add field · Field values for this category's tag fields · Convert to alias · Delete.

## Copy — verbatim

| Element | String |
|---|---|
| Window title | `Categories & Fields — <Library>` |
| Item fields header | `Media Item Fields` · `scope mediaItem · applies to every item in the library` |
| Filter placeholder | `Filter tags and aliases` |
| View tabs | `All` · `Similar only` |
| Similar cluster header | `<n> VARIANTS · <most-used name>` |
| Merge instruction | `Pick tags to merge, then a target — one of the picks, or a new tag the picks become aliases of.` |
| Merge result | `<n> tags merged — names kept as aliases` |
| Empty, filtered | `No tags match that filter.` |
| Empty, similar | `No near-duplicate names in this category.` |
| Paste title | `Paste tag list into <Category>` |
| Paste blurb | `One name per line. Names are normalized by this category's formatting rule, deduped against existing tags, and created in chunks.` |
| Paste counts | `<n> new` · `<n> already exist` |
| Behaviour notes | `Band: yes. Year: no — a new pick replaces the old.` · `Renders every tag as a toggle instead of autocomplete. Small fixed sets only.` · `Still editable — just absent from the filter panel.` · `Converts - . _ to spaces before formatting runs.` |
| Write-back note | `Blank writes an uppercased custom field. A standard key (ARTIST, DATE, PERFORMER) maps to the container's own tag.` |
| Tag fields note | `Attach to every tag in this category — Venue gets a City, Taper gets Equipment.` |
| Field sorting note | `Number fields also store a numeric value so sorting is numeric, and dates normalize to ISO 8601 — this is what makes ordering by a field possible at all.` |
| Aliases hint | `match on search & import` |
| Delete category | `Delete "<Name>"?` / `Removes the category, its <n> tags, every tagging that used them, and any field values underneath. This cannot be undone from this window.` |
| Delete tag | `Delete "<Name>"?` / `Removes the tag from <n> items. Consider Convert to alias instead — that keeps the taggings and folds the name into another tag.` |

## Keep from the existing view

The generation counters on both fetches and the reason for them. Identity from the parent's
selection. `List` virtualization — a migrated category holds thousands of tags. The narrow
in-place patch on save followed by a background category reload. `renameTag` refusing a rename
onto an existing name, because merging is a deliberate operation and not a rename side effect.
`hiddenByDefault` and its eye-slash. And the delete-category confirmation's substance: it names
the tags, the taggings and the field values that go with it.
