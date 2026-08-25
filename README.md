# Sights and Sounds

A native macOS media-library app — the replatform of the web-based
Sights and Sounds (video/audio organizer), with iOS, iPadOS and tvOS to
follow. Full context, locked decisions and the 11-phase plan live in
[docs/replatform-brief.md](docs/replatform-brief.md).

## Status — Phase 3a: browse workspace

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
- ✅ **Phase 3a** (this): the browse workspace.
  - One library per window; the workspace is a shell composing sidebar,
    grid and player as independent scenes.
  - Sidebar: sources with observed online/offline state (enable/disable
    via context menu), folder tree with counts, the three-way tag filter
    panel (click cycles require → exclude → clear), status flags.
  - Filtered grid backed entirely by the SQL compiler; thumbnails via
    AVAssetImageGenerator with a disk cache, so offline sources still
    look complete; offline items badge and refuse playback.
  - Basic native playback (AVKit) with clip in-point seek. Scrub
    previews, waveforms and the keyboard map land in Phase 3b.

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
