# Sights and Sounds

A native macOS media-library app — the replatform of the web-based
Sights and Sounds (video/audio organizer), with iOS, iPadOS and tvOS to
follow. Full context, locked decisions and the 11-phase plan live in
[docs/replatform-brief.md](docs/replatform-brief.md).

## Status — Phase 1: libraries, sources, schema, jobs

- ✅ **Phase 0** (merged): SPM skeleton, GRDB store + migration mechanism,
  the three-way filter compiling to one SQL statement (no in-memory pass),
  two-library structural isolation, the `FileAccess` boundary, terminology
  guard in CI.
- ✅ **Phase 1** (this): the schema that holds the whole product.
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
