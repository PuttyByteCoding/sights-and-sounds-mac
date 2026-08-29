# 03 — Player

**Comp:** `Mac Player Window.dc.html`
**Swift:** `Player/PlayerView.swift` (`PlayerContent` ~270, `InfoBar` ~380, `TransportBar` ~560,
`ScrubberView` ~700, `QueuePanel` ~960), `Player/TagPanelView.swift`,
`Player/OcrLinesPanel.swift`, `Player/KeyBindingsEditor.swift`,
`Playback/PlayerKeyMap.swift`, `Tagging/TagKeyBinding.swift`

The player is the deepest view in the app already: fitted video with a 2× upscale cap and an
anchor setting, panel widths clamped against a 150 pt video floor, waveform scrubber with
bucketed hover previews, hide blocks, clip authoring, queue cells that read `GridSettings`,
the ported key map, and per-library key bindings. Four things change — the focus model, the
segments rail, where on-screen text lives, and which keyboard map ships. Everything else is
tokens.

## Decisions

1. **Esc is the whole focus model.** Today focus is reclaimed by a tap gesture plus an
   `onChange` watcher on `showTagPanel`, and Esc means "close the tag panel, else leave the
   player". Make the stack explicit and unwind **exactly one layer** per press (the rule
   `02` §6 sets for browse): open sheet or popover → pending mark → focus back to the video
   → leave the player. Tab / ⇧Tab walks **video → tags → segments → queue**, skipping
   collapsed panels. The focused zone carries a 1 pt amber inset ring and is named in the
   footer, so "where do my keys go" is always answerable without pressing anything.

2. **Keep the first-responder guard; extend it for the numpad.** `NSApp.keyWindow?.firstResponder
   is NSTextView` is what makes bare single-key shortcuts safe — while a field owns the
   keyboard, `d` spells a tag name. F-keys already pass through it. Add the numpad: seeking
   is the one thing done constantly *while* typing, and `event.location`/`Numpad*` codes
   separate it cleanly from the top row that is spelling the tag.

3. **One key map, chosen once — not two maps forever.** The two maps agree on everything but
   four rows. Ship a single `keyMap: .mac | .web` setting consulted in exactly those four
   places, offered once after migration and thereafter reachable from `?`. The `?` sheet is
   both the chooser and the permanent cheat sheet, and every hint in the window (transport
   tooltips, footer, empty segment state) reads its labels from the same table — a second
   copy of "the mark key is `[`" is how these drift.

   | Row | Web map | Mac map (ships today) |
   |---|---|---|
   | Previous / next item | `⇧←` `⇧→` | `←` `→` |
   | Open / close a segment | `[` `]` | `⌃{` `⌃}` |
   | Triage keep / issue / delete | `R` `W` `D` | bound letters + advance |
   | Everything else | identical | identical |

   Do not make it per-library or per-window. It is muscle memory, so it is one app setting.

4. **Segments are one rail with three kinds, and two storage homes.** Songs, clips and hide
   blocks all read as time ranges on the scrubber, so they get one list — but they are not
   one record, and pretending otherwise would put an edit instruction in the grid:

   - **Song and clip are the same thing already**: `createEmbeddedClip` writes a child
     `MediaItem` with `parentMediaItemID`, `clipStartSeconds/EndSeconds`, `isClip`. A named
     range that can be tagged and browsed. The only difference is the label, so store it as
     a role on that row rather than inventing a table.
   - **A hide block is not an item.** It is a `VideoBlock(kind: .hide)` — a skip during
     playback and an instruction to `BlockRemovalJob`. It appears on the scrubber and in the
     rail, and never in the grid.

   Scrubber lanes: songs above the waveform, clips below, hide blocks shaded across it (the
   existing red 18% fill). Selecting a rail row highlights its bar and vice versa. This
   **removes the hide-blocks `Menu` from the transport bar** — the rail is now the one place
   blocks are listed, and per §5 of the shared decisions nothing is destroyed by a removal
   that stages an edited copy.

5. **On-screen text is a bottom drawer, not a third side panel.** `OcrLinesPanel` currently
   competes with the tag panel for width, which is why `rightPanelWidths` has to scale two
   panels jointly against the video floor. The lines are short, timestamped rows — they read
   better wide than tall. Move them under the transport, resized by the same
   `HorizontalResizeHandle` the queue uses. The right side becomes one rail (tags over
   segments), the bottom two stacked drawers (text, queue), and the joint-scaling path goes
   away with it.

6. **The player acts on the playing item only.** An OCR line can be copied, turned into a tag
   applied to this item, or added as an alias of an existing tag. Anything plural — "every
   item whose text says this" — is a link into Tag Analysis, never an action here. That one
   rule is what stops OCR from becoming two implementations of one feature in two windows.

7. **The info strip's contents move to where each fact already lives.** `InfoBar` renders
   position, tag pills, the favourite star and Save a Copy between the video and the
   transport. Position → the footer. Favourite and the three flags → toolbar toggles (they
   are already mirrored there by `FlagButtons`; one name, one place). Tag pills → the tag
   panel, which shows the same taggings with their category hue. Save a Copy → the toolbar's
   overflow, still disabled when `fileURL` is nil. `InfoBarSettings` shrinks to the two
   toggles that still have a home: `showsPosition`, `showsDownload`.

8. **Triage is a mode, and it is the only place a flag advances.** Outside it, `F/R/W/D`
   toggle and stay put. Inside it, R (keep) / W (won't play) / D (delete) mark the current
   item and advance, and the toolbar shows a running count of what the pass has done. A
   bound tag key with `advance` behaves the same way and needs no mode — the mode exists to
   make the *fixed* flag keys advance without changing what they mean elsewhere.

## Model and settings changes

| Change | Why | Where |
|---|---|---|
| `segmentRole: enum { song, clip }` on the child item | A song and a clip are both named ranges; only the label differs. | `Models/MediaItem` |
| `name` is optional at close | `createEmbeddedClip` requires a name; the rail needs to accept "New song" and let it be renamed in place. Blocking the close on a text field loses the range. | `Operations/ClipService` |
| `keyMap: .mac \| .web` | Four rows, one enum, read by the dispatcher and by every hint. | `Settings/AppSettings` |
| `InfoBarSettings` drops `showsTags`, `showsFavorite` | Both facts now have a permanent home elsewhere. | `Settings/AppSettings` |
| Numpad passes the typing guard | Seeking mid-word is the whole point of the numpad. | `PlayerView.handle(_:)` |

## Layout

Window content splits into a left column and a 352 pt right rail; a 30 pt footer spans both.

Left column, top to bottom: video stage on `#0A0806` (fitted, anchored, unchanged) ·
transport block on `#17130E` — 44 pt scrubber with the segment lanes, then one control row
(transport buttons, mono time, mark in/out, loop/mute) · on-screen-text drawer, 112 pt,
collapsed by default · queue drawer, 146 pt.

Right rail: tags (flex 1.35) over segments (flex 1), divided by a 1 pt rule, each with a
10 px section label and a Tab badge that lights amber when the zone holds focus.

Floors, all existing and all kept: video 150×150, tag panel 220, text panel 240, queue = one
whole cell (`QueueCell.metadataHeight` + 42). The rail's floor is now the tag floor; the two
panes inside it share the height and never resolve against each other.

Segment rows: mono `SONG`/`CLIP`/`HIDE` chip in the kind's hue (song `#6FBFB0`, clip
`#C58BB8`, hide `#D07A6A`), name, mono range + duration, play, remove. Selected row takes
`#241E16` with `inset 2px 0 0 #E9A23B`.

## Copy — verbatim

| Element | String |
|---|---|
| Marking indicator | `marking from <time> — <close key> to close` |
| No segments | `No songs or clips yet. Press <open key> to open a segment, <close key> to close it.` |
| Segment counts | `<n> songs · <n> clips` |
| Key map sheet title | `Keyboard map` |
| Key map sheet blurb | `Two maps disagree on four rows. Pick one — the hints throughout the window follow it.` |
| Key map footnote | `Rows that differ are highlighted. Everything else is identical in both maps.` |
| Focus footer, video | `<open> <close> segment · <triage> triage · numpad seek · Tab moves focus` |
| Focus footer, panels | `Esc releases to video · numpad seek still works · Tab moves focus` |
| OCR drawer subtitle | `Vision OCR · click a line to seek` |
| OCR → tag sheet | `Creates the tag in the chosen category and applies it to this item only. The category's formatting rule normalizes the name.` |
| OCR → alias sheet | `The line becomes an alternative name for the tag you pick, so future searches and imports resolve it.` |
| OCR, plural action | `Find across the library →` |
| Bindings blurb | `A bound key toggles its tag on the playing item. Only keys the fixed map leaves free are offered.` |
| Empty vocabulary | `No tag categories in this library yet — create them from the browse toolbar's Categories button.` *(existing)* |
| OCR empty | `No scanned text for this item yet.` / `Scan queued — reopen this panel when it finishes.` *(existing)* |
| Hide-block help | `Hide blocks: { opens at the playhead, } closes. They skip during playback; export an edited copy from the browse grid.` *(existing)* |

## Keep from the existing view

The fitted-video math and its 2× upscale cap in points, and `VideoAnchor` placement. The
paused-frame Live Text overlay with `onEmptyClick` resuming — text clicks belong to the
selection. Bucketed scrub previews and the clamped hover overlay. Waveform peaks from
`WaveformProvider`. Queue cells reading `GridSettings` so the queue and the grid never
disagree about what a tile says. Drag handles tracking in **global** coordinates (local
translation oscillates against a moving origin). `KeyBindingsEditor`'s filtering to
`TagKeyBinding.bindableKeys` and its `advances` label — note that `l` and `m` are bindable
and a binding on either **wins over** loop/mute, which is correct and already implemented.
`ClipError.nestedClip`: clips are authored on the parent, never inside a clip.
