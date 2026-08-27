import Foundation
import GRDB

/// Compiles a `MediaFilter` into one SQL statement.
///
/// The whole three-way filter — including the exact-folder term and
/// hidden-by-default suppression — evaluates in SQLite. There is no
/// in-memory pass, for any filter.
///
/// Baseline predicates applied to every listing, before the filter's own
/// terms (all standing rules from the web app, plus the Phase 1 source
/// model):
///   - `kind = ?` — the media-kind hard filter every surface must apply.
///   - `clipExported = 0` — embedded clip rows already exported to a
///     standalone file are hidden everywhere.
///   - the item's source is enabled — a disabled source's items leave
///     every listing (distinct from *offline*, which hides nothing).
public enum FilterCompiler {
    public struct Compiled: Sendable {
        public let sql: String
        public let arguments: StatementArguments
    }

    public static func compile(
        filter: MediaFilter, kind: MediaKind,
        ordering: MediaOrdering = .relativePath
    ) -> Compiled {
        var joinArgs: [any DatabaseValueConvertible] = []
        var clauses: [String] = []
        var whereArgs: [any DatabaseValueConvertible] = []

        // Ordering may need a join (binds before WHERE) or its own
        // arguments (bind after WHERE — placeholder order is textual).
        var join = ""
        var orderArgs: [any DatabaseValueConvertible] = []
        let orderBy: String
        switch ordering {
        case .relativePath:
            orderBy = "mediaItem.relativePath"
        case .fileName:
            orderBy = "mediaItem.fileName, mediaItem.relativePath"
        case .fileSize(let ascending):
            orderBy = "mediaItem.fileSize \(ascending ? "ASC" : "DESC"), mediaItem.relativePath"
        case .duration(let ascending):
            // Unprobed items (no duration) sort last, per the enum's rule.
            orderBy = """
            mediaItem.durationSeconds IS NULL, \
            mediaItem.durationSeconds \(ascending ? "ASC" : "DESC"), \
            mediaItem.relativePath
            """
        case .fullPath:
            join = " JOIN source AS orderSource ON orderSource.id = mediaItem.sourceID"
            orderBy = "orderSource.name COLLATE NOCASE, mediaItem.relativePath"
        case .random(let seed):
            // Deterministic per (row, seed): a keyed linear hash of the
            // rowid. Coefficients keep the product inside Int64 for any
            // realistic library; quality only needs to look shuffled.
            orderBy = "((mediaItem.rowid + ?) * 2654435761) % 1000000007, mediaItem.relativePath"
            orderArgs.append(seed)
        case .fieldValue(let definitionID, let ascending):
            join = """
             LEFT JOIN mediaItemFieldValue AS sortValue \
            ON sortValue.mediaItemID = mediaItem.id \
            AND sortValue.fieldDefinitionID = ?
            """
            joinArgs.append(definitionID)
            let dir = ascending ? "ASC" : "DESC"
            // Missing values always sort last; numeric before text so
            // number fields order numerically.
            orderBy = """
            sortValue.value IS NULL, \
            sortValue.numericValue \(dir), \
            sortValue.value COLLATE NOCASE \(dir), \
            mediaItem.relativePath
            """
        }

        clauses.append("mediaItem.kind = ?")
        whereArgs.append(kind.rawValue)
        clauses.append("mediaItem.clipExported = 0")
        clauses.append(
            """
            EXISTS (SELECT 1 FROM source \
            WHERE source.id = mediaItem.sourceID AND source.enabled)
            """)

        // Required: AND each term.
        for term in filter.required {
            let t = termSQL(term)
            clauses.append(t.sql)
            whereArgs.append(contentsOf: t.args)
        }

        // Excluded: AND NOT each term.
        for term in filter.excluded {
            let t = termSQL(term)
            clauses.append("NOT (\(t.sql))")
            whereArgs.append(contentsOf: t.args)
        }

        // Optional: one OR group.
        if !filter.optional.isEmpty {
            var parts: [String] = []
            for term in filter.optional {
                let t = termSQL(term)
                parts.append(t.sql)
                whereArgs.append(contentsOf: t.args)
            }
            clauses.append("(" + parts.joined(separator: " OR ") + ")")
        }

        // Free-text search: filename/path/notes/OCR, one LIKE pattern.
        let query = filter.searchText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            let pattern = "%" + escapeLike(query) + "%"
            clauses.append(
                """
                (mediaItem.fileName LIKE ? ESCAPE '\\' \
                OR mediaItem.relativePath LIKE ? ESCAPE '\\' \
                OR mediaItem.notes LIKE ? ESCAPE '\\' \
                OR EXISTS (SELECT 1 FROM ocrTextLine \
                           WHERE ocrTextLine.mediaItemID = mediaItem.id \
                           AND ocrTextLine.text LIKE ? ESCAPE '\\'))
                """)
            whereArgs.append(contentsOf: [pattern, pattern, pattern, pattern])
        }

        // Auto-hide: suppress items carrying a hidden-by-default tag, unless
        // that tag is explicitly referenced by the filter.
        let referenced = filter.referencedTagIDs.sorted { $0.uuidString < $1.uuidString }
        var hideSQL = """
        NOT EXISTS (SELECT 1 FROM mediaItemTag \
        JOIN tag ON tag.id = mediaItemTag.tagID \
        WHERE mediaItemTag.mediaItemID = mediaItem.id \
        AND tag.hiddenByDefault
        """
        if !referenced.isEmpty {
            let placeholders = Array(repeating: "?", count: referenced.count).joined(separator: ", ")
            hideSQL += " AND tag.id NOT IN (\(placeholders))"
            whereArgs.append(contentsOf: referenced)
        }
        hideSQL += ")"
        clauses.append(hideSQL)

        let sql = """
        SELECT mediaItem.* FROM mediaItem\(join) \
        WHERE \(clauses.joined(separator: " AND ")) \
        ORDER BY \(orderBy)
        """
        return Compiled(sql: sql, arguments: StatementArguments(joinArgs + whereArgs + orderArgs))
    }

    // MARK: - Term translation

    private static func termSQL(_ term: FilterTerm) -> (sql: String, args: [any DatabaseValueConvertible]) {
        switch term {
        case .tag(let id):
            return (
                """
                EXISTS (SELECT 1 FROM mediaItemTag \
                WHERE mediaItemTag.mediaItemID = mediaItem.id \
                AND mediaItemTag.tagID = ?)
                """,
                [id]
            )

        case .folder(let path):
            // Exact directory match. `folderPath` is NOCASE and indexed, so
            // this is the SQL form of the old OrdinalIgnoreCase equality —
            // the term that used to force the in-memory pass.
            return ("mediaItem.folderPath = ?", [MediaPath.normalize(path)])

        case .subtree(let path):
            let root = MediaPath.normalize(path)
            // Empty root = the whole library (every stored path is
            // source-relative), so the term matches everything.
            guard !root.isEmpty else { return ("1", []) }
            // ESCAPE pinned explicitly: an unescaped `_` in a folder name
            // silently matched nothing in the old stack (the Npgsql ILike
            // regression) — the escaping itself is under test.
            return (
                "mediaItem.relativePath LIKE ? ESCAPE '\\'",
                [escapeLike(root) + "/%"]
            )

        case .missingCategory(let categoryID):
            return (
                """
                NOT EXISTS (SELECT 1 FROM mediaItemTag \
                JOIN tag ON tag.id = mediaItemTag.tagID \
                WHERE mediaItemTag.mediaItemID = mediaItem.id \
                AND tag.tagCategoryID = ?)
                """,
                [categoryID]
            )

        case .status(let flag):
            switch flag {
            case .needsReview: return ("mediaItem.needsReview", [])
            case .playbackIssue: return ("mediaItem.playbackIssue", [])
            case .markedForDeletion: return ("mediaItem.markedForDeletion", [])
            case .favorite: return ("mediaItem.isFavorite", [])
            case .clip:
                return (
                    """
                    (mediaItem.parentMediaItemID IS NOT NULL \
                    OR mediaItem.isClip OR mediaItem.isExportedClip)
                    """,
                    []
                )
            case .embedded: return ("mediaItem.parentMediaItemID IS NOT NULL", [])
            case .exported: return ("mediaItem.isExportedClip", [])
            case .edited: return ("mediaItem.isEdited", [])
            }
        }
    }

    /// Escape `\`, `%` and `_` for a LIKE pattern using `\` as the escape
    /// character.
    static func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
