# 17 — Search String

**Comps:** none — designed in conversation, 2026-09-14.
**Swift:** net-new `Search/SearchRecipe.swift`, `Search/SearchStringBuilder.swift`,
`Search/FirefoxBookmarks.swift` (kit); `Search/SearchSettingsPane.swift`,
`Search/BookmarkSearchView.swift`, `Search/SearchCommands.swift` (app). Touched:
`Models/LibraryInfo`, `Database/LibraryDatabase` (migration), `Settings/AppSettings`,
`SettingsView`, `SightsAndSoundsApp` (menu, focused value), `Browse/BrowseModel`,
`Browse/LibraryWindowView`, `Browse/AuxiliaryWindow`, `Player/PlayerModel`, `Player/PlayerView`.

## What it is for

A video's file name and tags already say what it is. This turns them into one string to
search with — on the web, and in Firefox's bookmarks, where many of these shows are already
filed — without retyping. `sdg_BenFoldsFive_OnStage_2019.mp4` wearing Band "Ben Folds Five",
Year "2019" and Venue "On Stage" becomes:

```
"Ben Folds Five" 2019 at the venue "on stage"
```

## Decisions

1. **A format is a named recipe — an ordered list of parts, then an ordered list of rules —
   and a library keeps several, one of them the default.** Parts name tag categories, and
   categories belong to the library, so the formats live in the library file as JSON on
   `libraryInfo` (column `searchRecipe`, holding `SearchFormats`: the list and the default's
   id), the way the import boxes do. A library that stored one bare recipe before formats
   existed reads it as one format named Default, the default. The default by id falls back
   to the first format, so there is always one to use while any exists. A part is one of
   three kinds:

   | Kind | Source | Options |
   |---|---|---|
   | Literal | fixed text | none — used verbatim |
   | File name | the item's file name | with or without extension; split at underscores into pieces (`FileNameSegments.pieces`) or kept whole |
   | Tags | every tag the item wears from one category, or from all categories | joiner between several tags (default a space) |

   File-name and tag parts also carry **case** (as is · lowercase · UPPERCASE · Title Case)
   and **quoting** (never · multi-word values only · always).

2. **The rules run in the operator's order; formatting last.** A rule is **Exclude** (drop a
   value equal to the text, case-insensitively, whitespace-trimmed — whole values only, a
   whole file-name piece or a whole tag name, never a substring, so "on" cannot eat "On
   Stage") or **Replace** (every occurrence of the text inside a value becomes the other
   text; empty removes it — `-` → ` ` is the one this was asked for). For every value a part
   yields, the rules run top to bottom, so "replace `-` with a space, then exclude `ben folds
   five`" drops `Ben-Folds-Five` and the reverse order keeps it. Then the part's case and
   quoting. A value that ends up empty contributes nothing. Parts are joined with single
   spaces; a part with no values leaves no gap. A recipe stored before the rules were one
   list decodes its `replacements` then its `exclusions` into rules, in that order.

3. **The bookmark query is the values, not the string.** Literals are prose for a search
   engine and mean nothing to a bookmark. The bookmark search takes every non-literal value
   after replacements and exclusions but before quoting, and requires each one, matched
   case-insensitively, in a bookmark's title, URL, tags, description or keyword.

4. **Firefox is read, never asked.** Firefox has no external way to open its bookmarks
   manager with a query, so the app reads the profile's `places.sqlite` itself: copy the
   file and its `-wal` beside it to a temporary folder (Firefox holds the original open),
   open the copy read-only, query, delete the copy. The profile is an app-wide setting
   (`firefoxProfilePath`); **Detect** reads `profiles.ini` and takes the install's default
   profile, else the one marked `Default=1`, else the first. Tags are the bookmark's entries
   under Firefox's tags root; description is `moz_places.description`, with the legacy
   `bookmarkProperties/description` annotation as a fallback; keyword is `moz_keywords`;
   folder path walks `parent` up to the root.

5. **Three commands in a Search menu, so they work from anywhere.** Menu shortcuts beat the
   player's key handler and a tag field alike.

   All three use the **default format**.

   | Command | Key | Does |
   |---|---|---|
   | Copy Search String | ⌘⇧C | builds the string, copies it, shows it in the player footer |
   | Search Firefox Bookmarks | ⌘⇧B | opens the bookmarks window for the item |
   | Search the Web in Firefox | ⌘⇧F | opens Firefox on the web search URL with the string |

   The **subject** is the playing item when the focused window has a player up, otherwise
   the grid's single selected item. Published as a focused scene value; with none, the
   commands are disabled.

6. **The web search URL is app-wide.** `webSearchURL` with a `{query}` placeholder, default
   `https://duckduckgo.com/?q={query}`. Opened in Firefox when it is installed, else in the
   default browser with a footer note saying so.

7. **The page is a Settings tab.** "Search String", per-library scope header, the library
   picker the Tag Category Configuration tab uses. A **Formats** section: a picker of the
   library's formats, the chosen one's name, a "Use for ⌘⇧C, ⌘⇧F and ⌘⇧B" checkbox, Add
   and Remove. Then, for the chosen format, parts as rows — kind, source, formatting —
   with add, remove and move up/down; below them the rules as rows of the same shape, whose
   order is the order they run; a live preview against a **sample file name** — the library's first
   file to start, then anything typed over it, with the first item's tags. An app-wide
   section on the same page holds the Firefox profile (with Detect) and the web search URL.
   The page is a draft: the preview follows every edit, and **Apply** writes it (Revert
   reloads). Nothing takes effect until Apply.

9. **The player has a Search panel.** A right-rail panel like History, toggled from the
   toolbar and remembered (`PlayerPanels.search`): every format's string for the shown item,
   the format's name above each. A click on a string copies it and the footer says so; a
   string a format cannot make for this item reads "(nothing for this item)" and is inert.
   Each row carries a **⌘⇧C** marker, lit on the default format; a click on a marker makes
   that format the default, which is the same fact the Settings checkbox sets. The strings
   refresh with the tags, so a tag applied in the panel beside it shows at once; the formats
   are re-read when the panel opens, so an Apply in Settings reaches an open player.

8. **Missing things say so.** A recipe part naming a category that no longer exists is
   skipped by the builder and flagged in the page. No Firefox profile, no `places.sqlite`,
   or an unreadable copy each show a plain message in the bookmarks window instead of an
   empty list. An empty result names the values it searched for.

## Copy

- Menu: **Search** · **Copy Search String** · **Search Firefox Bookmarks** · **Search the Web in Firefox**
- Settings tab: **Search String**
- Page sections: **Formats** · **Parts** · **Rules** · **Preview** · **Firefox**
- Player panel: **Search** · marker **⌘⇧C** · empty **(nothing for this item)** · hint **Click a string to copy it · ⌘⇧C marks the menu's format**
- Part kinds: **Text** · **File name** · **Tags**
- Rule kinds: **Exclude** · **Replace**
- Case: **As is** · **lowercase** · **UPPERCASE** · **Title Case**
- Quoting: **Never** · **Multi-word only** · **Always**
- Bookmarks window, empty: **No bookmarks match** `<values>`
- Bookmarks window, no profile: **No Firefox profile is set. Choose one in Settings › Search String.**
- Footer after copy: the string itself

## Tests

Kit: the builder against each part kind, each case and quoting option, the rules in both
orders, exclusion as whole-value only, an empty replacement, a missing category, and the
example above verbatim; the formats' round trip, default fallback and legacy single-recipe
decode; the
bookmark values from the same recipes; the Firefox reader against a synthetic
`places.sqlite` the test builds with Firefox's tables (bookmarks, tags, a description, a
keyword, folders); profile detection against a synthetic `profiles.ini`. The menu commands,
the window and the page are view work `swift test` cannot drive.
