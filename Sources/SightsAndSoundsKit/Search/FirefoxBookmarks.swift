import Foundation
import GRDB

/// Why the bookmarks could not be read — each one a plain sentence in
/// the window rather than an empty list.
public enum FirefoxBookmarkError: Error, Equatable, Sendable {
    case noProfile
    case noPlacesFile
    case unreadable(String)

    public var message: String {
        switch self {
        case .noProfile: "No Firefox profile is set. Choose one in Settings › Search String."
        case .noPlacesFile: "The Firefox profile has no bookmarks file (places.sqlite)."
        case .unreadable(let detail): "The bookmarks file could not be read: \(detail)"
        }
    }
}

/// One Firefox bookmark with everything the profile knows about it.
public struct FirefoxBookmark: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let title: String
    public let url: String
    /// "menu / Shows / 2019" — the folders above it, root omitted.
    public let folderPath: String
    public let tags: [String]
    public let description: String?
    public let keyword: String?
    public let dateAdded: Date?
    public let lastModified: Date?
    public let lastVisited: Date?
}

/// Where Firefox keeps its profiles, and which one it opens by default.
public enum FirefoxProfiles {
    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Firefox", isDirectory: true)
    }

    /// The profile Firefox would open: the install section's default,
    /// else the profile flagged Default=1, else the first listed.
    public static func detect(root: URL = defaultRoot) -> URL? {
        guard let text = try? String(contentsOf: root.appendingPathComponent("profiles.ini"), encoding: .utf8)
        else { return nil }
        return defaultProfile(iniText: text, root: root)
    }

    /// Pure, so it is tested: `profiles.ini` in, the profile folder out.
    public static func defaultProfile(iniText: String, root: URL) -> URL? {
        var sections: [(name: String, values: [String: String])] = []
        for rawLine in iniText.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), line.hasSuffix("]") {
                sections.append((String(line.dropFirst().dropLast()), [:]))
            } else if let equals = line.firstIndex(of: "="), !sections.isEmpty {
                let key = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
                sections[sections.count - 1].values[key] = value
            }
        }
        func resolve(_ path: String, relative: Bool) -> URL {
            relative ? root.appendingPathComponent(path, isDirectory: true)
                : URL(fileURLWithPath: path, isDirectory: true)
        }
        let profiles = sections.filter { $0.name.hasPrefix("Profile") }
        if let install = sections.first(where: { $0.name.hasPrefix("Install") }),
           let path = install.values["Default"], !path.isEmpty {
            let relative = profiles.first { $0.values["Path"] == path }?.values["IsRelative"] != "0"
            return resolve(path, relative: relative)
        }
        let chosen = profiles.first { $0.values["Default"] == "1" } ?? profiles.first
        guard let chosen, let path = chosen.values["Path"], !path.isEmpty else { return nil }
        return resolve(path, relative: chosen.values["IsRelative"] != "0")
    }
}

/// Reads bookmarks from a COPY of the profile's places file — Firefox
/// holds the original open — and answers "which bookmarks contain every
/// one of these terms" over title, URL, tags, description and keyword.
public enum FirefoxBookmarkReader {
    /// Copy the profile's places file (and its write-ahead log, so the
    /// newest bookmarks are in the copy) aside, search it, delete it.
    public static func search(profile: URL, terms: [String]) throws -> [FirefoxBookmark] {
        let places = profile.appendingPathComponent("places.sqlite")
        guard FileManager.default.fileExists(atPath: places.path) else { throw FirefoxBookmarkError.noPlacesFile }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("firefox-places-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let copy = scratch.appendingPathComponent("places.sqlite")
            try FileManager.default.copyItem(at: places, to: copy)
            let wal = profile.appendingPathComponent("places.sqlite-wal")
            if FileManager.default.fileExists(atPath: wal.path) {
                try FileManager.default.copyItem(at: wal, to: scratch.appendingPathComponent("places.sqlite-wal"))
            }
            return try search(placesFile: copy, terms: terms)
        } catch let error as FirefoxBookmarkError {
            throw error
        } catch {
            throw FirefoxBookmarkError.unreadable("\(error)")
        }
    }

    /// Search one places file directly. Every non-empty term must appear,
    /// case-insensitively, somewhere in the bookmark; no terms lists
    /// every bookmark. Newest-modified first.
    public static func search(placesFile: URL, terms: [String]) throws -> [FirefoxBookmark] {
        let needles = terms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        let all: [FirefoxBookmark]
        do {
            all = try DatabaseQueue(path: placesFile.path).read(loadBookmarks)
        } catch {
            throw FirefoxBookmarkError.unreadable("\(error)")
        }
        return all
            .filter { bookmark in
                let haystack = ([bookmark.title, bookmark.url, bookmark.description ?? "", bookmark.keyword ?? ""]
                    + bookmark.tags).joined(separator: " ").lowercased()
                return needles.allSatisfy { haystack.contains($0) }
            }
            .sorted {
                let left = $0.lastModified ?? .distantPast, right = $1.lastModified ?? .distantPast
                return left == right ? $0.title < $1.title : left > right
            }
    }

    private struct Folder { let parent: Int64; let title: String }

    private static func loadBookmarks(_ db: Database) throws -> [FirefoxBookmark] {
        // Folders, and which of them are tag folders: the children of
        // the tags root, whose own children are tag entries, not bookmarks.
        var folders: [Int64: Folder] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT id, parent, title FROM moz_bookmarks WHERE type = 2") {
            folders[row["id"]] = Folder(parent: row["parent"] ?? 0, title: row["title"] ?? "")
        }
        let tagsRoot: Int64? = try Int64.fetchOne(db, sql: "SELECT id FROM moz_bookmarks WHERE guid = 'tags________'")
            ?? folders.first { $0.value.title == "tags" && folders[$0.value.parent]?.parent == 0 }?.key
        let tagFolderIDs = Set(folders.filter { $0.value.parent == tagsRoot }.map(\.key))

        var tagsByPlace: [Int64: [String]] = [:]
        if !tagFolderIDs.isEmpty {
            for row in try Row.fetchAll(db, sql: "SELECT fk, parent FROM moz_bookmarks WHERE type = 1 AND fk IS NOT NULL") {
                let parent: Int64 = row["parent"] ?? 0
                guard tagFolderIDs.contains(parent), let title = folders[parent]?.title else { continue }
                tagsByPlace[row["fk"], default: []].append(title)
            }
        }
        var keywords: [Int64: String] = [:]
        if try db.tableExists("moz_keywords") {
            for row in try Row.fetchAll(db, sql: "SELECT place_id, keyword FROM moz_keywords") {
                let placeID: Int64 = row["place_id"] ?? 0
                if keywords[placeID] == nil { keywords[placeID] = row["keyword"] }
            }
        }
        // Descriptions: the modern column, else the legacy annotation.
        let hasDescription = try db.columns(in: "moz_places").contains { $0.name == "description" }
        var legacyDescriptions: [Int64: String] = [:]
        if !hasDescription, try db.tableExists("moz_items_annos"), try db.tableExists("moz_anno_attributes") {
            for row in try Row.fetchAll(db, sql: """
                SELECT a.item_id, a.content FROM moz_items_annos a \
                JOIN moz_anno_attributes t ON t.id = a.anno_attribute_id \
                WHERE t.name = 'bookmarkProperties/description'
                """) {
                legacyDescriptions[row["item_id"] ?? 0] = row["content"]
            }
        }

        func path(from parent: Int64) -> String {
            var names: [String] = []
            var current = parent
            var hops = 0
            while let folder = folders[current], folder.parent != 0 || !folder.title.isEmpty, hops < 64 {
                if !folder.title.isEmpty { names.append(folder.title) }
                current = folder.parent
                hops += 1
            }
            return names.reversed().joined(separator: " / ")
        }
        func date(_ microseconds: Int64?) -> Date? {
            microseconds.flatMap { $0 > 0 ? Date(timeIntervalSince1970: Double($0) / 1_000_000) : nil }
        }

        let sql = """
            SELECT b.id, b.title, b.parent, b.fk, b.dateAdded, b.lastModified, \
                p.url, p.title AS placeTitle, p.last_visit_date\(hasDescription ? ", p.description" : "") \
            FROM moz_bookmarks b JOIN moz_places p ON p.id = b.fk WHERE b.type = 1
            """
        return try Row.fetchAll(db, sql: sql).compactMap { row in
            let parent: Int64 = row["parent"] ?? 0
            guard !tagFolderIDs.contains(parent) else { return nil }
            let id: Int64 = row["id"]
            let url: String = row["url"] ?? ""
            let placeID: Int64 = row["fk"] ?? 0
            let title: String = (row["title"] as String?).flatMap { $0.isEmpty ? nil : $0 }
                ?? (row["placeTitle"] as String?).flatMap { $0.isEmpty ? nil : $0 } ?? url
            let description: String? = hasDescription ? row["description"] : legacyDescriptions[id]
            return FirefoxBookmark(
                id: id, title: title, url: url, folderPath: path(from: parent),
                tags: (tagsByPlace[placeID] ?? []).sorted(),
                description: description.flatMap { $0.isEmpty ? nil : $0 },
                keyword: keywords[placeID],
                dateAdded: date(row["dateAdded"]), lastModified: date(row["lastModified"]),
                lastVisited: date(row["last_visit_date"]))
        }
    }
}
