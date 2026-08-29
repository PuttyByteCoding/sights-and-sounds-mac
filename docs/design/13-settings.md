# 13 — Settings

**Comps:** `Mac Settings Repair.dc.html`, `Mac Settings Category Order.dc.html`
**Swift:** `SettingsView.swift` (`SettingsView` ~8, `ScopeHeader` ~58, `PathSettingRow` ~88,
and the six panes), `Settings/AppSettings.swift`

## What changes

**Read `SettingsView` before designing anything here.** It is a `TabView`, not a sidebar —
General · Import · Playback · Jobs · Tag Category Configuration · Library Import — and three of
its decisions are already made and correct: every pane opens with a `ScopeHeader` saying
whether the setting reaches this Mac or one library; the window is resizable with a persisted
frame (there is a whole `NSViewRepresentable` forcing the resizable bit AppKit omits); and
`settings.json` is hand-editable with missing keys falling back to defaults, which the General
pane says out loud.

Two tabs are added — **Repair** and **Category Order** — and one existing pane loses rows.
Nothing is restructured.

## 13a · Repair

1. **Recipes are data, not code.** A recipe is a match, a tool, a command template, an estimate
   and a cost label. Adding "untrunc for truncated MP4s" becomes a settings change rather than
   a release, and the Review window's issue queue (spec 07) reads this list instead of carrying
   a `switch` over failure kinds.

2. **Tools are declared once, separately.** Each external binary is registered with its path
   and version and referenced by name. A recipe whose tool is missing is **flagged in place**
   — `untrunc not found` on the card — rather than silently never matching. Each tool row shows
   how many recipes depend on it, with **Test** when found and **Locate…** when not.

3. **Cheapest first is a choice, so order is the offer order.** Drag to sort; the queue offers
   them top-down. The cost label tells the queue how to present each one:
   **Stream copy** (lossless, offer first) · **Re-encode** (time and a generation of quality) ·
   **Last resort** (salvages what decodes, loses the rest — shown last, never auto-selected).

4. **A new recipe arrives disabled.** It is a command line that will be run against real files;
   the enable checkbox is the "I have tested this" gesture. Say so when it is created.

5. **App-level, and sources are absent by construction.** Tools and recipes are tooling, not a
   library's vocabulary. A source belongs to exactly one library, so it lives in the library —
   this pane never grows a source list.

## 13b · Category order

1. **One order to start from, per surface.** The global order is the default; a surface with
   its own order has diverged. `null` means follow global, which keeps this one setting plus
   four optional overrides rather than five lists to maintain.

2. **The surfaces genuinely disagree, which is the whole reason.** You filter by Venue and tag
   by Band. Browse sidebar, player tag panel, import staging and library review each get their
   own row, each captioned with *why* it might differ.

3. **Locking hides, it does not erase.** Lock on: every surface follows global and cannot be
   rearranged. Lock off: each one gets its divergence back. A setting that silently discards
   the arrangement you built is a setting you stop touching.

4. **Show the divergence count where the lock is** — `2 of 4 diverged` / `all matching global` /
   `locked to global` — so the state of the whole system reads before any row does.

This is the parked follow-up from `CLAUDE.md`, and it is specified here only. Do not build it
until tagging is called finished.

## 13c · Changes to existing panes

- **Playback ▸ Info bar** loses `Tags` and `Favorite star` (spec 03 §7 gives both facts a
  permanent home); `Position` and `Save a Copy button` remain.
- **Playback ▸ Fixed keys** gains the key-map choice from spec 03 §3 — one control, four rows
  of consequence, with the `?` sheet as the full reference.
- **Jobs ▸ OCR** gains the rest of `OcrSettings` (spec 08 §9) as the *defaults*; the operations
  window overrides them per run.
- **Tag Category Configuration** stays read-only, as its header comment insists. Editing lives
  in the Categories & Fields window (spec 04). Do not introduce a second editor.

## Model changes

| Change | Why | Where |
|---|---|---|
| `ExternalTool`: name, path, detected version, last verified | 13a §2. | new app-level table |
| `RepairRecipe`: name, failure kinds, match pattern, tool, command template, estimate, cost label, enabled, sortOrder | 13a §1; shared with spec 07. | new app-level table |
| `categoryOrder`: global `[UUID]`, `locked: Bool`, and `[surface: [UUID]?]` | 13b. Stored app-level but keyed by category ID, so it is per library in practice — decide which and be consistent. | `Settings/AppSettings` |

A category ID is library-scoped, so a global category order cannot literally be app-wide.
Store it **in the library file** alongside the vocabulary it orders, and surface it in this
pane with a `ScopeHeader(scope: .library)` and a library picker, the way `Library Import`
already does.

## Layout

Both panes live inside the existing `TabView`; the comps draw the tab strip only for context.
Keep `ScopeHeader` at the top of each — app for Repair, library for Category Order.

**Repair**: tools block first (row per binary: status dot, name + version, mono path, recipe
count, action), then recipe cards — drag handle, enable box, name, failure-kind chip in blue
`#8FA6D6`, cost chip (green/amber/red), estimate, and the command in mono. A missing tool shows
its warning on the card. The selected recipe opens an editor beside or beneath: name, kinds,
tool, match pattern, command template, cost, estimate.

**Category order**: the global order as draggable hue chips, the lock checkbox with its
explanatory note, then one card per surface — icon, name, why-line, state chip, **Reset** when
diverged, and its own chip row (inert and non-draggable while locked).

## Copy — verbatim

| Element | String |
|---|---|
| Cost labels | `Stream copy` / `Nothing is re-encoded — the fastest and only lossless option. Prefer these first.` · `Re-encode` / `Rewrites the affected stream. Costs time and a generation of quality.` · `Last resort` / `Salvages what decodes and loses the rest. The queue shows these last and never auto-selects them.` |
| Missing tool | `<tool> not found` · `Locate…` · `Test` |
| Add tool | `Point at a binary — the app records its path and version, and it becomes available to recipes` |
| New recipe | `Added, disabled until you have tested it` |
| Lock, on | `On. Every surface follows the global order and cannot be rearranged on its own. Divergent orders are remembered, not discarded — unlock to get them back.` |
| Lock, off | `Off. The global order is a starting point; any surface can be dragged into an order that suits the work done there.` |
| Surfaces blurb | `Drag within a surface to give it its own order. The browse sidebar and the player rarely want the same one — you filter by Venue and tag by Band.` |
| Surfaces, locked | `Locked. Each surface shows the global order and cannot be rearranged here.` |
| Surface captions | `filter panel — ordered by what you filter on most` · `tagging — ordered by what you type first` · `pre-staged on a batch — ordered by what a whole folder shares` · `creating or migrating a library` |
| State chips | `following global` · `own order` · `<n> of 4 diverged` · `all matching global` · `locked to global` |
| Scope headers | `Applies to this Mac — every library. Stored in settings.json.` · `Applies to the selected library only. Stored in its library file.` *(existing)* |
| settings.json | `Settings live in settings.json in Application Support — hand-editable; missing keys fall back to defaults.` *(existing)* |
| Override note | `The override replaces the app-wide lists — it can drop extensions, not just add. Comma-separated, case-insensitive; applies to the next import. Stored in the library file, so it travels with the library.` *(existing)* |

## Keep from the existing view

The `TabView` — app-wide panes first, then per-library. `ScopeHeader` on **every** pane, new
ones included. `SettingsWindowConfigurator` and the two bug numbers behind it (#73, #101):
minimum not fixed width, infinity maximums so the scene has something to grow into, forced
`.resizable`, and a frame autosave name. `bindSetting`'s read-once/write-through pattern and
`PathSettingRow`'s Choose…/Reset pair with its default label spelled out. Every "applies to the
next…" sentence — each one answers a question that would otherwise be asked once per session.
The vocabulary import's additive promise: *existing categories keep their configuration;
missing categories, tags, aliases and fields are created. Nothing is deleted.*
