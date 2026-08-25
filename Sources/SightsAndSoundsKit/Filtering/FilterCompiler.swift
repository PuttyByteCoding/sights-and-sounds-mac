import Foundation
import GRDB

/// Compiles a `MediaFilter` into one SQL statement.
///
/// This is the Phase 0 spike deliverable: the whole three-way filter —
/// including the exact-folder term and hidden-by-default suppression —
/// evaluates in SQLite. There is no in-memory pass, for any filter.
///
/// Baseline predicates applied to every listing, before the filter's own
/// terms (both are standing rules from the web app):
///   - `kind = ?` — the media-kind hard filter every surface must apply.
///   - `clipExported = 0` — embedded clip rows already exported to a
///     standalone file are hidden everywhere.
public enum FilterCompiler {
    public struct Compiled: Sendable {
        public let sql: String
        public let arguments: StatementArguments
    }

    public static func compile(filter: MediaFilter, kind: MediaKind) -> Compiled {
        var clauses: [String] = []
        var args: [any DatabaseValueConvertible] = []

        clauses.append("mediaItem.kind = ?")
        args.append(kind.rawValue)
        clauses.append("mediaItem.clipExported = 0")

        // Required: AND each term.
        for term in filter.required {
            let t = termSQL(term)
            clauses.append(t.sql)
            args.append(contentsOf: t.args)
        }

        // Excluded: AND NOT each term.
        for term in filter.excluded {
            let t = termSQL(term)
            clauses.append("NOT (\(t.sql))")
            args.append(contentsOf: t.args)
        }

        // Optional: one OR group.
        if !filter.optional.isEmpty {
            var parts: [String] = []
            for term in filter.optional {
                let t = termSQL(term)
                parts.append(t.sql)
                args.append(contentsOf: t.args)
            }
            clauses.append("(" + parts.joined(separator: " OR ") + ")")
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
            args.append(contentsOf: referenced)
        }
        hideSQL += ")"
        clauses.append(hideSQL)

        let sql = """
        SELECT mediaItem.* FROM mediaItem \
        WHERE \(clauses.joined(separator: " AND ")) \
        ORDER BY mediaItem.relativePath
        """
        return Compiled(sql: sql, arguments: StatementArguments(args))
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
