import Foundation
import GRDB
import Testing
@testable import SightsAndSoundsKit

/// Firefox's bookmarks, read from a copy of the profile's places file.
/// The database here is synthetic, built with Firefox's table layout:
/// never the developer's own profile.
@Suite struct FirefoxBookmarksTests {
    /// A places.sqlite with the roots Firefox creates, one nested folder
    /// holding a tagged, described, keyworded bookmark, one plain
    /// bookmark, and a tag folder whose entries must not read as bookmarks.
    private func makePlaces() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("places-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("places.sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url LONGVARCHAR, title LONGVARCHAR,
                    rev_host LONGVARCHAR, visit_count INTEGER DEFAULT 0, hidden INTEGER DEFAULT 0,
                    typed INTEGER DEFAULT 0, frecency INTEGER DEFAULT -1, last_visit_date INTEGER,
                    guid TEXT, foreign_count INTEGER DEFAULT 0, url_hash INTEGER DEFAULT 0,
                    description TEXT, preview_image_url TEXT, origin_id INTEGER);
                CREATE TABLE moz_bookmarks (id INTEGER PRIMARY KEY, type INTEGER, fk INTEGER,
                    parent INTEGER, position INTEGER, title LONGVARCHAR, keyword_id INTEGER,
                    folder_type TEXT, dateAdded INTEGER, lastModified INTEGER, guid TEXT,
                    syncStatus INTEGER DEFAULT 0, syncChangeCounter INTEGER DEFAULT 1);
                CREATE TABLE moz_keywords (id INTEGER PRIMARY KEY, keyword TEXT UNIQUE,
                    place_id INTEGER, post_data TEXT);
                """)
            // Roots: 1 root, 2 menu, 3 toolbar, 4 tags, 5 unfiled.
            try db.execute(sql: """
                INSERT INTO moz_bookmarks (id, type, parent, position, title, guid) VALUES
                    (1, 2, 0, 0, '', 'root________'),
                    (2, 2, 1, 0, 'menu', 'menu________'),
                    (3, 2, 1, 1, 'toolbar', 'toolbar_____'),
                    (4, 2, 1, 2, 'tags', 'tags________'),
                    (5, 2, 1, 3, 'unfiled', 'unfiled_____');
                """)
            // Folders: Shows (under menu) > 2019 (nested).
            try db.execute(sql: """
                INSERT INTO moz_bookmarks (id, type, parent, position, title, guid) VALUES
                    (10, 2, 2, 0, 'Shows', 'folderA_____'),
                    (11, 2, 10, 0, '2019', 'folderB_____');
                """)
            // Places.
            try db.execute(sql: """
                INSERT INTO moz_places (id, url, title, description, last_visit_date) VALUES
                    (100, 'https://example.org/bff-onstage-2019', 'Ben Folds Five live', 'Filmed on stage in 2019', 1700000000000000),
                    (101, 'https://example.org/other', 'Something else', NULL, NULL);
                """)
            // The bookmarks, dated in microseconds like Firefox.
            try db.execute(sql: """
                INSERT INTO moz_bookmarks (id, type, fk, parent, position, title, dateAdded, lastModified, guid) VALUES
                    (20, 1, 100, 11, 0, 'Ben Folds Five live', 1600000000000000, 1650000000000000, 'bm1_________'),
                    (21, 1, 101, 5, 0, 'Something else', 1600000000000000, 1600000000000000, 'bm2_________');
                """)
            // Tags: a folder per tag under the tags root, each holding an
            // untitled entry pointing at the place.
            try db.execute(sql: """
                INSERT INTO moz_bookmarks (id, type, fk, parent, position, title, guid) VALUES
                    (30, 2, NULL, 4, 0, 'concert', 'tagA________'),
                    (31, 1, 100, 30, 0, NULL, 'tagA1_______'),
                    (32, 2, NULL, 4, 1, 'soundboard', 'tagB________'),
                    (33, 1, 100, 32, 0, NULL, 'tagB1_______');
                """)
            try db.execute(sql: "INSERT INTO moz_keywords (id, keyword, place_id) VALUES (1, 'bff', 100)")
        }
        return url
    }

    @Test func everyTermMustHitSomewhereInTheBookmark() throws {
        let places = try makePlaces()
        defer { try? FileManager.default.removeItem(at: places.deletingLastPathComponent()) }

        let hits = try FirefoxBookmarkReader.search(placesFile: places, terms: ["ben folds five", "2019", "on stage"])
        let hit = try #require(hits.first)
        #expect(hits.count == 1)
        #expect(hit.title == "Ben Folds Five live")
        #expect(hit.url == "https://example.org/bff-onstage-2019")
        #expect(hit.folderPath == "menu / Shows / 2019")
        #expect(hit.tags == ["concert", "soundboard"])
        #expect(hit.description == "Filmed on stage in 2019")
        #expect(hit.keyword == "bff")
        #expect(hit.dateAdded == Date(timeIntervalSince1970: 1_600_000_000))
        #expect(hit.lastModified == Date(timeIntervalSince1970: 1_650_000_000))
        #expect(hit.lastVisited == Date(timeIntervalSince1970: 1_700_000_000))

        // A term found only in a tag or the keyword still counts; one
        // found nowhere sinks the bookmark.
        #expect(try FirefoxBookmarkReader.search(placesFile: places, terms: ["soundboard"]).count == 1)
        #expect(try FirefoxBookmarkReader.search(placesFile: places, terms: ["bff"]).count == 1)
        #expect(try FirefoxBookmarkReader.search(placesFile: places, terms: ["ben folds", "phish"]).isEmpty)
    }

    @Test func tagEntriesAreNotBookmarksAndNoTermsMeansEveryBookmark() throws {
        let places = try makePlaces()
        defer { try? FileManager.default.removeItem(at: places.deletingLastPathComponent()) }
        let all = try FirefoxBookmarkReader.search(placesFile: places, terms: [])
        #expect(all.map(\.url).sorted() == ["https://example.org/bff-onstage-2019", "https://example.org/other"])
        #expect(all.first { $0.url.hasSuffix("other") }?.tags == [])
        #expect(all.first { $0.url.hasSuffix("other") }?.folderPath == "unfiled")
    }

    @Test func aMissingPlacesFileIsANamedError() {
        let missing = URL(fileURLWithPath: "/nonexistent/profile")
        #expect(throws: FirefoxBookmarkError.noPlacesFile) {
            try FirefoxBookmarkReader.search(profile: missing, terms: ["x"])
        }
    }

    @Test func theDefaultProfileComesFromTheInstallThenTheDefaultFlagThenTheFirst() {
        let root = URL(fileURLWithPath: "/Users/someone/Library/Application Support/Firefox")
        let withInstall = """
            [Install4F96D1932A9F858E]
            Default=Profiles/abc.default-release
            Locked=1

            [Profile1]
            Name=default
            IsRelative=1
            Path=Profiles/xyz.default
            Default=1

            [Profile0]
            Name=default-release
            IsRelative=1
            Path=Profiles/abc.default-release
            """
        #expect(FirefoxProfiles.defaultProfile(iniText: withInstall, root: root)?.path
            == root.appendingPathComponent("Profiles/abc.default-release").path)

        let flagged = """
            [Profile0]
            Name=one
            IsRelative=1
            Path=Profiles/one

            [Profile1]
            Name=two
            IsRelative=1
            Path=Profiles/two
            Default=1
            """
        #expect(FirefoxProfiles.defaultProfile(iniText: flagged, root: root)?.lastPathComponent == "two")

        let first = """
            [Profile0]
            Name=only
            IsRelative=0
            Path=/somewhere/else/only
            """
        #expect(FirefoxProfiles.defaultProfile(iniText: first, root: root)?.path == "/somewhere/else/only")
        #expect(FirefoxProfiles.defaultProfile(iniText: "", root: root) == nil)
    }
}
