# Sights and Sounds

A native macOS media-library app — the replatform of the web-based
Sights and Sounds (video/audio organizer), with iOS, iPadOS and tvOS to
follow. Full context, locked decisions and the 11-phase plan live in
[docs/replatform-brief.md](docs/replatform-brief.md).

## Status — Phase 0: skeleton and store

Phase 0 proves the hardest things first, per the brief:

- ✅ **SPM skeleton** — `SightsAndSoundsKit` (shared models + GRDB store) and a
  minimal SwiftUI app shell. Later platforms build their own presentation on
  the same kit.
- ✅ **Migration mechanism** — `DatabaseMigrator` with the `phase0` schema
  slice; applied on open, verified against real files in tests.
- ✅ **The three-way tag filter compiles to SQL** — required / optional /
  excluded slots, tag / folder / subtree / missing-category / status terms,
  hidden-by-default suppression, the media-kind hard filter — one statement,
  no in-memory pass. The exact-folder term (the web app's one untranslatable
  filter) is an indexed equality on a denormalized `folderPath` column.
- ✅ **Two libraries at once, structurally isolated** — one SQLite file per
  library, one pool per file, no ATTACH. Proven in tests.
- ✅ **One narrow file-access interface** — `FileAccess`; the sandboxing
  insurance. No code outside it touches `FileManager`.
- ✅ **Terminology guard in CI** — `scripts/check-terminology.sh` enforces
  [docs/terminology.md](docs/terminology.md) from the first commit.

## Building

Requires Xcode 16+ (Swift 6). Open `Package.swift` in Xcode, or:

```sh
swift build          # build kit + app shell
swift test           # 23 tests: filter semantics, SQL shape, isolation
swift run            # run the Phase 0 app shell
./scripts/check-terminology.sh
```

## Layout

| Path | What |
|---|---|
| `Sources/SightsAndSoundsKit/Models` | `MediaItem`, `TagCategory`, `Tag`, `MediaItemTag`, `MediaPath` |
| `Sources/SightsAndSoundsKit/Database` | `LibraryDatabase` — open/migrate one library file |
| `Sources/SightsAndSoundsKit/Filtering` | `MediaFilter` + `FilterCompiler` (filter → one SQL statement) |
| `Sources/SightsAndSoundsKit/FileAccess` | The one file-system boundary |
| `Sources/SightsAndSoundsApp` | Phase 0 SwiftUI shell |
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
