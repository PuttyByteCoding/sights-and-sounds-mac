# Search String Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build one string from a video's file name and tags by a per-library recipe, copy it, search the web with it in Firefox, and search Firefox's bookmarks with its values inside the app.

**Architecture:** A pure kit layer (recipe model, builder, Firefox bookmarks reader) with no UI dependency, stored per library as JSON on `libraryInfo`. An app layer adds a Search menu whose commands act on a focused-scene "subject" (the playing item, else the grid's single selection), a bookmarks window as a new auxiliary-window kind, and a Settings tab that edits the recipe with a live preview.

**Tech Stack:** Swift 6, SwiftUI, GRDB (SQLite), Swift Testing, AppKit for Firefox launch and the clipboard.

**Spec:** `docs/design/17-search-string.md`

## Global Constraints

- Build with `swift build` must produce zero warnings; `swift test` must pass in full; `scripts/check-terminology.sh` and `scripts/check-no-private-data.sh` must be clean.
- Copy verbatim from the spec: menu **Search** · **Copy Search String** · **Search Firefox Bookmarks** · **Search the Web in Firefox**; tab **Search String**; kinds **Text** · **File name** · **Tags**; case **As is** · **lowercase** · **UPPERCASE** · **Title Case**; quoting **Never** · **Multi-word only** · **Always**.
- Shortcuts: ⌘⇧C copy, ⌘⇧B bookmarks, ⌘⇧F web.
- Default web search URL: `https://duckduckgo.com/?q={query}`.
- Test data stays synthetic. Never read the developer's real Firefox profile in tests.
- Per-key tolerant decoding for every new settings field (a missing key falls back to the default).

---

### Task 1: Recipe model and per-library storage

**Files:**
- Create: `Sources/SightsAndSoundsKit/Search/SearchRecipe.swift`
- Modify: `Sources/SightsAndSoundsKit/Models/LibraryInfo.swift` (add `searchRecipe: String?`)
- Modify: `Sources/SightsAndSoundsKit/Database/LibraryDatabase.swift` (migration `searchRecipe` after `importBoxes`)
- Test: `Tests/SightsAndSoundsKitTests/SearchRecipeTests.swift`

**Interfaces:**
- Produces: `SearchRecipe { parts: [SearchPart]; exclusions: [String]; replacements: [SearchReplacement] }`, `SearchPart { id: UUID; kind: SearchPart.Kind; format: SearchFormat }`, `SearchPart.Kind = .literal(String) | .fileName(includesExtension: Bool, splitsPieces: Bool) | .tags(categoryID: UUID?, joiner: String)`, `SearchFormat { letterCase: SearchLetterCase; quoting: SearchQuoting }`, `LibraryDatabase.searchRecipe() throws -> SearchRecipe`, `LibraryDatabase.setSearchRecipe(_:) throws`.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import SightsAndSoundsKit

@Suite struct SearchRecipeTests {
    @Test func aRecipeRoundTripsThroughTheLibrary() throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Recipe")
        #expect(try library.searchRecipe() == .empty)
        let band = UUID()
        let recipe = SearchRecipe(
            parts: [
                SearchPart(kind: .tags(categoryID: band, joiner: " "), format: SearchFormat(letterCase: .asIs, quoting: .multiWord)),
                SearchPart(kind: .literal("at the venue")),
                SearchPart(kind: .fileName(includesExtension: false, splitsPieces: true), format: SearchFormat(letterCase: .lowercase, quoting: .never)),
            ],
            exclusions: ["sdg"], replacements: [SearchReplacement(from: "-", to: " ")])
        try library.setSearchRecipe(recipe)
        #expect(try library.searchRecipe() == recipe)
    }
}
```

- [ ] **Step 2: Run it** — `swift test --filter SearchRecipeTests` — expect a compile error: no `SearchRecipe`.

- [ ] **Step 3: Implement**

```swift
// Sources/SightsAndSoundsKit/Search/SearchRecipe.swift
import Foundation

public enum SearchLetterCase: String, Codable, Sendable, CaseIterable { case asIs, lowercase, uppercase, titleCase }
public enum SearchQuoting: String, Codable, Sendable, CaseIterable { case never, multiWord, always }

public struct SearchFormat: Codable, Equatable, Sendable {
    public var letterCase: SearchLetterCase
    public var quoting: SearchQuoting
    public init(letterCase: SearchLetterCase = .asIs, quoting: SearchQuoting = .never) { ... }
}

public struct SearchReplacement: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID; public var from: String; public var to: String
    public init(id: UUID = UUID(), from: String, to: String)
}

public struct SearchPart: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: Codable, Equatable, Sendable {
        case literal(String)
        case fileName(includesExtension: Bool, splitsPieces: Bool)
        case tags(categoryID: UUID?, joiner: String)
    }
    public var id: UUID; public var kind: Kind; public var format: SearchFormat
    public init(id: UUID = UUID(), kind: Kind, format: SearchFormat = SearchFormat())
}

public struct SearchRecipe: Codable, Equatable, Sendable {
    public var parts: [SearchPart]; public var exclusions: [String]; public var replacements: [SearchReplacement]
    public init(parts: [SearchPart] = [], exclusions: [String] = [], replacements: [SearchReplacement] = [])
    public static let empty = SearchRecipe()
}

extension LibraryDatabase {
    public func searchRecipe() throws -> SearchRecipe {
        guard let raw = try info()?.searchRecipe, let data = raw.data(using: .utf8) else { return .empty }
        return (try? JSONDecoder().decode(SearchRecipe.self, from: data)) ?? .empty
    }
    public func setSearchRecipe(_ recipe: SearchRecipe) throws {
        let encoded = String(data: try JSONEncoder().encode(recipe), encoding: .utf8)
        try writer.write { db in
            guard var info = try LibraryInfo.fetchOne(db) else { return }
            info.searchRecipe = encoded
            try info.update(db)
        }
    }
}
```

`LibraryInfo` gains `public var searchRecipe: String?` with a `nil` default in `init`; the migration `searchRecipe` adds a `.text` column to `libraryInfo`.

- [ ] **Step 4: Run it** — expect PASS.
- [ ] **Step 5: Commit** — `Search: recipe model stored per library`.

### Task 2: The builder

**Files:**
- Create: `Sources/SightsAndSoundsKit/Search/SearchStringBuilder.swift`
- Test: `Tests/SightsAndSoundsKitTests/SearchStringBuilderTests.swift`

**Interfaces:**
- Consumes: Task 1's types.
- Produces: `SearchSubject { fileName: String; tags: [SearchSubjectTag] }`, `SearchSubjectTag { categoryID: UUID; name: String }`, `SearchStringBuilder.values(for: SearchPart, subject:, recipe:) -> [String]`, `SearchStringBuilder.string(recipe:subject:) -> String`, `SearchStringBuilder.bookmarkTerms(recipe:subject:) -> [String]`, `SearchStringBuilder.missingCategoryIDs(in: SearchRecipe, known: Set<UUID>) -> [UUID]`, `LibraryDatabase.searchSubject(for itemID: UUID) throws -> SearchSubject?`.

- [ ] **Step 1: Write the failing tests** — the spec's example verbatim; each kind; each case; each quoting; replacements before exclusions; whole-value exclusions; a missing category skipped; empty parts leave no gap; bookmark terms unquoted and literal-free.
- [ ] **Step 2: Run** — compile error.
- [ ] **Step 3: Implement** — per spec decision 2. Title Case via `TagNameFormatter.format(_, textFormat: .titleCase)`. File-name pieces via `FileNameSegments.pieces(of:)` when splitting (falls back to the stem when the name carries no underscore). Quoting wraps in straight double quotes; multi-word means the value contains whitespace.
- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** — `Search: the builder turns a recipe and an item into a string`.

### Task 3: Firefox profile detection and bookmarks reader

**Files:**
- Create: `Sources/SightsAndSoundsKit/Search/FirefoxBookmarks.swift`
- Test: `Tests/SightsAndSoundsKitTests/FirefoxBookmarksTests.swift`

**Interfaces:**
- Produces: `FirefoxProfiles.defaultProfile(iniText: String, root: URL) -> URL?`, `FirefoxProfiles.detect() -> URL?`, `FirefoxProfiles.defaultRoot: URL`, `FirefoxBookmark { id: Int64; title: String; url: String; folderPath: String; tags: [String]; description: String?; keyword: String?; dateAdded: Date?; lastModified: Date?; lastVisited: Date? }`, `FirefoxBookmarkReader.search(placesFile: URL, terms: [String]) throws -> [FirefoxBookmark]`, `FirefoxBookmarkReader.search(profile: URL, terms:) throws -> [FirefoxBookmark]`, `FirefoxBookmarkError.noProfile | .noPlacesFile | .unreadable(String)`.

- [ ] **Step 1: Write the failing tests** — build a synthetic `places.sqlite` with `moz_places`, `moz_bookmarks` (roots: root, menu, toolbar, tags, unfiled), `moz_keywords`, one tagged bookmark with a description and a keyword in a nested folder; assert every term must hit; assert tag rows are not returned as bookmarks; assert folder path; parse a synthetic `profiles.ini` for the install default, the `Default=1` profile, and the first profile.
- [ ] **Step 2: Run** — compile error.
- [ ] **Step 3: Implement** — copy `places.sqlite` and `places.sqlite-wal` (if present) to a temporary directory, open with GRDB read-only, load folders, bookmarks, tags, keywords; filter in Swift; delete the copy in `defer`.
- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** — `Search: read Firefox bookmarks from a copy of the profile`.

### Task 4: App settings, subject plumbing, and the Search menu

**Files:**
- Modify: `Sources/SightsAndSoundsKit/Settings/AppSettings.swift` (`firefoxProfilePath: String?`, `webSearchURL: String`)
- Create: `Sources/SightsAndSoundsApp/Search/SearchCommands.swift`
- Modify: `Sources/SightsAndSoundsApp/Browse/BrowseModel.swift` (`playingItemID`, `searchSubject`), `Browse/LibraryWindowView.swift` and `Browse/AuxiliaryWindow.swift` (focused scene value; `.bookmarkSearch` kind), `Player/PlayerModel.swift` (`itemShown` hook, `notice`), `Player/PlayerView.swift` (wire hook; footer shows notice), `SightsAndSoundsApp.swift` (`CommandMenu("Search")`).
- Test: `Tests/SightsAndSoundsKitTests/SettingsTests.swift` (new fields decode tolerantly), `Tests/SightsAndSoundsAppTests/SearchCommandsTests.swift` (`SearchWebURL.resolve(template:query:)`).

**Interfaces:**
- Produces: `SearchSubjectRef { libraryID: UUID; itemID: UUID }` as `FocusedValues.searchSubject`; `SearchWebURL.resolve(template: String, query: String) -> URL?`; `AuxWindowRequest.Kind.bookmarkSearch`.

- [ ] Steps: failing tests for settings decode and URL resolution → implement → pass → commit `Search: menu, subject and settings`.

### Task 5: The bookmarks window

**Files:**
- Create: `Sources/SightsAndSoundsApp/Search/BookmarkSearchView.swift`
- Modify: `Browse/AuxiliaryWindow.swift` (dispatch `.bookmarkSearch`)

- [ ] Implement per spec decisions 4, 5, 8 and the copy; build; commit `Search: the Firefox bookmarks window`.

### Task 6: The Settings tab

**Files:**
- Create: `Sources/SightsAndSoundsApp/Search/SearchSettingsPane.swift`
- Modify: `SettingsView.swift` (tab), `docs/design/13-settings.md` (one line naming the tab)

- [ ] Implement per spec decision 7; build; commit `Search: the Search String settings tab`.

### Task 7: Verification and PR

- [ ] `swift build` zero warnings; `swift test` all pass; both guard scripts clean; bundle built and launched from the worktree, alive, then quit; PR to `dev` with Why / What / Verification / After merging.

## Self-review

Spec coverage: decisions 1–2 → Tasks 1–2; 3–4 → Task 3; 5–6 → Task 4; 7 → Task 6; 8 → Tasks 2, 5, 6; copy → Tasks 4–6; tests → Tasks 1–4. Type names are used consistently across tasks.
