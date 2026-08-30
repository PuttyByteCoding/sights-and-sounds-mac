# Sights and Sounds

A native macOS media-library app — the replatform of the web-based
Sights and Sounds (video/audio organizer), with iOS, iPadOS and tvOS to
follow. Full context, locked decisions and the 11-phase plan live in
[docs/replatform-brief.md](docs/replatform-brief.md).

## Status — Phase 8 complete (shutdown gate open); design pass under way

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
- ✅ **Phase 6b** (merged): compare and decide.
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
- ✅ **Phase 7a** (merged): revertible moves and staging.
  - Every file move goes through the FileAccess boundary with a paper
    trail: never overwrites (timestamp suffix on collision), retries
    transient IO, updates the item's path triplet, and logs a
    revertible fileMoveLog row that outlives purged items.
  - Staging ports MarkAndMove: mark-for-deletion / playback-issue flag
    the row AND move the file under _ToDelete / _PlaybackIssue;
    embedded clips, already-staged and missing files flag only; the
    decision always commits before the move is attempted. decide() now
    stages the loser physically (the 6b placeholder, filled).
  - Purge: files then rows, flagged rows only, offline sources skipped
    whole, failures keep their rows — reported honestly. Confirmed in
    plain words by the user.
  - Moved/staged files never re-import as duplicates — the DB path
    moves with the file.
  - UI: Maintenance menu with Move History (per-entry Revert) and the
    purge flow; player W/D keys now stage physically.
- ✅ **Phase 7b** (merged): clips and container operations.
  - Clip authoring in the player (⌃{ / ⌃} + save bar): an embedded clip
    is a named range carrying its parent's path — the path-unique index
    became partial (real files only) via a proper table rebuild.
  - Clip export: stream-copied to a standalone file; the spent clip row
    keeps the ported breadcrumb (hidden from listings, pointing at its
    export).
  - Optimize (faststart) and Repair: passthrough remux with
    archive-before-write — the replacement is verified BEFORE the
    original moves to _Replaced, so the original is never at risk.
  - Grid context menu: Export Clip / Optimize / Repair; clips resolve
    to their parent's file everywhere (playback, thumbnails).
- ✅ **Phase 7c** (merged): hide blocks and encoding.
  - Hide blocks: { opens at the playhead, } closes (the old map's block
    taps); shaded on the scrubber; skipped LIVE during playback with
    the same segment math the removal edit uses — what you hear is
    what the edit keeps.
  - Block removal: frame-accurate trim+concat re-encode (the ported
    x264 line) to an "(edited)" copy; additive — the original and its
    blocks stay untouched.
  - Encode a Copy: H.264 (the old app's exact default line) or HEVC,
    beside the original, never in place.
  - ffmpeg through one boundary with graceful degradation: no ffmpeg
    is a summary with install guidance, not a failure (CI-proof).
- ✅ **Phase 7d** (merged): reorganization, OCR, join, search.
  - Template reorganization, ported: %Category tokens (underscores for
    spaces), ordinal multi-value choice with notes, missing-token
    skips, per-segment sanitization — previewed before anything moves,
    and every move rides the revertible log. (Standard-field tokens
    join with Phase 8's write-back port.)
  - OCR via Vision: resumable frame scanning (interval + reach in
    ocrProgress, ported shape), recognized lines timestamped.
  - Free-text search (the old SearchQuery): name, path, notes and
    OCR text — wildcards escaped, compiled into the same single SQL
    statement.
  - Join: ffmpeg concat stream copy of a folder's parts, name order,
    additive.
- ✅ **Phase 8a** (merged): metadata write-back.
  - The Picard-derived StandardFields table and the write-back mapping,
    ported with their merge semantics (collision merge in mapping
    order, case-sensitive dedupe, ASCII-folded auto field names).
  - The ported tool ladder: metaflac / AtomicParsley in place when
    present, ffmpeg stream-copy remux as the universal fallback —
    essence untouched by construction.
  - Wipe-and-rewrite is only ever preceded by a pre-write snapshot
    (ffprobe tag JSON); restore writes a snapshot back after taking a
    pre-restore snapshot, so undo is itself undoable. Full run/per-file
    history that outlives moves and deletes.
  - A fallback remux changes bytes: the content hash clears for the
    next sweep.
- ✅ **Phase 8b** (this): backup, restore, validation, triage.
  - Per-library backup via GRDB online backup — consistent while live,
    no closing, later writes never leak in. Backups are verified to
    open and migrate BEFORE any restore swaps files, and the current
    file is archived first, never destroyed.
  - Validation sweep: rows vs disk per online source — missing files,
    orphans, size mismatches — each with one honest action; offline
    sources are skipped whole (absence of a drive is not absence of
    files).
  - Triage: restore-from-staging and clear-playback-issue on flagged
    items in the grid.
  - **The shutdown gate is open**: run the migrator against the real
    snapshot, verify counts, archive the old repo, stop the containers.
- 🔨 **Design pass** (in progress): recreating the designed surfaces in
  `docs/design/` — sixteen specs over the existing SwiftUI views, in the
  order `docs/design/README-specs.md` sets.
  - Design tokens (`Theme`): warm charcoal surfaces with an amber accent,
    the app's own appearance rather than system materials. Archivo (UI)
    and JetBrains Mono (every filename, path, count, duration and
    timestamp) bundled and registered at launch.
  - Spec 01, library picker: a **dialog**, not a window — it appears at
    launch and from File ▸ Open Library… (⌘O), and goes away as soon as a
    library is chosen. Cached per-library counts in the registry, so the
    app opens without opening every library file and waking every drive.
  - Spec 02, browse window: the three-way filter gets a vocabulary (green
    `+` required, blue `~` optional, red `−` excluded, a four-state cycle
    you can walk both ways) with a `Missing — no <Category> tag` row per
    category, a chip bar over the grid and a legend under the sidebar.
    Media type becomes a multi-select filter — the kind guard moves into
    the query as `MediaKinds`, which cannot be empty. Sidebar counts come
    from one batch sharing the listing's baseline. Tiles are drawn by
    named, `V`-cycled **saved views**: eleven slots, nineteen values plus
    one per category, uniform frames per kind with pillarboxing. Offline
    items are badged and desaturated rather than blocked, with a banner
    and a real hide/show toggle; selection and a floating bulk bar.
  - Spec 03, player: Esc unwinds one layer and Tab walks video → tags →
    segments → queue, with the focused zone ringed and named in a footer.
    One keyboard map chosen once (`?` compares both and is the permanent
    cheat sheet); the numpad keeps seeking while you type. Songs, clips
    and hide blocks share one segments rail — `segmentRole` makes a song
    and a clip one record — and on-screen text moves to a bottom drawer
    whose lines tag the playing item only. Triage is a mode, and the only
    place a flag key advances.
  - Spec 04, Categories & Fields: three panes — categories in their order,
    a tag table with use counts and sortable headers, and an always-present
    inspector. `Similar only` clusters the spellings of one name; merging
    keeps the discarded ones as aliases; write-back becomes a picker over
    the thirteen standard keys; field definitions get a UI at last.
    `displayStyle` replaces the checkbox boolean and `isDefaultFocus` is
    gone — focus is the first visible category.
  - Spec 05, Import: four steps — Source › Scan › Review & Stage › Import.
    Scanning produces a list and writes nothing (probing stays lazy, and
    the skipped-extension histogram says what was not listed); nothing
    enters the library until the list is confirmed; tag staging boxes
    apply per import or per folder, and sticky boxes keep their value.
  - Spec 06, Background tasks: a lane per library (which is what a runner
    is) above one chronological table, a detail inspector that keeps a
    failure's full error and payload, and pause per lane as well as
    globally. `Run next` reorders a queue and never pre-empts; Retry files
    a new row and leaves the failure in place; Clear finished keeps
    failures.

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
swift run            # run the app (dev; keyboard focus handled)
./scripts/check-terminology.sh
```

For a double-clickable app with a dock presence:

```sh
./scripts/make-app-bundle.sh   # → dist/SightsAndSounds.app
```

## Layout

| Path | What |
|---|---|
| `Sources/SightsAndSoundsKit/Models` | Entities: media, sources, vocabulary, fields, feature state |
| `Sources/SightsAndSoundsKit/Database` | `LibraryDatabase` (one library file) + `AppDatabase` (registry, prefs) |
| `Sources/SightsAndSoundsKit/Filtering` | `MediaFilter` + `FilterCompiler` (filter → one SQL statement) |
| `Sources/SightsAndSoundsKit/Jobs` | `Job`, `JobRunner`, `JobRecord` — the one job abstraction |
| `Sources/SightsAndSoundsKit/FileAccess` | The one file-system boundary |
| `Sources/SightsAndSoundsApp` | The macOS app: windows, views, and `Theme` (the design tokens) |
| `Sources/SightsAndSoundsApp/Resources/Fonts` | Archivo and JetBrains Mono (OFL, licences alongside) |
| `docs/` | Replatform brief, terminology ledger |
| `docs/design/` | The design handoff: sixteen specs, tokens, comps and screenshots |
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
