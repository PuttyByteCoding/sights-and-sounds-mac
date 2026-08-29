# 12 — Library properties

**Comp:** `Mac Library Properties.dc.html`
**Swift:** `LibraryPropertiesView.swift`, `Models/LibraryInfo.swift`

## What changes

`LibraryPropertiesView` is already the right idea and says so in its own header: *Get Info,
for a library — facts and jump-offs, not a second editor*, with aggregates loaded off the main
actor because it must never beachball on a big library. Keep all of that.

Two changes. It gains a second tab for the handful of settings **only this library can own**,
and its rows get a shared column grid so a row with a button stops dragging the rows above it
out of alignment.

## Decisions

1. **Facts and settings, kept apart — by tab.** **Info** is Get Info: identity, contents,
   coverage, history, and links out. **Configuration** holds only what belongs to this library
   and nowhere else: its name, its separator characters, its extension overrides. Everything
   app-wide stays in Settings. The existing view's one exception — an explicit rename lives
   here — stands, and moves to the Configuration tab where it now has company.

2. **Coverage is progress, not damage.** Hashes, thumbnails, fingerprints and scanned text are
   what the background workers chase. Give each a proportion bar and one line under the
   section: a gap is work not yet reached. Report from the same sources the jobs use to decide
   work — the existing view is careful about this and the comment saying so should survive.

3. **A number with somewhere to go gets a button.** `37 pending duplicate pairs` → **Review**.
   Operations logged → **Open log**. Last backup → **Back up now**. File → **Reveal**. A
   properties window earns its place by being the shortest route to the thing the number is
   about.

4. **One separator set per library.** A category chooses *whether* to apply separators, never
   *which* — nobody wants a hyphen to split Band names but not Venue names. So
   `separatorCharacters` is library-wide (README model table), edited here as removable chips
   with a live example, and Categories & Fields links to it rather than restating it.

5. **An override replaces, it never extends.** Extensions inherit from Settings until this
   library overrides them, and then the app-wide list stops applying **entirely**. Show it as
   a state on the group — `from Settings` / `this library` — with one button to take the
   override or hand it back, and a note when the two lists differ. `LibraryInfo`'s
   `effectiveVideoExtensions(appWide:)` already implements exactly this semantics; the UI just
   has to not imply a merge.

6. **Changing extensions changes the next scan, not the library.** Existing items are
   untouched. Say it where the chips are, or someone will expect removing `avi` to remove
   their AVIs.

7. **Every row is a grid.** Label, value and a fixed action column, right-aligned; coverage
   rows add a fixed track column. A `display: none` track leaves the grid entirely, so
   non-coverage sections stay three-column and everything still lines up. This is the tokens
   file's layout rule 1 in miniature — an optional trailing button needs a reserved column or
   it drags every column left on that row alone.

## Model changes

| Change | Why | Where |
|---|---|---|
| `separatorCharacters: String` (default `-._`) | §4; already in the README's table. Feeds `separatorsToSpaces` for every category that opts in. | `Models/LibraryInfo` |
| Operations-logged count and last-backup date | Two rows the comp shows that nothing currently supplies. Last backup can come from the backups directory listing (spec 10). | `Writeback/BackupService`, `Logging` |
| Segment counts in Contents | Once songs and clips are one kind of named range (spec 03), `Clips` becomes `<n> songs · <n> clips`. | query only |

## Layout

Window ~`980` wide. A toolbar of two icon-over-label tabs (**Info · Configuration**), selected
on `#2A2118`.

**Info**: four sections — IDENTITY, CONTENTS, COVERAGE, HISTORY — each a 10 px section label
over a bordered block of rows. Row grid `minmax(0,1fr) / minmax(0,auto) / 76px`; coverage rows
`minmax(0,1fr) / 120px / 112px / 76px` with a 5 px track. Values in mono; source rows tinted by
reachability (green online, `#D9924A` offline); the pending-duplicates value in mauve
`#C58BB8`. Paths middle-truncated, never `direction: rtl`.

**Configuration**: name field with an inert-until-changed **Rename**; separator chips with an
add field and a live `dave-matthews.band_live_2024-06-14 → dave matthews band live 2024-06-14`
example; two extension groups, each with its state chip, its toggle button, removable chips
(inert and dimmed while inheriting) and an add field.

## Copy — verbatim

| Element | String |
|---|---|
| Tabs | `Info` · `Configuration` |
| Identity rows | `Name` · `Library ID` · `Created` · `File` · `Database size` · `Schema migrations applied` |
| Contents rows | `Video items` · `Audio items` · `Segments` · `Media on disk` |
| Coverage rows | `Content hashes` · `Thumbnails on disk` · `Audio fingerprints` · `Items with scanned text` · `Pending duplicate pairs` |
| Coverage note | `All of it recomputes from disk. A gap here is work the background jobs have not reached yet, not damage.` |
| History rows | `Last opened` · `Last backup` · `Operations logged` |
| Actions | `Reveal` · `Review` · `Back up now` · `Open log` |
| Extension states | `from Settings` · `this library` |
| Extension buttons | `Override here` · `Use app defaults` |
| Extension note | `Differs from the app-wide list. Existing items are untouched — this changes what the next scan picks up.` |
| Vocabulary jump-off | `View the full configuration in Settings → Tag Category Configuration; edit categories from the library window's Categories button.` *(existing)* |
| Load failure | `Could Not Read Library` *(existing)* |

## Keep from the existing view

The whole loading discipline: aggregates gathered in a detached task, one `read` doing every
count, and the reason in the header comment — a properties window must never beachball on a
big library. The counts themselves and their exact SQL, including the exclusions that make
them honest (`clipExported = 0` in the kind counts, `parentMediaItemID IS NULL` in the media
size, embedded versus exported clips counted separately). Coverage reported from the sources
the jobs use. Rename as the one edit that belongs here. Reveal-in-Finder as a link-styled
button on the path. `LibraryInfo.effectiveVideoExtensions(appWide:)` as the single place
inheritance is resolved.
