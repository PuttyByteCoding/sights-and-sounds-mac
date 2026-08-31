# 14 — Tag analysis: the build plan

Spec 14 describes the window. This says how it gets built, in what order, and
records the **ported semantics** so nobody has to re-derive them.

Written 30 August 2026 after reading the old app — `PuttyByteCoding/SightsAndSounds`
— at `src/VideoOrganizer.Domain/TagAnalysis/` and, decisively, its own design
specs at `docs/superpowers/specs/`.

## Why this document exists

Spec 14 insists on the wire vocabulary — `keyEquals · valueStartsWith ·
numericRange · pathRootStartsWith`, `ignore · setKind · stripPrefix ·
onlyIfTrue · assignCategory · hidePrefix` — and says "use those strings exactly;
they are the ported vocabulary, not a naming opportunity". It does **not** say
what any of them do.

Writing the engine from the names alone would mean inventing behaviour behind
ported vocabulary, which is the one thing the spec is emphatic about. The old
app has the answers. They are recorded here rather than left in a repository
this one does not depend on.

**The old app's own specs matter as much as its source.** Reading only the
`Rules/` directory produced a plan that had `hidePrefix` down as dead code and
the candidate pipeline down as flat. Both were wrong, and both were corrected by
`2026-08-12-tag-analysis-server-pipeline-design.md`.

## The engine, exactly

From `RuleEngine.cs`, `RuleTypes.cs`, `KeyNormalizer.cs` and the four matcher
evaluators — themselves a port of an older `analyzeRules.ts`.

### The fold

```
kind     = .tag
value    = input.value
category = nil
matched  = nil

for rule in rules (list order):
    if rule.matcher fires against (input.key, CURRENT value):
        for action in rule.actions (list order): apply it
```

Three properties, none obvious, all load-bearing:

1. **Matching re-checks the current value**, not the original — a rule that
   strips a prefix changes what later rules see, which is how rules compose.
2. **Last action wins** for `kind` and `category`. Overlapping rules do not
   conflict; the later one decides.
3. **Every rule is considered.** No first-match-wins short circuit.

### Actions

| Action | Effect |
|---|---|
| `ignore` | `kind = .ignored`, recording the rule that did it |
| `setKind(kind)` | Lenient parse. **An unrecognised kind is inert, not fatal** — stored as a free string so a new kind needs no migration |
| `stripPrefix(prefix)` | Ordinal prefix test; drops it. No-op when absent |
| `onlyIfTrue` | Trimmed, compared case-insensitively to `"true"`; anything else sets `kind = .ignored` |
| `assignCategory(name)` | Sets the category. Wire name was `assignGroup`; the migrator translates inbound |
| `hidePrefix` | **Not part of the fold, and that is correct.** It is consumed by path parsing: strip the media root, then any `hidePrefix` match, then split into segments. It exists so a hidden root is an ordinary rule row rather than a separate synced setting — one editor, one storage, one backup path |

### Kinds

`tag · title · path · filename · md5 · flag · ignored`. `tag` is the default;
`ignored` is what a drop looks like.

### Matchers

| Matcher | Semantics |
|---|---|
| `keyEquals(key)` | Both sides through the key fold below. **A nil key never matches** — a path segment or bare string has no key |
| `valueStartsWith(prefix)` | Ordinal, **case-sensitive**. `"Title - "` is authored to match literally |
| `numericRange(min, max)` | The **whole trimmed value**, invariant locale; `"19 94"` and `"1994a"` are not numbers. **Bounds inclusive** |
| `pathRootStartsWith(root)` | **Boundary-respecting**: `/mnt/media` must not swallow `/mnt/mediaXYZ`. Backslashes normalise, trailing slashes trim, an exact equal yields an empty remainder |

### The key fold

The one normalisation in the pipeline, and **two callers must never disagree
about it** — the `keyEquals` matcher and the candidate seen-set. A seen-set
folding differently either under-collapses (duplicate candidates) or
over-collapses (a silently lost category assignment). Both were real review
defects, on two successive rewrites.

1. remove `[0]`-style array indices · 2. drop a leading `.` · 3. lowercase ·
4. remove every non-alphanumeric character

### Degrade, never throw

An unregistered matcher **does not match and does not throw**. A rule authored
against a newer build goes inert rather than taking down an analysis run over a
whole library. Same for an unknown kind.

## The pipeline is recursive

The single most important thing the old specs say, and the thing spec 14's
"three sources, one queue" understates: **a path inside a JSON value inside a
container comment is parsed all the way down.**

- `TextParser` is the hub, holding an ordered list of sub-parsers **registered
  as data, never a switch**. Path and JSON parsers are sub-parsers.
- A sub-parser returns `nextStrings` that **loop back into `TextParser`**. It
  never produces candidates itself — the rule-based fallback is the only place a
  raw string becomes one.
- **Paths are an ordered list of strings and nothing more.** Splitting a path is
  parsing, however presentational it looks, so it happens once in the Kit and
  the view only draws an already-split list.
- **Termination is a timeout, nothing else.** A depth cap and a node budget were
  both built and then deliberately removed: recursion should not hit a limit in
  normal operation, and a wall-clock bound guards the thing worth guarding
  rather than standing in for it. The seen-set stays as a **cycle guard**, and
  is **key-scoped**.
- A truncated run must **say so where the results are**, not only in a
  provenance list. An incomplete list that looks complete is worse than a
  visibly incomplete one.

### Sources

Five readers, not three: applied tags, container metadata, file properties,
sidecar `.txt`, and OCR. **OCR is opt-in and never runs on the automatic load.**

### Candidate shape

`name · category? · applied · suppressedReason? · preTicked · sourceReaderId ·
rawValue · pathSegments?`

`suppressedReason` is `fragment · weakWord · rule · alreadyApplied` — a reason,
not a boolean, because the suppressed view has to say *why* a value was struck
and a boolean forces the view to re-derive it.

## Build order

**A · The vocabulary and the engine** *(no UI)*
Typed matchers and actions round-tripping the wire JSON, the key fold, and the
fold above. Pure logic, fully testable, and what every later phase rests on.
The semantics above are the test oracle.

**B · The recursive parser core**
`TextParser` with sub-parsers as data, path and JSON sub-parsers, timeout-based
termination, the key-scoped seen-set folded through A's normaliser, and
provenance as returned data rather than logging. The old app's pathological
tests port directly and are the reason termination is understood at all:
mutual recursion, case-flip repeats, wide fan-out, and the same text under two
keys parsed twice.

**C · Readers and the candidate queue**
The five readers behind one interface, the decisions table so an ignored
candidate stays ignored, and the derived queue. Suppression — fragment, weak
word, rule, already-applied — carries a reason.

**D · The Candidates tab**
Spec 14's layout: source and status filters, candidate rows, the evidence strip
seeking each still to `OcrTextLine.timeSeconds`, and the bulk bar.

**E · The Rules tab, and "Make a rule from this"**
Reorderable numbered cards, the matcher/action editor, the dry run, and spec
§4's "if a rule already covers it, open that rule rather than adding a rival".

A and B are pure Kit and carry almost all the risk. C is where the sweep cost
lands. D and E are presentation over settled logic.

## Deliberately not planned yet

- **The pending-changes table.** The old app's `2026-08-19` page design puts a
  before/after table under the player, grouped by category, with struck /
  regular / bold statuses and aliases indented under each tag as a *recognition
  aid*. Spec 14 has an evidence strip instead and does not mention it. It is a
  good idea that belongs to a different layout; raise it against spec 14 rather
  than smuggling it in.
- **The component suite around the engine** — `FragmentSuppressor`,
  `WeakWordEvaluator`, `FuzzyTagMatcher`, `JsonLeafExtractor`,
  `InventoryPhraseSplitter`, `NameClusterFinder`, `TagSuggestionMatcher`. Each
  needs its own read before porting; none is on the critical path to a working
  queue.
- **Phase C's sweep cost** is confirmed acceptable but wants the
  progress-and-resume treatment the OCR and thumbnail sweeps have, not a
  blocking pass.
