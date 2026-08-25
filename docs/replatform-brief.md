# Sights and Sounds — Native Replatform Brief

*Rev 5 · 24 August 2026 · drawn from the web app at commit `e645b8c`*

The web app is being left behind for a native macOS app, with iOS, iPadOS and tvOS
behind it. This is the full brief: what exists today, what survives, what changes,
and the phased route.

Companion HTML (same content, nicer to read): `replatform-brief.html`
Published copy: https://claude.ai/code/artifact/ddcf425c-5a11-4880-973d-fbd5c4532137

---

## 1. Decisions locked

| # | Decision |
|---|---|
| 01 | **Fully native, self-contained.** The macOS app owns its store and does its own processing. No .NET, no SvelteKit, no Postgres, no Docker. SQLite via GRDB. |
| 02 | **Multiple independent libraries, one database file each.** Concerts, Learning, Home Videos — each a separate SQLite file with its own tag vocabulary. Never shared. |
| 03 | **TagGroup → TagCategory, Property → Field.** Enforced by a banned-words check in CI. No compatibility aliases. |
| 04 | **Unsandboxed and personal, for now.** Direct distribution, not the App Store. Absolute paths and a system `ffmpeg` both available. |
| 05 | **Multiple sources, with an offline state.** An offline source keeps metadata, tags and thumbnails; only playback and file operations stop. |
| 06 | **The existing library migrates — repeatedly.** Frozen as a dev fixture, re-run after every schema change, then once for real at cutover. |
| 07 | **Library order: Concerts, Learning, Home Videos.** Learning second because it demands sequence, progress and hierarchy. |
| 08 | **Best tool per operation.** AVFoundation and Vision where they win, ffmpeg where it wins. |
| 09 | **Keycloak out, device pairing in.** Clients pair with the host Mac and are authorized per library. |
| 10 | **Three repositories.** New app repo, separate disposable migrator, existing repo archived read-only. |
| 11 | **The web app really switches off.** Phase 8 is the shutdown gate. |
| 12 | **Superpowers workflow, no OpenSpec.** Brainstorm → spec → plan → execute, one issue and one PR per user-visible slice. |

---

## 2. Libraries

The single largest change. Today's app has one implicit library whose entire tag
vocabulary is concert-shaped.

### What a library owns

- **Its own TagCategories**, and therefore its own tags, aliases and field definitions.
- **Its own sources** — a source belongs to exactly one library.
- **Its own media items**, reached through those sources.
- **Its own analysis rules**, which reference categories and so cannot be library-agnostic.
- **Its own saved filters, key bindings and view settings** — all of which name tags.
- **Its own duplicate candidates.** Comparing a concert against a home video is noise.

**App-level:** the library registry, paired devices and permissions, worker settings,
preferences. Workers run once and service every library.

### Storage: one SQLite database per library

Each library is its own database file, packaged as a document-style bundle, with a
small app-level store for the registry, pairings and preferences.

The alternative — a single database with a `libraryID` column on every table — would
make cross-library search trivial but require *every query* to remember to scope
itself. That exact discipline problem is already documented in `ARCHITECTURE.md`:
every listing surface must hard-filter by media kind rather than trusting the UI,
because forgetting leaks rows. A second mandatory scoping dimension doubles a failure
mode already encountered, and it fails silently.

Separate files make cross-library leakage **structurally impossible** rather than
merely forbidden, and make a library portable. Accepted cost: cross-library search
becomes explicit work.

### Creating a library

1. **Name and location.**
2. **Template** — Concerts, Learning, Home Videos, or Empty. The existing
   `tags.seed.example.json` is already this format and carries over nearly unchanged.
3. **Review** — the full category list with configuration shown; rename, remove or
   adjust before anything is written.
4. **Sources** — add the first, or defer.

### Sample templates

| Template | Category | Selection | Display | Demonstrates |
|---|---|---|---|---|
| Concerts | Band | Multiple | Search | Large vocabulary, write-back to ARTIST |
| Concerts | Recording Type | Single | Checkboxes | Small fixed set with aliases (SBD, AUD, FM) |
| Concerts | Venue | Single | Search | Section label grouping |
| Concerts | Year | Single | Search | Write-back to DATE |
| Learning | Subject | Single | Search | Default focus category |
| Learning | Instructor | Multiple | Search | Write-back to PERFORMER |
| Learning | Watched | Single | Checkboxes | Two-value category as a workflow flag |
| Home Videos | People | Multiple | Checkboxes | Multi-select over a stable small set |
| Home Videos | Occasion | Single | Search | Birthdays, holidays, trips |
| Home Videos | Location | Single | Search | Write-back to LOCATION |

### What the second library will demand

Learning exercises concepts a concert library never needed:

- **Sequence.** Course lessons are ordered; concerts aren't. Today's browse sorts are
  `shuffle | fileName | fileSize | duration | folderFile` — **there is no sort by tag
  or field value**, so ordering by a Lesson Number field is not expressible at all.
  Phase 1 schema requirement and Phase 3 browse requirement.
- **Progress state.** Watch count is a tally, not a state machine. Learning wants
  completion and probably resume position.
- **Hierarchy.** Subject → Course → Lesson is two levels deeper than Band → Show.
  Decide whether that's three TagCategories or a real parent-child relationship.

Home Videos third stresses a different axis — many-valued People tags, date-shaped
browsing — against a schema that has already survived one genuinely different library.

### Working across libraries

- **One library per window.** Open several at once, each in its own window.
- **The library is the top-level context.** No global "all libraries" grid initially —
  it would need a merged vocabulary that by design doesn't exist.
- **Moving an item between libraries is a file move.** Tags do not survive, because the
  target vocabulary differs by construction. Say so plainly rather than dropping silently.

---

## 3. Repositories & terminology

### Three repositories

- **`sights-and-sounds`** — new. The app. Clean terminology, enforced.
- **`sights-and-sounds-migrator`** — new, separate, disposable. Reads a v8 snapshot,
  writes a library file. Archived once the migration is done.
- **the existing repo** — archived read-only. Reference during the port, never a dependency.

**Why the migrator is separate:** it is the one place old terminology *must* appear.
The v8 snapshot literally contains a `tagGroups` array and `videos` rows. Keeping that
in the app repo would mean the banned-words rule needs exceptions, and a rule with
exceptions erodes. Separated, the ban in the app repo is absolute.

### Terminology ledger

Terms that must not appear in `sights-and-sounds`. Enforce with a grep in CI from the
first commit.

| Banned | Use instead | Why |
|---|---|---|
| `VideoOrganizer` | `SightsAndSounds` | **Largest carryover risk.** 294 files, all 7 project names, the root namespace. The product has never been called by its own name in code. |
| "Video Organizer" | "Sights and Sounds" | 11 user-visible strings, including window titles. |
| `Video` (as entity) | `MediaItem` | Named for half of what it holds; audio has shared the table since FLAC support. |
| `TagGroup` | `TagCategory` | "Group" suggests a loose bundle. These are classifications with rules. |
| `PropertyDefinition` | `FieldDefinition` | "Property" is a language-level term in Swift. "Field" is also what a person calls it on screen. |
| `TagPropertyValue` | `TagFieldValue` | Same rename, tag scope. |
| `VideoPropertyValue` | `MediaFieldValue` | Same rename, media scope. |
| `PropertyScope`, `PropertyDataType` | `FieldScope`, `FieldDataType` | Supporting enums move with it. |
| `VideoSet` | `Source` | Already deleted once. Naming it would resurrect the prefix-ownership model. |
| `Md5`, `Md5Failed`, `Md5Backfill` | `contentHash`, `ContentHashJob` | Naming a column after an algorithm makes changing the algorithm a schema migration. |
| `ThumbnailWarming` | `ThumbnailGeneration` | "Warming" is cache jargon describing mechanism, not job. |
| `videos` (table, routes) | `mediaItems` | Follows the entity rename through storage and protocol. |
| `SAS_MEDIA_ROOT`, `sas_media_token` | *(concepts removed)* | Single root becomes per-library sources; the cookie becomes a header on a paired connection. |

Both `Video`-holds-audio and `TagGroup` were typed, reviewed past, and became
load-bearing. The second was only caught because the first taught you to look.

---

## 4. Sources & offline

### What the old model got wrong

A media item belonged to a source because its path *started with* the source's path.
No foreign key — ownership was a string prefix. That rippled everywhere: relocating a
source meant rewriting the source path and every child path atomically; the streaming
guard was a prefix test; disabling meant hiding rows. It grew awkward enough to be
removed entirely.

### The model to build

- **`Source`** — name, root path, kind (internal / external / network), enabled flag,
  last-seen timestamp, owning library.
- **Real foreign keys** — `Source.libraryID`, `MediaItem.sourceID`. Ownership declared,
  not inferred.
- **Paths stay source-relative** — the good half. Relocating updates one row.
- **The access guard becomes a join**, not a prefix test.
- **A source is a folder, not a volume**, so one drive can host sources for several
  libraries at different paths.

### Offline is first-class

Online-ness is observed, not stored: a source is online when its root is reachable.
Mount/unmount notifications drive transitions, with a reachability check as fallback.

- **Everything except touching the file still works** — metadata, tags, fields, flags,
  duplicate candidates and OCR text are all local.
- **Thumbnails keep working** — the preview cache is local, so an offline source still
  *looks* complete rather than showing placeholders.
- **Playback and file operations are disabled**, with clear per-source state.
- **Workers skip offline sources** and pick them up on return.

Today an unreachable root degrades the whole app. Per-source state means one unplugged
drive costs that drive's playback and nothing else.

---

## 5. Client authentication

Replaces Keycloak, JWT bearers, the media-token cookie, the IP allowlist and the CA
dance. Three recent access problems were plumbing: a certificate needing trust on every
device, an allowlist that broke when DHCP moved a Mac, and a token smuggled through a
cookie because `<video>` can't set an Authorization header. A native client has none of
those constraints.

| Step | What happens |
|---|---|
| **Discover** | Bonjour. The host advertises; clients browse. No addresses typed, DHCP reassignment is a non-event. |
| **Pair** | The host shows a six-digit code (QR variant for phones). Single-use, expires quickly. No account, no identity provider, no internet. |
| **Trust** | The host generates one self-signed TLS identity, kept in its Keychain. The client pins the fingerprint at pairing and verifies against the pin — **never a trust store, on any device**. |
| **Authorize** | A long-lived per-device token in the client's Keychain, presented as an ordinary header. Each device carries a role — viewer / editor / full — **per library**. |
| **Manage** | A device list on the host: name, platform, per-library roles, paired date, last seen, revoke. |

Per-library roles matter: the living-room Apple TV can have Concerts and Home Videos
while never seeing Learning.

**Out of scope:** access from outside the LAN (use an overlay network if ever wanted,
never port forwarding), user accounts (devices are the unit of identity), certificate
authorities in any form.

**Prove early:** iOS requires an explicit local-network permission and declared service
types, easy to get wrong in a way that leaves discovery silently broken.

---

## 6. Migration

The v8 JSON snapshot contains all 19 tables as plain lists, **ordered
parents-before-children** so a consumer can insert in array order without tripping
foreign keys. Every version gate from v1 to v8 is documented in `DbSnapshot.cs`,
including which tables self-heal and which — the analysis rules — explicitly do not.

The snapshot has no concept of a library, so migration must *invent* the library that
was always implicit, and do it visibly.

### Two migrations, not one

The migrator does not need the old app running — it needs one exported snapshot file.

- **Dev migrations, many.** Export a snapshot now, freeze it as a local fixture. Delete
  the library file and regenerate after every schema change through Phases 1–4. Real
  data throughout, schema stays cheap to change, and the migrator gets exercised dozens
  of times so bugs surface early.
- **The cutover migration, once.** A fresh export at the end, since tagging continues in
  the web app throughout.
- **Keeping the web app alive is a separate question** — about continuing to work in it,
  not about the migrator.

> **The frozen fixture never enters a repository.** A real snapshot contains real
> filenames and the real tag vocabulary. Local disk only, never committed, never in CI.
> The migrator's tests run against a small synthetic snapshot.

### The flow

1. **Name the library** — defaulting to "Concerts".
2. **Review the TagCategories** that will be created, with configuration and tag counts.
   Rename or exclude before anything is written. *Same screen new-library creation uses.*
3. **Map the old root to a source.**
4. **Verify counts** — media items, tags per category, rule count, against the source DB.

### Mapping decisions

- **Per-feature flags get rehomed** into their own tables on the way in. Cheapest moment.
- **Recomputable data need not migrate** — stream hashes, quality analyses, fingerprints,
  thumbnails all self-heal.
- **Analysis rules must migrate.** Authored, not derived.
- **Write-back history and snapshots are worth carrying** — the undo trail for operations
  that touched real files.

---

## 7. Design decisions

### Keep

- **Filtering happens in SQL.** The three-way tag filter compiles to a database
  predicate. This is why the store is GRDB rather than SwiftData — it's the hardest
  query in the product. Fix the in-memory folder-equality exception rather than
  reproduce it.
- **Signal-driven background workers.** Sleep until woken, no polling. Decide work from
  disk state rather than a DB flag — why missing thumbnails self-heal.
- **Destructive operations are reversible.** Pre-restore snapshots, revertible move logs,
  purge only touching flagged rows, archive-before-write. Maps directly onto native undo.
- **Human-reviewed duplicates.** The fingerprint prefilter has a *measured* reliability
  floor near 25s. Port the matcher; do not redesign the thresholds.
- **Synthetic media fixtures in tests.** Private media never reaches CI.

### Changed

- **Single root, prefix ownership** → multiple sources, explicit FKs, offline state.
- **Everything shells out to ffmpeg** → best tool per operation. **AVFoundation** wins on
  playback, thumbnails, waveforms, trimming, faststart remux, standard-container
  metadata. **Vision** wins on OCR outright. **ffmpeg keeps** stream hashing, Chromaprint
  fingerprinting, tag write-back to formats AVFoundation won't touch, odd containers,
  exact stream-copy semantics.
- **Sprite sheet scrub previews** → `AVAssetImageGenerator`. Keep the caching discipline
  and disk-state self-healing; the sprite sheet goes.
- **TagGroup / Property naming** → TagCategory / Field.
- **One implicit library** → explicit and plural.

### Gone

- **Anemic domain model, logic in endpoints.** Root cause of nearly every code finding.
- **.NET + PostgreSQL + SvelteKit.** Extract the rule engine, fingerprint matcher, filter
  semantics and snapshot format definition before deleting.
- **OpenAPI as contract.** Moot without a network boundary. Revive in miniature in Phase 9.
- **Keycloak, IP allowlist, forced HTTPS.** Replaced by pairing with pinning.

### Watch

- **Unsandboxed, "for now".** Sandboxing later means reworking every file access onto
  security-scoped bookmarks. **Cheap insurance: put all file access behind one narrow
  interface from day one** so the change stays confined. Do not scatter path handling.

---

## 8. Code organization — lessons from the web app

| Metric | Finding | Lesson |
|---|---|---|
| **4,382 lines** | The player is a god component — 189 state/function declarations covering playback, tag editing, suggestions, OCR, scrub frames, zoom, blocks, clips, recovery, refresh. | The player owns playback and nothing else. Tagging, OCR and clip authoring are separate features reachable *from* a playing item. |
| **4,820 lines** | The "core" endpoint file became a catch-all — ~110 endpoints spanning flags, streaming, thumbnails, OCR, encode, join, repair, clips, validation, hashing, blocks. | The convention was right; the discipline lapsed. "Ungrouped" is not a domain. |
| **13 classes** | Long-running jobs rebuilt per operation — import, encode, join, repair, clip export, block removal, move, OCR, optimize, write-back, hash, fingerprint, thumbnails. Most ~56 lines, nearly identical. | One concept implemented thirteen times. **Build it once in Phase 1** — highest-leverage single change available. |
| **48 columns** | The core entity accreted per-feature flags — two failure flags with error strings, a generation flag, playback-issue, marked-for-deletion, needs-review, three clip booleans, an OCR marker. | Per-feature state belongs beside its feature, not on the hottest table. |
| **2 dimensions** | Query scoping is a discipline that fails silently — the media-kind hard-filter rule exists because the mistake was made. | The argument that settled one database per library. |
| **3,930 lines** | Browse carried the whole workspace until two late tickets extracted panels. | A workspace should be a shell composing independent scenes from the start. |
| **1 entity** | `Video` holds audio. `TagGroup` is the same failure caught earlier. | Name it `MediaItem` and `TagCategory` on day one. |
| **219 files** | **What went right** — 121 C# and 98 frontend test files, risky paths under integration test. Pure testable modules separating measurement from decision. | Carry both habits over unchanged. The comments explaining *why* are why this port is tractable. |

---

## 9. Phased plan

### Phase 0 — Skeleton and store
Prove the hardest things first.
- App skeleton, GRDB store, migration mechanism, test harness.
- **Spike the three-way tag filter** as a real query; confirm it compiles to the SQL you expect.
- **Prove the library storage shape** — open two libraries at once, confirm they cannot see each other.
- One narrow file-access interface (the sandboxing insurance).

*Ships: an app with a schema and a proven filter.*

### Phase 1 — Libraries, sources, schema, jobs
- `Library` as top-level container; app-level registry beside it.
- `Source` with library ownership, source-relative paths, online detection.
- `MediaItem` with kind. Per-feature state in its own tables.
- `TagCategory`, tags, aliases, `FieldDefinition`s.
- **Field values must be sortable** — Learning needs lesson ordering.
- **The generic job abstraction** — built once, used by everything after.

*Ships: a schema that holds the whole product.*

### Phase 2 — Library creation and migration
- The category review screen, built once, used by both flows.
- New-library creation with Concerts / Learning / Home Videos / Empty templates.
- A v8 snapshot reader landing as the first library.
- Verify counts; rehome flags; skip what self-heals; carry the analysis rules.

*Ships: your concerts library carried over, and a second one creatable.*

### Phase 3 — Browse and playback
- Filtered grid with the three-way filter in SQL, folder-tree navigation.
- Native playback with `AVAssetImageGenerator` previews and waveforms.
- The keyboard map.
- One library per window; offline-source presentation with cached thumbnails.

*Ships: a Mac app you'd rather use than the web app.*

### Phase 4 — Tagging and analysis
- TagCategory editing, bulk edit, key bindings, hidden tags.
- Candidate mining and the rule engine — ports nearly as-is.
- The analyze workspace as its own scene.

*Ships: full tagging parity.*

### Phase 5 — Ingest and background work
- Directory scan and import with the serialized-queue guarantee.
- Thumbnail generation, hashing, fingerprinting — signal-driven, disk-state-decided, offline-aware.
- One background-tasks dashboard across all libraries.

*Ships: libraries grow and maintain themselves.*

### Phase 6 — Duplicates and compare
- Port the matcher; do not redesign the thresholds.
- Compare view with quality scoring, decide-and-merge.
- Scoped within a library; human review absolute.

*Ships: duplicate detection parity.*

### Phase 7 — Media operations and organization
- Encode, optimize, join, clip export, block removal, repair — each a job conformance.
- OCR via Vision.
- Template reorganization and revertible moves, wired to native undo.

*Ships: macOS feature parity.*

### Phase 8 — Write-back, backup, validation → switch off the web app
- Metadata write-back with snapshots and undo.
- Per-library backup and restore, data validation, purge, playback-issue triage.
- **The shutdown gate.** Archive the old repo; stop the containers.

*Ships: the web app is switched off for good.*

### Phase 9 — Discovery, pairing, serving
- Bonjour, pairing codes, certificate pinning, per-device tokens with per-library roles.
- The device management screen.
- A read protocol for clients.
- Prove the iOS local-network permission on a real device early.

*Ships: the Mac can serve, verified with a test client.*

### Phase 10 — iOS, iPadOS, tvOS
- Shared model and domain packages; per-platform presentation.
- Library picking constrained by what the device is authorized to see.
- tvOS gets focus-driven browse and playback and stops there.

*Ships: the libraries in your pocket and on the TV.*

---

## 10. Platform matrix

| Capability | macOS | iOS | iPadOS | tvOS |
|---|---|---|---|---|
| Pick a library | Full — multi-window | Rev 1 | Rev 1 | Yes |
| Create / configure a library | Full | No | No | No |
| Browse & filter | Full | Rev 1 | Rev 1 | Yes |
| Playback | Full | Rev 1 | Rev 1 | Yes |
| Edit tags | Full | Rev 2 | Rev 2 | No |
| Submit new media | Full | Rev 3 | Rev 3 | No |
| Tag analysis | Full | Not planned | Rev 4 | No |
| Duplicates & compare | Full | Not planned | Rev 4 | No |
| Media operations | Full | No | Trigger only | No |
| Organization & moves | Full | No | Rev 4 | No |
| Write-back | Full | No | Rev 4 | No |
| Source management | Full | Status only | Status only | No |
| **Pairing role** | **host** | viewer → editor → full | viewer → editor → full | **viewer** |

**iOS stops at Rev 3** — view, tag, submit. Everything past it is screen-hungry.

**iPadOS Rev 4 is effectively macOS parity**, and gets **its own view layer** written
against the shared domain and view-model packages — independent layout, no duplicated
logic, no stretched-phone compromise.

**Library creation and configuration stay Mac-only** across every rev. Authoring a tag
vocabulary is a desk activity, and keeping it on one platform means the schema-editing
surface has exactly one implementation.

---

## 11. Still open

- **Is Subject → Course → Lesson three TagCategories, or a real hierarchy?** The Learning
  library forces this. The one open modelling question that changes the schema rather
  than the UI.
- **Does progress state belong to the media item or to a viewer?** One person today, but
  paired devices make "watched on the TV, resume on the iPad" plausible, and retrofitting
  per-device state is expensive.
- **Is there a per-library interchange format?** A library is one file, so copying it is a
  backup. Whether an exportable format is *also* wanted is separate; the v8 snapshot is
  the obvious model.

---

## 12. First actions

1. **Export a v8 snapshot from the running web app and freeze it.** One API call today,
   and it unblocks the entire repeatable-migration loop. Keep it local — it carries real
   filenames.
2. **Extract before deleting** — the tag-analysis rule engine, the fingerprint matcher,
   the filter semantics, the snapshot format definition. Easier to port from something
   that still runs and is testable.
3. **Phase 0 spec** — brainstorm → spec → plan in the superpowers workflow.
4. **Layout design** — a canvas across Mac, iPhone, iPad and TV, with iPad drawn as its
   own view layer.
