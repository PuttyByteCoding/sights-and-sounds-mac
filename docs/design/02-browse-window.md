# 02 — Browse window

**Comp:** `Mac Browse Window.dc.html`
**Swift:** `Browse/SidebarView.swift`, `Browse/ItemGridView.swift`, `Browse/LibraryWindowView.swift`, `GridDisplaySettings.swift`

The window is functionally complete already — `NavigationSplitView`, sources with folder
trees, collapsible categories with narrowing fields, `cycleTag`, status flags, offline
badges, player in the detail column. This is a design pass, not a build.

## 1 · Tokens

Apply `handoff/design-tokens.md`. Sidebar `#17130E` against content `#131009` separates the
two without a rule. Every count in JetBrains Mono; a zero count dims rather than
disappearing — "exists but unused for this kind" is the information (#96).

## 2 · The three-way filter needs a vocabulary

`cycleTag` exists; the slots have no visual language. Give them one:

| Slot | Mark | Colour | Row treatment |
|---|---|---|---|
| Required | `+` | `#6FB86F` | tinted row background at 8% |
| Optional | `~` | `#6B96D6` | same |
| Excluded | `−` | `#D07A6A` | **name struck through** |

- Click cycles forward, **right-click steps back**. Both need to exist; a four-state cycle
  with no reverse is a guessing game.
- A collapsed category keeps an amber count badge — a filter cannot hide invisibly (already
  in the source; keep it).
- Every live slot appears as a **removable chip in a bar above the grid**, with a Clear all.
  The sidebar shows where a filter came from; the chip bar shows what is currently on.
- A **legend** at the foot of the sidebar. Three colours and three glyphs is more than a
  first-time user will infer.

## 3 · Missing is a filter value

Each category ends with an italic **`Missing — no <Category> tag`** row carrying its own
count, cycling the same three slots. Required on Venue is the untagged worklist; excluded is
"only fully tagged shows". It counts toward the collapsed-category badge and chips like any
tag. This is the tagging backlog made filterable rather than a separate screen.

## 4 · Media type is a filter, not a mode

Video / Audio / **Photo** as checkboxes in the sidebar, several selectable, the last one not
unselectable. Replaces the toolbar's one-at-a-time picker.

**The guard moves into the query, it does not go away.** One `kindOK`-style gate that every
listing path goes through. `ARCHITECTURE.md`'s hard-filter rule exists because forgetting it
leaked rows; relaxing one-kind-at-a-time is fine, losing the guard is not.

## 5 · Offline, honestly — and the trap

Cached thumbnails mean an offline source's tiles look **completely normal**. Only the play
action fails. So:

- Tile: small `◍` badge and slight desaturation, **not** a blocking overlay. The thumbnail is
  real and current; pretending otherwise is worse.
- A banner above the grid stating exactly what still works: *"N of these M items live on
  <Source> — tags, fields and thumbnails are local and current. Only playback and file
  operations are unavailable."*
- The banner's action is a **real toggle** — Hide offline items / Show offline items — which
  filters the listing and reports how many are hidden. Counting against the pre-toggle
  listing keeps the state recoverable.

## 6 · Selection and bulk

⌘-click or shift-click starts a selection; after that plain clicks extend it. Selected tiles
take an amber ring and a corner check. The bulk bar floats **over** the grid, bottom centre,
so the sidebar stays reachable: Add tags · Mark reviewed · Add to queue · Mark for deletion ·
Deselect · esc.

**Esc unwinds one layer:** an open popover first, then the selection. Never both.

## 7 · Tile shapes per kind, and vertical video

Each kind gets **one uniform frame** so the grid keeps its rhythm at 10,000 items — 16:9
video, 16:10 audio waveform, 3:2 photo. Anything narrower **pillarboxes** inside its frame
against near-black with a `⇕ 9:16` badge. A 9:16 tile at true aspect is 3.2× the height of a
landscape one; true aspect wrecks the grid.

View Options gains **Fit tiles to media aspect** for when you are actually reviewing phone
footage. Tiles top-align so the ragged edge stays tidy.

Audio tiles carry sample rate and channels where video carries resolution.

## 8 · Saved tile views — the largest addition

Eleven slots per tile: **nine overlaying** the thumbnail (four corners, top / middle /
bottom centre) plus a **dashed outer ring** — above, below, left, right — that sits beside it.

- One value registry: duration, resolution/sample rate, file size, filename, source, media
  type, aspect, favourite, offline, needs-review, playback-issue, marked-for-deletion, and
  tags either as all categories or one category at a time.
- A value that does not apply **renders nothing**, so ★ and ◍ cost no space on items that are
  neither.
- **Tags are pills wherever they appear** — fully rounded, category hue. Over the image the
  hue is layered on a scrim; outside, the tint alone carries it.
- Overlay badges get the scrim; outside badges drop it and read as plain text.
- Views are named, duplicated, deleted, and **cycled with `V`**.

**Per-value settings appear only on a value you have already ticked**, and only where they
apply — overflow (truncate/wrap), alignment, width (auto/fill/fixed). `★` has no caret.
Defaults come from the slot: corners truncate and align outward, the bottom strip wraps.

This is deliberately **not** a basic/advanced toggle. Splitting by presumed expertise hides
things people need; scoping by what they have already chosen does not. Nothing is labelled
"advanced".

Ship these views: **Default** (offline+aspect TL, ★ TR, format BL, duration BR, filename
below), **Triage** (flags TL, ★ TR, duration BR, filename + tags below), **Tagging**
(filename + Band/Venue/Year below), **Contact sheet** (source above, year in the left
gutter), **Clean** (duration only).

## Copy — verbatim

| Element | String |
|---|---|
| Filter slots legend | `Required — item must carry it` · `Optional — any one of these` · `Excluded — item must not carry it` |
| Legend footnote | `Click cycles through the slots. Right-click a tag to edit it.` |
| Missing row | `Missing — no <Category> tag` |
| Offline banner | `N of these M items live on <Sources> — tags, fields and thumbnails are local and current. Only playback and file operations are unavailable.` |
| Offline banner, hidden | `N items on <Sources> are hidden. Their tags, fields and thumbnails are local and still current.` |
| Empty, filtered | `Nothing matches this filter` / `Loosen a required slot, or clear the filter.` |
| Deselect | `Deselect · esc` |
