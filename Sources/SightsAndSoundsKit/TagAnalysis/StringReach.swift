import Foundation
import GRDB

extension LibraryDatabase {

    /// Library-wide item counts for every (key, value) in embedded
    /// metadata and every OCR line — the ITEMS column beside a per-video
    /// string: "this appears in 148 items" is what makes it worth a tag.
    ///
    /// Keyed by the same fold the analysis dedupes with, so lookups can
    /// never miss on case or key spelling. Two grouped queries, fetched
    /// once per reload — never per row.
    public func stringOccurrenceCounts() throws -> [String: Int] {
        try writer.read { db in
            var counts: [String: Int] = [:]
            for row in try Row.fetchAll(
                db,
                sql: """
                SELECT key, value, COUNT(DISTINCT mediaItemID) AS n \
                FROM embeddedMetadataPair GROUP BY key, value
                """)
            {
                let key = "\(KeyNormalizer.normalize(row["key"] as String))|\((row["value"] as String).lowercased())"
                counts[key, default: 0] += row["n"] as Int
            }
            for row in try Row.fetchAll(
                db,
                sql: "SELECT text, COUNT(DISTINCT mediaItemID) AS n FROM ocrTextLine GROUP BY text")
            {
                let key = "|\((row["text"] as String).lowercased())"
                counts[key, default: 0] += row["n"] as Int
            }
            return counts
        }
    }

    /// The items a string appears in, library-wide — the APPEARS IN list
    /// for a selected candidate. Metadata and OCR only; a path segment's
    /// reach is its folder, which the path itself already says.
    public func itemsCarrying(
        key: String?, value: String, limit: Int = 12
    ) throws -> (names: [String], total: Int) {
        try writer.read { db in
            var ids = Set<UUID>()
            if let key {
                for row in try Row.fetchAll(
                    db,
                    sql: """
                    SELECT DISTINCT mediaItemID FROM embeddedMetadataPair \
                    WHERE key = ? COLLATE NOCASE AND value = ? COLLATE NOCASE
                    """,
                    arguments: [key, value])
                {
                    ids.insert(row["mediaItemID"])
                }
            } else {
                for row in try Row.fetchAll(
                    db,
                    sql: """
                    SELECT DISTINCT mediaItemID FROM embeddedMetadataPair WHERE value = ? COLLATE NOCASE \
                    UNION SELECT DISTINCT mediaItemID FROM ocrTextLine WHERE text = ? COLLATE NOCASE
                    """,
                    arguments: [value, value])
                {
                    ids.insert(row["mediaItemID"])
                }
            }
            guard !ids.isEmpty else { return ([], 0) }
            let names = try String.fetchAll(
                db,
                sql: """
                SELECT fileName FROM mediaItem \
                WHERE hex(id) IN (SELECT value FROM json_each(?)) \
                ORDER BY relativePath LIMIT ?
                """,
                arguments: [
                    "[" + ids.map { "\"\($0.uuidString.replacingOccurrences(of: "-", with: ""))\"" }
                        .joined(separator: ",") + "]",
                    limit,
                ])
            return (names, ids.count)
        }
    }
}
