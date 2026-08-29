# 01 — Library picker

**Comp:** `Mac Library Picker.dc.html` · **Swift:** `SightsAndSoundsApp.swift` — `LibraryListView` (~256), `LibraryRow` (~416)

## What changes

`LibraryListView` is currently the root `WindowGroup` — a window that stays open behind
everything. It becomes a **dialog** that appears at launch and from File ▸ Open Library…,
and dismisses the moment a library is chosen.

## Decisions

1. **It leaves when it is done.** A launcher that stays open accumulates features. Its one
   job is choosing a library; everything worth reading about a library lives in that
   library's own window under Properties.
2. **Two contexts, one dialog.** At launch there is nothing behind it, so the cancel button
   reads **Quit**. From the menu it appears over your work, cancel means cancel, and the
   window-placement control appears — because only then is there a window to replace.
3. **A new window by default.** Opening a library never disturbs what you are looking at,
   which is also how a document-based Mac app behaves. "This window" is available and names
   the library it will close.
4. **Already-open libraries offer Bring Forward**, not a second window. The `OPEN` badge is
   wired to behaviour, and the dialog does not land its default selection on it.
5. **Removing is forgetting.** The registry stores where a file is, not the library. The
   confirm shows the file being left behind and uses a neutral button, because nothing is
   destroyed.
6. **The summary is cached, not computed.** See the model change below.

## Model change

`LibraryRef` holds `{id, name, filePath, lastOpenedAt}` and nothing else. Rendering counts,
sizes and source status per row means opening every library and stat-ing every source root
at launch — including unplugged drives, the slow case — which is exactly what
`LibraryPropertiesView`'s "must never beachball on a big library" comment avoids.

**Add a cached summary written when a library closes:** item count, total bytes, source
count, category count, tag count. Rows read the cache. Anything that can change while a
library is shut — whether its sources are reachable — is shown **only for a library that is
currently open**, whose handle is already live.

## Layout

Panel, 620pt wide, centred. Title, then the list, then (menu context only) the placement
band, then the button row.

Rows: 34pt icon · name + `OPEN` badge + offline badge · cached summary line (mono) · path
(mono, dim) · last-opened right-aligned. Double-click opens.

The placement band is a **raised** strip (`#231E17`), not a thin divider row — it was too
easy to miss inline. Bold "Open in" label, segmented control with the active option in
amber, and the consequence on its own line with a status dot: green for a new window,
amber for reusing this one.

## Copy — verbatim

| Element | String |
|---|---|
| Title, launch | `Sights and Sounds` |
| Title, menu | `Open Library` |
| Blurb, launch | `Pick a library to open. Each one is a separate file with its own vocabulary, sources and media.` |
| Blurb, menu | `Pick a library to open. Everything already open stays as it is.` |
| Cancel, launch | `Quit` |
| Cancel, menu | `Cancel` |
| Primary | `Open <Name>` / `Bring Forward` |
| Placement | `Open in` · `A new window` · `This window` |
| Placement note, new | `Concerts stays open. Two libraries side by side, each window keeping its own filter and queue.` |
| Placement note, this | `Concerts closes and its window is reused. Nothing is lost, but you will have to reopen it.` |
| Cache note | `Counts are as of each library's last close. Whether a drive is plugged in is only known for a library that is open.` |
| Empty title | `No Libraries` *(existing)* |
| Empty body | `Create your first library to get started.` *(existing)* |
| Secondary actions | `New Library…` · `Add Existing…` · `Create Demo Library…` *(all existing)* |

## Keep from the existing view

`LibraryRow`'s context menu is right and stays: **Properties… · Back Up Now · Restore from
Backup… · Remove from List…**. Its removal dialog copy is right and stays verbatim,
including the clause about closing the library's windows first. Do not introduce a second
label for Properties.
