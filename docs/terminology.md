# Terminology ledger

Names that must not enter `sights-and-sounds`. Enforce with `check-terminology.sh`
from the first commit — not at review time.

Both `Video`-holds-audio and `TagGroup` were typed, reviewed past, and became
load-bearing before anyone noticed. The second was only caught because the first
taught us to look. A grep costs nothing and catches exactly that.

## Hard errors — unambiguous identifiers

| Banned | Use instead | Why |
|---|---|---|
| `VideoOrganizer` | `SightsAndSounds` | **Largest carryover risk.** 294 files, all 7 project names, the root namespace. The product has never been called by its own name in code — this is the term most likely to be typed from muscle memory. |
| `Video Organizer` | `Sights and Sounds` | 11 user-visible strings in the web app, including window titles. |
| `TagGroup` | `TagCategory` | "Group" suggests a loose bundle. These are classifications with rules about how many values apply and how they display. |
| `PropertyDefinition` | `FieldDefinition` | "Property" is a language-level term in Swift (stored and computed properties), so it reads ambiguously in every file. "Field" is also what a person calls it on screen. |
| `TagPropertyValue` | `TagFieldValue` | Same rename, tag scope. |
| `VideoPropertyValue` | `MediaFieldValue` | Same rename, media scope — drops `Video` at the same time. |
| `PropertyScope` | `FieldScope` | Supporting enum. |
| `PropertyDataType` | `FieldDataType` | Supporting enum. |
| `VideoSet` | `Source` | Already deleted once from the web app. Naming it again would resurrect the path-prefix ownership model along with the word. |
| `Md5Backfill` | `ContentHashJob` | Naming a job after an algorithm makes changing the algorithm a rename. |
| `Md5Failed` | `contentHashFailed` | Same. |
| `ThumbnailWarming` | `ThumbnailGeneration` | "Warming" is cache jargon describing the mechanism rather than the job. |
| `SAS_MEDIA_ROOT` | *(concept removed)* | The single root becomes per-library sources. |
| `sas_media_token` | *(concept removed)* | The media cookie becomes an ordinary header on a paired connection. |

## Warnings — need human judgement

These can't be banned outright because the English words are legitimate.

| Pattern | Concern | Legitimate uses |
|---|---|---|
| `Video` as a **type name** | The core entity must be `MediaItem`. | `MediaKind.video`, `videoCodec`, `videoStreamCount`, `AVFoundation` types. |
| `Md5` / `MD5` bare | Fine as *the algorithm*, wrong as a *column or type name*. | `Insecure.MD5` at a call site computing a hash. |
| `videos` as a **table or collection name** | Should be `mediaItems`. | A local variable genuinely holding only video-kind items. |
| `Properties` in **user-facing copy** | Should read "Fields". | Swift's own `properties` in doc comments about types. |

## Notes

- **The migrator repo is exempt by design.** `sights-and-sounds-migrator` must speak the
  old vocabulary — the v8 snapshot literally contains a `tagGroups` array and `videos`
  rows. That's precisely why it's a separate repository: the ban here stays absolute,
  with no allowlist and no justification comments.
- **No compatibility aliases.** A typealias from the old name to the new one defeats the
  entire point and is how two names for one thing survive.
