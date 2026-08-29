# 08 — Operations

**Comp:** `Mac Operations.dc.html`
**Swift:** `Browse/ItemGridView.swift` (context menu ~148–220), `Operations/EncodeJob.swift`,
`RemuxJob.swift`, `JoinJob.swift`, `ClipExportJob.swift`, `BlockRemovalJob.swift`,
`OcrJob.swift`

## What changes

Every operation already exists as a job with a name, and `ItemGridView`'s context menu already
names them all — **use those strings verbatim, do not invent a second set.** What is missing
is the step between choosing one and it running: nothing says what will be written, how big
it will be, how long it will take, or what the operation is about to do to the original.

The context menu keeps working for the one-item case. Picking an operation against a
**selection** opens this window: operation list, the selection as an editable input/output
list, the cost, the guarantees, and the actual command.

## Decisions

1. **Say what it costs before it runs.** Files written, bytes added, time taken — for the
   current selection, recomputed as the selection changes. This is shared decision §3, and
   this window is where it is most load-bearing: `≈ 22.6 GB added to disk` is the number that
   changes someone's mind.

2. **The selection is the list.** The rows *are* the operation's input, each with a checkbox
   and its predicted output beside it. Unticking recomputes every number. Nothing hardcodes
   its own count, and there is no second selection model to get out of sync with Browse.

3. **Unavailable, not hidden** (shared decision §2). Join needs two items; with one selected
   it stays in the list, greyed, with `needs at least 2 items selected` **where its
   description goes**, and the footer says the same thing where the summary was. Hiding it
   teaches nothing about why it is missing.

4. **Stream copy versus re-encode belongs on the operation list, not in a paragraph.** Four of
   these copy streams untouched, OCR writes no file at all, and only Encode loses a
   generation. That distinction decides how freely each can be used, so it is a chip on the
   row: `stream copy` green, `re-encode` amber, `reads only` blue.

5. **Additive without exception, stated as guarantees.** Every operation writes beside the
   original: encode leaves the source, join leaves the parts, clip export marks the clip
   exported rather than deleting it, block removal writes an edited copy. Because nothing is
   modified in place there is no undo to design — say that in three specific bullets per
   operation rather than a general reassurance.

6. **Show the command.** `ffmpeg -i {in} -c copy -movflags +faststart {out}` tells someone who
   knows ffmpeg more than three paragraphs can, and tells someone who does not that this is a
   plain, inspectable thing. It is also the string a repair recipe would carry (spec 07 §4).

7. **A refusal is better than a bad file.** `JoinJob` concat-demuxes and refuses when codecs,
   dimensions or sample rates differ — **with ffmpeg's own error**, not a guess. Surface that
   refusal in the panel *before* running, with the mismatch listed and the fix named (encode
   the odd part first, then join). Nothing is written.

8. **Join's order is explicit.** From a selection, parts are dragged into the order they will
   play in. From a folder, it is name order and says so — `JoinJob` sorts by name, and the
   remedy for a wrong order is renaming the files. Two modes because they answer different
   questions; one silent ordering rule would be wrong for both.

9. **OCR's settings deserve to be visible exactly once — here.** Everywhere else in the app
   you see OCR *results*. This is where they are produced, and the defaults are a guess:
   sample interval, recognition level, minimum text height, region of interest, language
   correction, and repeat collapsing. Every one of them maps to a `VNRecognizeTextRequest`
   property or the sampling loop.

   **Show the cost as it changes.** Half-second sampling across four concerts is ~34,000
   frames; that is worth knowing before starting rather than after. The frame count and the
   estimate derive from the ticked items, like every other operation's costs.

10. **Block removal draws what it keeps.** One timeline, hidden ranges hatched, kept material
    green, with removed duration and output size read from the same ranges that drew it — so
    the picture and the numbers cannot drift. The player already skips these live, so what
    you have been watching is what the edit keeps; say that.

## Model changes

| Change | Why | Where |
|---|---|---|
| `OcrSettings`: `recognitionLevel`, `minimumTextHeight`, `regionOfInterest`, `usesLanguageCorrection`, `collapseRepeats` (interval and budget already exist) | The job hard-codes `.accurate` and `usesLanguageCorrection = false`; the comp exposes six knobs and five have nowhere to live. Per run, defaulted from settings. | `Settings/AppSettings`, `Operations/OcrJob` |
| Predicted output size / duration per operation | Every cost figure in this window. An estimate function per job kind — bitrate × duration for encode, source size for remux, kept-range share for block removal. | `Operations/*` |
| `JoinJob` dry-run compatibility check | The refusal must be visible before the job is queued, not as a failed row in Background Tasks. | `Operations/JoinJob` |
| Explicit part order on the join payload | Name order stays the folder default; a selection carries its own order. | `Operations/JoinJob` |
| Batch enqueue: one operation, N items, one queue | The window acts on a selection; the runner still executes one at a time. | `Jobs/JobRunner` |

## Layout

Window `1280 × 868`, three columns.

**Operation list 250 pt** (`#17130E`): name, what it produces, and the kind chip. Unavailable
rows at 50% with the requirement in place of the description. A pinned foot note: each runs as
a background job on this library's queue, one at a time.

**Centre**: title and blurb, then per-operation controls (preset / mode segmented, join source
+ order list, OCR's six controls beside a region diagram and a live estimate card, block
timeline), then the input → output list — `26 / minmax(0,1fr) / 26 / minmax(0,1fr)`, source in
mono grey, arrow, predicted output in green (or `#C9857A` when refused), excluded rows at 45%.
A refusal block sits below on `#251512` with a `#4A2A24` border.

**Inspector 296 pt**: `WHAT THIS COSTS` (mono figures, right-aligned to a common column),
`GUARANTEES` (green dots), `COMMAND` (mono on `#0F0C07`).

Footer 62 pt: the summary sentence, then the primary button naming its count — inert and
neutral when the selection cannot satisfy the operation.

## Copy — verbatim

Operation names come from the grid's context menu and must match it exactly: `Optimize
(Faststart)` · `Repair Container` · `Encode a Copy` · `Export Clip to File` ·
`Export Copy Without Hidden Blocks` · `Scan On-Screen Text (OCR)` · `Join Folder's Files` ·
`Write Tags to File` · `Restore Embedded Tags`.

| Element | String |
|---|---|
| Kind chips | `stream copy` · `re-encode` · `reads only` |
| Unavailable | `needs at least <n> items selected` · `unavailable` |
| Encode blurb | `Re-encode into a fresh file beside the original. The original is not touched, not replaced, and not deleted — this only ever adds.` |
| Encode guarantee | `Re-encoding loses a generation of quality — the only operation here that does.` |
| Remux blurb | `Rewrite the container without touching a single frame. Optimize moves the index to the front so a file starts playing instantly; Repair rebuilds a container that will not open.` |
| Remux guarantee | `Byte-identical streams — no quality change is possible.` |
| Join blurb | `Concatenate several files into one. Stream copy, so it is exact and fast — and it refuses outright when the parts do not actually match.` |
| Join order note | `Drag to reorder — this is the order they will play in.` / `Name order. Rename the files if you need a different one.` |
| Join refusal | `ffmpeg refuses this join` / `Concatenating without re-encoding requires identical codecs, dimensions and sample rates. Transcode the odd one out first — Encode a Copy will do it — then join the results.` |
| Clip blurb | `Turn an embedded clip into a standalone file. Stream-copied, never re-encoded — and the clip is not deleted from its parent.` |
| Clip guarantee | `The clip row is kept, marked exported, not deleted.` |
| Blocks blurb | `Cut the hidden ranges out into an edited copy. The player already skips these live, so what you have been hearing is what the edit keeps.` |
| Blocks legend | `kept · <duration>` · `removed · <duration>` |
| OCR blurb | `Read the text visible in each frame with Vision and store it against the item. The only operation here that writes no file — it adds searchable text and nothing else.` |
| OCR guarantees | `Vision runs locally; nothing leaves the machine.` · `The media file is opened read-only and never written.` · `Rescanning replaces the previous result for that item, so tightening a setting and running again is safe.` |
| OCR control labels | `SAMPLE EVERY` · `RECOGNITION` · `SMALLEST TEXT` · `REGION` · `CORRECTION` · `REPEATS` |
| OCR control notes | `How often a frame is read. Text on screen for less than this can be missed entirely.` · `As a share of frame height. Lower catches captions and credits; it also catches noise.` · `Restrict where text is looked for. A stage banner lives up top; a caption lives at the bottom.` · `Vision guesses at plausible misreads. Off is literal — better when the text is a band name it will not know.` · `The same banner across 200 frames is 200 identical lines unless they are collapsed.` |
| Cost labels | `files written` · `added to disk` · `of encoding` / `of copying` · `frames read` · `of scanning` |
| Queued | `Queued on this library — follow it in Background Tasks` |

## Keep from the existing view

The context menu's structure — file-location actions above media operations, a divider between
them, everything `.disabled(!model.isOnline(item))` — and its **exact** labels. Embedded clips
resolving to the parent's file for Show in Finder and export. `Export Clip to File` appearing
only for a clip that is not already exported. `Optimize`/`Repair`/`Encode`/`Join` hidden for
child items entirely (`parentMediaItemID == nil`), because a clip is a range, not a file.
`Export Copy Without Hidden Blocks` appearing only when `hasHideBlocks`. `RemuxJob`'s
archive-before-write discipline and its `_Replaced/<path>` original, named in the summary.
`EncodeJob.Preset.displayName` — `H.264 (compatible)` / `HEVC (smaller)` — as the preset
labels.
