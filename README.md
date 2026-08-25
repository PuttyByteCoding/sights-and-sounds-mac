# Sights and Sounds

A native macOS media-library app — the replatform of the web-based
Sights and Sounds (video/audio organizer), with iOS, iPadOS and tvOS to
follow. Full context, locked decisions and the 11-phase plan live in
[docs/replatform-brief.md](docs/replatform-brief.md).

## Status — Phase 6: duplicates and compare

- ✅ **Phase 0** (merged): SPM skeleton, GRDB store + migration mechanism,
  the three-way filter compiling to one SQL statement (no in-memory pass),
  two-library structural isolation, the `FileAccess` boundary, terminology
  guard in CI.
- ✅ **Phase 1** (merged): the schema that holds the whole product.
  - `LibraryInfo` identity in each library file + the app-level registry
    (`AppDatabase`) that reconciles by library id when files move.
  - `Source` with real FK ownership (never path prefixes), source-relative
    paths, enabled flag; online-ness is observed via `FileAccess`, never
    stored. Disabled sources leave every listing; offline hides nothing.
  - Full vocabulary: `TagCategory` configuration, `Tag` + `TagAlias`,
    `FieldDefinition` with schema-checked scopes.
  - **Sortable field values** — number fields keep a derived `numericValue`
    so a Learning course orders by Lesson Number ("10" after "2"); typed
    `MediaOrdering.fieldValue` joins it in SQL.
  - Per-feature state in side tables (`contentHashFailure`,
    `thumbnailState`, `ocrProgress`) — the 48-column lesson. The line:
    filter/grid state is a column, single-feature state is a side table.
  - **The generic job abstraction** — `Job` + `JobRunner` + persisted
    `JobRecord`: state machine, progress, failure capture, cooperative
    cancellation. The web app implemented this thirteen times; here it
    exists once and every later operation is a conformance.
- ✅ **Phase 2** (merged): library creation.
  - `LibraryPlan` — the editable review model both flows share: template
    creation now, snapshot migration next. Rename, exclude, adjust;
    nothing is written until the whole plan validates.
  - Templates per the brief's sample table: Concerts, Learning (with the
    Subject/Course/Lesson-as-flat-categories decision and Lesson Number
    ordering field), Home Videos, Empty.
  - `LibraryCreator` executes a reviewed plan: file, identity, vocabulary,
    optional first source, registry entry.
  - `analysisRule` storage (phase2 migration) — rules are authored data
    the migrator must carry; the engine itself ports in Phase 4.
  - App shell: library list + the New Library flow (name → template →
    review → create).
- ✅ **Phase 3a** (merged): the browse workspace.
  - One library per window; the workspace is a shell composing sidebar,
    grid and player as independent scenes.
  - Sidebar: sources with observed online/offline state (enable/disable
    via context menu), folder tree with counts, the three-way tag filter
    panel (click cycles require → exclude → clear), status flags.
  - Filtered grid backed entirely by the SQL compiler; thumbnails via
    AVAssetImageGenerator with a disk cache, so offline sources still
    look complete; offline items badge and refuse playback.
  - Basic native playback with clip in-point seek.
- ✅ **Phase 3b** (merged): the player, finished.
  - Custom transport (AVPlayerLayer): scrubber with hover **scrub
    previews** (AVAssetImageGenerator replaces the sprite sheets),
    **waveform timelines** for audio (streamed PCM decode, disk-cached),
    clip-range shading with out-point loop-back, playback-rate menu.
  - **The keyboard map**, ported from the web app's decision table:
    1/4/7 back · 3/6/9 forward (2s/30s/240s defaults, settings-backed),
    5/Space play-pause, 0 start, 8/numpad− near end, Shift+digit and
    numpad variants, ←/→ walk the filtered listing, F/R/D/W flag
    toggles, Escape closes.
  - Progress recording on the media item: resume position (cleared near
    either edge), lastWatchedAt, watch tally + completed on 90% crossing.
  - Privacy guard in CI: library databases and snapshot exports can
    never be tracked (`scripts/check-no-private-data.sh`).
- ✅ **Phase 4a** (merged): tagging core.
  - Tag panel beside the player (T): checkbox categories as checkbox
    lists with ⌥1–9 toggles, pill + autocomplete for the rest,
    default-focus category takes the keyboard.
  - The ported name formatter: TextFormat case rules with
    separators-to-spaces running first, applied identically on every
    create/rename path; single-select categories replace on assign;
    default focus is exclusive — all enforced in the kit's single write
    path, not the UI.
  - Key → tag bindings, library-owned (a table, not browser storage):
    free F-keys and letters toggle tags in the player, optional
    advance-on-apply for triage; editor sheet included.
  - Category manager: full category configuration plus per-tag rename /
    hide / delete with cascades.
- ✅ **Phase 5a** (merged): directory scan and import.
  - `ImportJob` — the first real `Job` conformance: recursive scan,
    AVFoundation probing (duration, dimensions, codecs, streams),
    idempotent by the unique source-relative path, serialized by the
    runner (the old import-queue guarantee), offline/disabled sources
    refuse with clear messages, files never deleted (validation's
    business, Phase 8). Sidecar JSON/text files are noted-but-untouched
    for the future metadata pipeline.
  - Jobs gained a one-line completion summary ("38 new, 2 skipped").
  - App: Add Source… folder picker; per-source Import New Files with
    live progress beside the source row.
  - Note: the rule-engine port (old Phase 4b) is replaced by a
    claims-based metadata pipeline, deliberately sequenced after
    Phase 8.
- ✅ **Phase 5b** (merged): background workers and the dashboard.
  - Content hashing sweep (MD5 for cross-migration comparability; the
    column stays algorithm-neutral): per-item failures recorded beside
    the feature and never stall the sweep or retry endlessly.
  - Thumbnail sweep: disk state decides — a deleted cache file
    regenerates on the next signal even though the DB row says done.
  - Signal-driven, no polling: import completion and volume mounts wake
    the workers; duplicate signals collapse (enqueueUnlessPending).
  - One job runner per library, app-owned — windows and the dashboard
    share it, so cancellation works from anywhere.
  - Background Tasks window: every library's jobs, live progress,
    summaries, cancellation.
- ✅ **Phase 6a** (merged): duplicate detection.
  - The fingerprint matcher, ported with its measured thresholds intact
    (BER 0.30 gate, the 25s reliability floor, the calibrated 14-bit
    relative prefilter) — including both survey-hardened behaviors: the
    in-loop overlap floor and the asymmetric-stride offset voting.
  - Candidate pairs: order-normalized, one row per pair ever — a
    rejected pair permanently blocks re-flagging. Human review absolute.
  - Three sweeps on the maintenance signal: identical hashes, audio
    fingerprint capture (fpcalc; a missing tool is a note with install
    guidance, not a failure), and prefiltered fingerprint matching.
  - Compare view, quality scoring and decide-and-merge landed as 6b.
- ✅ **Phase 6b** (this): compare and decide.
  - QualityScore ported: scaled composition (missing signal analysis is
    a non-special case), tier tables intact, blockiness deliberately an
    unscored annotation until a real calibration exists.
  - Decide semantics ported: the library recomputes mergeability (never
    trusts the caller), single-value categories claim in-loop so the
    keeper's pick always wins exactly once, a deletion-staged keeper is
    refused, skipped merges are explained. Loser is flag-marked; the
    physical staging move joins in Phase 7.
  - Review UI: candidate queue with source/confidence, side-by-side
    compare with thumbnails, metadata, score breakdowns, tag carry-over
    toggles, Keep/Not Duplicates. Toolbar badge shows pending count.

### Demo library

**Create Demo Library…** in the app builds a complete fake concert
collection — invented bands and venues, dated show folders, taggings,
field values, and tiny *synthesized* media files (color-bar MP4s,
sine-chord M4As) — so thumbnails, waveforms, scrub previews, playback
and filters all run on data that is fake by construction. Deterministic
per seed; also the fixture generator for tests and future screenshots.

## Building

Requires Xcode 16+ (Swift 6). Open `Package.swift` in Xcode, or:

```sh
swift build          # build kit + app shell
swift test           # filter semantics, SQL shape, schema integrity, jobs
swift run            # run the app shell
./scripts/check-terminology.sh
```

## Layout

| Path | What |
|---|---|
| `Sources/SightsAndSoundsKit/Models` | Entities: media, sources, vocabulary, fields, feature state |
| `Sources/SightsAndSoundsKit/Database` | `LibraryDatabase` (one library file) + `AppDatabase` (registry, prefs) |
| `Sources/SightsAndSoundsKit/Filtering` | `MediaFilter` + `FilterCompiler` (filter → one SQL statement) |
| `Sources/SightsAndSoundsKit/Jobs` | `Job`, `JobRunner`, `JobRecord` — the one job abstraction |
| `Sources/SightsAndSoundsKit/FileAccess` | The one file-system boundary |
| `Sources/SightsAndSoundsApp` | Early SwiftUI shell |
| `docs/` | Replatform brief, terminology ledger |
| `scripts/` | Terminology guard (bash 3.2 portable, wired into CI) |

## Rules that hold from day one

- **Banned words fail CI.** Old-app names must not appear; no compatibility
  aliases. The ledger lists and explains each entry — deliberately the only
  file in the repo that spells them.
- **Every listing query hard-filters by media kind** — the API makes `kind`
  a required parameter so it cannot be forgotten.
- **All file access goes through `FileAccess`** so sandboxing later is a
  one-conformance change.
- **Real library data never enters the repo or CI** — tests use synthetic
  fixtures only.

## Related repositories

- `sights-and-sounds-migrator` — separate, disposable; reads a v8 snapshot
  from the web app and writes a library file. Speaks the old vocabulary by
  design, which is why it is not this repo.
- The web app repo — archived read-only at cutover (Phase 8).
