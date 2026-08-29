# Design tokens — Sights and Sounds (macOS)

App-owned appearance. Warm charcoal, not system materials. macOS window chrome and
controls; warm charcoal content. Decided Aug 2026.

## Surfaces

| Token | Hex | Use |
|---|---|---|
| Page | `#0B0A08` | Behind everything |
| Window content | `#131009` | Main content area |
| Sidebar | `#17130E` | Left rails — differs from content so the split needs no rule |
| Raised / card | `#151209` | Cards, list rows, panels |
| Selected row | `#2A2118` | With `inset 2px 0 0 #E9A23B` |
| Toolbar / chrome | `#1A1610` | Toolbars, footers |
| Title bar | `#1C1814` | Window title bar |
| Well / input | `#0F0C07` | Text fields, progress tracks |
| Border | `#2A251E` | Standard |
| Border, raised | `#3A3328` | Dialogs, popovers |
| Border, active | `#4A3C24` / `#7A6428` | Selected card / focused control |

## Text

| Token | Hex | Contrast on `#131009` | Use |
|---|---|---|---|
| Primary | `#F2EDE4` | 15.2:1 | Body, values |
| Secondary | `#CFC6B8` | 10.4:1 | Row text |
| Tertiary | `#A79E90` | 6.9:1 | Descriptions |
| Quaternary | `#8C8478` | 5.0:1 | **Floor for text at 10–12px** |
| Disabled only | `#6E6659` | 3.4:1 | Non-informational only |

**Rule learned the hard way:** `#7C7466` and `#5E5749` fail AA below 12px. They were
shipped on load-bearing data three separate times — a file path, an encode's predicted
output size, and the prior embedded value a write-back was about to overwrite. Anything
a decision depends on is `#8C8478` or lighter.

## Accent and status

| Token | Hex | Meaning |
|---|---|---|
| Amber | `#E9A23B` | Primary action, selection, focus, running |
| Green | `#6FB86F` / `#8FCF8F` | Required, succeeded, online, kept |
| Blue | `#6B96D6` / `#8FA6D6` | Optional, informational |
| Red | `#D07A6A` / `#D9A090` | Excluded, failed, destructive |
| Orange | `#D9924A` / `#C9884A` | Offline, warning, skipped |
| Mauve | `#C58BB8` | Duplicates |

Destructive confirm button: `#8A3428` on `#FFEDE8`. Neutral-but-irreversible (removing a
library from the registry): `#2A241C` — **not** red, because nothing is destroyed.

## Tag category hues

Fixed per category, used for pills, swatches and filter chips everywhere.

Band `#8B93E8` · Recording Type `#C58BB8` · Venue `#6FBFB0` · Year `#E9A23B` · Taper `#9DBF7F`

## Type

- UI: **Archivo** — 17px window heading, 13px row, 12.5px body, 11.5px secondary, 10px section label (700, 0.13em tracking, uppercase)
- Mono: **JetBrains Mono** — every filename, path, count, duration, size, timestamp, job kind, command, fingerprint

Never set a count or a filename in the UI face. Mono is what makes a column of numbers
scannable and a path identifiable.

## Geometry

- Radius: 4px chip · 6px control · 7px button · 9px card · 11px window · 999px pill
- Row padding: 9–10px vertical, 13–16px horizontal
- Section gap: 15–16px. Card gap: 7–10px
- Segmented control: 2px padding container, 5–6px radius children

## Layout rules that took iterations to get right

1. **Shared column grids must actually be shared.** A header outside a scroller and rows
   inside it have different available widths. Use `scrollbar-gutter: stable` on both, or
   put the header inside as a sticky row. Rows with an optional trailing button need a
   fixed column for it, or that button drags every column left on that row alone.
2. **`box-sizing: border-box`** on anything with `height: 100%` and padding.
3. **Never `direction: rtl`** to truncate a path from the left — the leading `/` is a bidi
   neutral and reorders to the end. Truncate the middle in the string: keep the volume and
   the filename, elide the centre. Matches `.truncationMode(.middle)` in the source.
4. **Progress derived from a clock, and the clock accounts for pauses.** Three separate
   timer bugs this session: a tick that died on remount, a pause that rewound to the seed,
   and a modal stranded by a cleared interval. Store `startedAt` + `total`, bank paused
   spans per lane, derive the value.
5. **One name, one place.** Five separate instances of the same fact rendered two ways in
   one view. Store a label once and read it everywhere.
