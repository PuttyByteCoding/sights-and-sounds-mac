# 14 — Tag analysis

**Comp:** `Mac Tag Analysis Window.dc.html`
**Swift:** `Models/AnalysisRule.swift`, `Database/LibraryDatabase.swift` (`analysisRule` table
~360), `Operations/OcrJob.swift` (`OcrTextLine`), `Writeback/TagWriters.swift` (`readTags`)

## What changes

Only the storage exists: an `analysisRule` table and a model carrying `sortOrder`, one
`matchJSON` matcher and an ordered `actionsJSON` array. Its header names the wire vocabulary
verbatim and says the engine ports in Phase 4 — **matchers** `keyEquals · valueStartsWith ·
numericRange · pathRootStartsWith`, **actions** `ignore · setKind · stripPrefix · onlyIfTrue ·
assignCategory · hidePrefix`. It also records that the migrator translates the old
`assignGroup` to `assignCategory` on the way in.

Everything else is net-new: the engine, the candidate queue, and this window. Use those
strings exactly — they are the ported vocabulary, not a naming opportunity.

## Decisions

1. **Three sources, one queue.** Embedded metadata keys, on-screen text and path fragments all
   arrive as the same shape: a string appearing in N items with no tag behind it. Treating them
   as one kind of candidate means one triage surface and one rule engine, rather than three
   half-features that each learn nothing from the others.

2. **This is the plural half of OCR, and that is the boundary.** The player can copy a line,
   make a tag from it, or add it as an alias — for the item playing (spec 03 §6). Everything
   that touches *other* items happens here. That single rule keeps the same feature from being
   implemented twice in two windows.

3. **A suggestion is a suggestion.** Each candidate carries a proposed decision —
   `assignCategory` to a named category, `alias` of an existing tag, `ignore`, `setKind` — and
   the operator accepts, redirects or rejects it. Bulk actions apply the *suggested* decision
   across a selection, so accepting 40 obvious ones is one click and the ambiguous ones stay
   for a human.

4. **Deciding the same thing twice is a rule waiting to be written.** "Make a rule from this"
   carries the candidate's key and value straight into the matcher, and if a rule already
   covers it, it opens that rule instead of adding a rival. That is the entire path from
   one-off triage to automation, and it must not require retyping the string.

5. **Order is the engine.** Rules run top to bottom and actions fold in list order — both
   documented as significant in `AnalysisRule`'s header — so both are reorderable and
   **numbered on screen**. An unordered list would misrepresent what the engine does.

6. **A rule reports before it writes.** A dry run states matches — pairs and items — and
   nothing is written until Apply. A rule with no actions says `no actions yet` rather than
   looking finished.

7. **`setKind` takes a kind, never a metadata key.** The action's argument comes from a small
   closed vocabulary (`filename`, `md5`, …); the candidate carries the intended kind. Free text
   there is how `OriginalMD5` ends up as a kind name.

8. **Frames, not a second player.** The evidence strip shows each matching item as a still, and
   for on-screen text the frame **at the moment the string was read** — `OcrTextLine.timeSeconds`
   is already stored per line. That answers the bulk question ("is this really a band name?")
   without opening ten items, and it is the only reason a still is worth showing.

9. **Applying a rule is revertible through the existing log.** Category assignment is a
   database write; anything that reaches a file goes through write-back and its run history
   (spec 10 §4). Do not invent a third audit trail.

## Model changes

This is a build, not a redesign. The pieces:

| Change | Why | Where |
|---|---|---|
| `EmbeddedMetadataPair` — item, key, value, kind | The candidate queue's largest source. `TagWriters.readTags` already produces the ffprobe dictionaries; this persists them so they can be grouped and counted. | new table |
| Candidate query: group by (source, key, value) with an item count, excluding anything already tagged, aliased or ruled | The queue itself. Derived, not stored — a decision changes the underlying data, so the queue recomputes. | new `Domain/TagAnalysis` |
| Rule engine: typed matcher and action enums encoding/decoding the JSON vocabulary above | `matchJSON`/`actionsJSON` are strings today with nothing to parse them. | new `Domain/TagAnalysis` |
| Dry run returning matched pairs and affected items per rule | §6. | `Domain/TagAnalysis` |
| Candidate decisions recorded (ignored / accepted) | An ignored candidate must not return next sweep. | new table |

## Layout

Window `1520` wide. Mode tabs **Candidates · Rules** with a mono headline.

**Candidates.** Left rail (draggable, 212–470 pt): source filter (all / metadata / on-screen /
file), status filter, search, then candidate rows — source chip, the string, mono item count,
suggestion chip, and a ✓ when a rule already covers it. Selecting one fills the centre: the
string large, where it came from, the suggested decision with a category picker beside it, and
**Make a rule from this**. Below, the evidence strip — one still per matching item, OCR stills
seeking to the read timestamp, with a peek on hover. A bulk bar appears with a selection:
`<n> picked · <n> items affected`, then Apply suggestions · Ignore · Make a rule.

**Rules.** A note that both orders matter, then rule cards: order number, matcher chip in blue
`#8FA6D6`, arrow, action chips in green `#8FCF8F` (or the amber `no actions yet`), the dry-run
line, and up/down/remove. The selected rule opens an editor: matcher radio list with a
one-line explanation each, the argument field with a matcher-specific placeholder,
**ACTIONS, IN ORDER** (numbered, reorderable, removable) with dashed chips to add from the
closed action vocabulary, then the dry-run sentence and Apply.

## Copy — verbatim

| Element | String |
|---|---|
| Modes | `Candidates` · `Rules` |
| Rule order note | `Rules run top to bottom, and actions fold in list order — both orders are significant.` |
| Actions heading | `ACTIONS, IN ORDER` / `folds top to bottom` |
| No actions | `no actions yet` |
| Dry run, with actions | `Matches <n> metadata pairs across <n> items. <n> actions fold in order; nothing is written until you apply.` |
| Dry run, empty | `Add at least one action to see what this rule would do.` |
| New rule from candidate | `New rule from "<value>" — review the actions before applying` / `New rule from "<value>" — add an action to make it do something` |
| Already covered | `Already covered by a rule — showing it` |
| Applied | `Rule applied · <n> items updated, revertible from the write-back log` |
| Bulk bar | `<n> picked · <n> items affected` · `Apply suggestions` · `Ignore` · `Make a rule` |
| Matcher explanations | `the metadata key is exactly this` · `the value begins with this string` · `the value falls in this numeric range` · `the item's path starts with this folder` |
| Matcher names | `keyEquals` · `valueStartsWith` · `numericRange` · `pathRootStartsWith` *(existing — `AnalysisRule` header)* |
| Action names | `ignore` · `setKind` · `stripPrefix` · `onlyIfTrue` · `assignCategory` · `hidePrefix` *(existing — `AnalysisRule` header)* |

## Keep from the existing model

The wire vocabulary, spelled exactly as `AnalysisRule`'s header lists it — it is what the old
engine used and what the migrator writes. `sortOrder` across rules and action order inside
`actionsJSON` both being significant, and the engine folding actions in list order. The
`assignGroup → assignCategory` translation happening in the migrator, never at read time. And
the reason analysis rules migrate at all while hashes and fingerprints do not: they are
**authored, not derived** (spec 11 §8).
