# 00 — What changed, and why

Written 29 August 2026, alongside specs 03–16. (Specs 01 and 02 were written in an earlier
session and are not covered here.)

A spec is not a transcription of its comp. Writing each one meant reading the existing Swift,
and the Swift kept changing the answer — sometimes because it already solved the problem,
sometimes because it made the comp's version impossible. This document records **every place a
spec departs from its comp, or asks the code to change**, in plain terms, so the reasoning is
recoverable months from now without re-deriving it.

Three kinds of entry:

- **Comp → spec** — the design in the browser comp says one thing, the spec says another.
- **Swift → spec** — something already in the code decided the design.
- **Added** — the spec asks for something neither the comp nor the code has.

## How to read a spec

Each one has the same five parts. *What changes* is the summary. **Decisions** is the expensive
part — the reasoning, numbered so you can cite it ("spec 07 §2"). *Model changes* is schema and
API work, usually needed before the view. *Layout* is measurements and structure. *Copy —
verbatim* is exact strings; anything marked *(existing)* is already in the code and must not be
reworded. *Keep from the existing view* is the list of things that look changeable but are not.

## Settled decisions

| Decision | Date | Where recorded |
|---|---|---|
| A library file is `<Name>.sqlite` — no custom extension. The comps show `.sasl`; ignore them. | 29 Aug 2026 | README "Decisions that apply everywhere", spec 11 §9 |
| Background tasks gets a `priority` column. Run next reorders the queue; it never interrupts a running job. | 29 Aug 2026 | Spec 06 §10 and its model table |

---

## 03 — Player

**Comp → spec: two keyboard maps became one setting.** The comp offers a `?` sheet comparing
the web map against the Mac map and lets you switch live. Supporting two live maps means two
behaviours to maintain forever. The spec ships a single `keyMap` enum consulted in the four
places the maps disagree, chosen once after migration, with the `?` sheet kept permanently as
the cheat sheet. Every hint in the window reads its labels from that one table.

**Comp → spec: the segments rail gained a third kind.** The comp lists songs and clips. Hide
blocks are the same shape on screen — a time range you marked — so they join the same rail, and
the hide-block menu currently in the transport bar goes away. But they are **not** the same
record: a song or clip is a child media item you can tag and browse (`createEmbeddedClip`
already writes exactly that), while a hide block is an instruction to an edit job and must
never appear in the grid.

**Comp → spec: the on-screen-text panel moved to the bottom.** The Swift has it as a second
right-hand panel, which is why there is code scaling two panels jointly against the video's
minimum size. The comp puts it under the transport, the lines read better wide than tall, and
the joint-scaling code deletes with it.

**Comp → spec: nothing from the info bar was deleted, only relocated.** The comp drops the tag
pills and the Save a Copy button. The spec moves each fact to where it already lives — position
to the footer, flags to the toolbar, tags to the tag panel, Save a Copy to the toolbar overflow
— and shrinks the settings to the two toggles that still have a home.

**Swift → spec: `l` and `m` are already bindable keys**, and the code deliberately lets a tag
binding beat loop and mute. Documented as correct rather than "fixed".

**Added: Esc unwinds exactly one layer.** The comp releases focus to the video; the Swift
closes the tag panel or leaves the player. The spec defines the whole stack in order, matching
the rule spec 02 sets for browse.

**Added: the numpad keeps working while you type.** The existing guard suspends single-key
shortcuts while a text field has focus, which is right — but seeking is the one thing you do
constantly *while* typing a tag name.

## 04 — Categories & Fields

**Comp → spec: the write-back field became a picker.** The comp has a free text input. There
are exactly thirteen standard keys; anything else silently becomes a custom field, so a typo
looks like it worked and writes `ARTSIT` into your files.

**Comp → spec: the behaviour list follows the agreed model changes.** "Display as checkboxes"
becomes a three-way choice (search / checkboxes / radio) and "Default focus" disappears —
focus is now the first visible category, which removes a setting and a whole class of conflict.

**Added: a colour on the category.** The design tokens fix a hue per category and three windows
draw it, but nothing stores one, so every surface is currently inventing it.

**Added: four vocabulary operations that do not exist** — merge tags, per-tag use counts,
alias-aware tag creation, bulk reorder. Worth knowing: the merge that *does* exist is for
duplicate media items, which is a different operation entirely.

## 05 — Import

**Comp → spec: probing became lazy.** The comp's file table shows duration and resolution per
candidate. Getting those means probing every file, which is most of what makes an import slow —
so Scan would cost as much as the import it exists to precede. Size comes free; the other two
fill in for the rows on screen and show `—` until then.

**Swift → spec: adding a source currently imports immediately**, and one job discovers, probes
and inserts in a single pass. Review is impossible without splitting that in two.

## 06 — Background tasks

**Swift → spec: the job names already exist.** The view maps all sixteen job kinds to human
names. The spec makes that the app's only source of job labels rather than restating them.

**Added: Run next reorders, never interrupts.** Priority pushes a queued job to the front of
its library's lane. The runner is serialized on purpose and a job mid-write finishes, so the
toast says what actually happens.

**Flagged, not solved:** job history has no retention policy. The `limit(30)` in the view is a
display cap, not a rule about what is kept.

## 07 — Review

**Swift → spec: the purge takes everything flagged**, not a list you pass it. So the delete
list's per-row ticks cannot be a view filter — unticking has to genuinely unstage the item, or
the confirmation count is a lie. The spec asks for a version that takes an explicit set, with
the flag check kept as the guard inside.

**Comp → spec: repair fixes became data.** The comp hard-codes a fix list per failure kind. As
a table — match, tool, command, estimate, risk — adding one is a settings change instead of a
release, and the Settings ▸ Repair pane has something to edit.

## 08 — Operations

**Swift → spec: OCR's settings are hard-coded in the job.** The comp exposes six knobs; only
two exist. The other five need somewhere to live.

**Added: a dry-run compatibility check for Join.** The refusal has to be visible before the job
is queued, not as a failed row in Background Tasks half an hour later.

**Added: cost estimates per operation.** Every "≈ 22.6 GB added to disk" figure in that window
needs a function behind it.

## 09 — Organise

**Swift → spec: move history has no session column.** The comp groups moves into runs with a
"Put all back" — grouping by template and timestamp works until two runs happen a minute apart.

**Flagged: the move log must be complete.** The `limit: 200` in the code is a display default;
if it ever became a storage cap, a large reorganise would contain moves that happened and
cannot be undone.

## 10 — Maintenance

**Added: a write-back dry run.** Write-back replaces a file's whole tag set, so the preview has
to show the value it is about to overwrite — and it cannot get that by running the job.

**Comp → spec: the recurring sweep time was questioned.** The comp shows `Today at 06:00`. Either
add a real schedule setting or drop the implication; do not display a time the app does not
keep.

## 11 — New library

**Comp → spec: `.sasl` → `.sqlite`.** See settled decisions.

**Comp → spec: do not build the folder picker.** The comp draws a Finder-style column browser
because a browser cannot open the real one. On the Mac it is one `NSOpenPanel` call.

**Swift → spec: the review step is far poorer than the plan behind it.** The plan model carries
thirteen fields per category plus tags, aliases and tag fields; the screen edits four. So today
you create a library and immediately go reconfigure it.

## 12 — Library properties

**Swift → spec: almost nothing changed.** This view already states its own principle — facts and
jump-offs, not a second editor — and already loads its aggregates off the main thread so it
cannot freeze on a big library. It gains a Configuration tab for the three things only a
library can own, and a shared column grid so a row with a button stops dragging the rows above
it out of line.

**Added: two rows with no data behind them** — operations logged, and last backup.

## 13 — Settings

**Comp → spec: category order cannot be an app-wide setting.** It is a list of category IDs, and
those are library-scoped, so a "global" order in the app's settings file would mean nothing
across libraries. It belongs in the library file, with a library picker, like the existing
Library Import pane.

**Swift → spec: Settings is a tab view, not a sidebar**, every pane already declares its scope,
and the window's resizing has a deliberate workaround behind it. Repair and Category Order join
as tabs; nothing is restructured.

**Added: this spec records the knock-on changes from earlier specs** — the info-bar toggles that
go, the key-map choice that arrives, the OCR settings that arrive — so they do not get orphaned.

**Note:** category order is the parked follow-up from `CLAUDE.md`. Specified only; not to be
built until you say tagging is finished.

## 14 — Tag analysis

**Swift → spec: the vocabulary is already decided.** The rule table exists with nothing to parse
it, but its header names the four matchers and six actions verbatim, plus the rename the
migrator applies. The spec uses those strings exactly rather than inventing names.

Everything else here is a build: the engine, the candidate queue, and a table for embedded
metadata pairs.

## 15 — Devices

Net-new, so nothing to depart from.

**Added: remote requests go through the same scoping functions as the local UI.** A role check
that only the network layer applies is a second implementation of the rule, and the second one
is the one that gets forgotten.

## 16 — Command palette

Net-new.

**Added: commands derive from the library's vocabulary.** "Filter by Band", "Add a Venue tag"
and so on are generated per category, so a new category gets its commands for free.

**Added: every command uses the name it already has** — from the grid's context menu, the window
titles, the browse filter rows. A palette that paraphrases becomes a second vocabulary for the
same actions.

---

## Judgement calls worth revisiting

None of these are wrong; they are places where a different answer would also have been
defensible, and where you may know something I do not.

1. **One keyboard map instead of two** (03 §3). If the muscle memory matters more than I
   assumed, the live switch is cheap to keep.
2. **Hide blocks in the segments rail** (03 §4). It puts an edit instruction next to two things
   that are media items. The alternative is leaving the transport-bar menu alone.
3. **On-screen text as a bottom drawer** (03 §5). Reasonable either way; the deciding factor was
   deleting the two-panel width negotiation.
4. **Retiring two info-bar settings** (03 §7). If you use the tag pills under the video, say so
   and they stay.
5. **Splitting scan from import** (05). It is the largest code change any of these specs asks
   for. The payoff is that adding a source stops being irreversible in practice.
6. **Repair recipes as data** (07 §4, 13a). More upfront work than a hard-coded list; it pays
   off the third time you want a new fix.
