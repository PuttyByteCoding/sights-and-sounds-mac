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
///   - `kind IN (…)` — the media-kind hard filter every surface must
///     apply. A listing may name several kinds, but never none: the gate
///     is `MediaKinds`, which cannot be empty.
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
        filter: MediaFilter, kinds: MediaKinds,
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

        let baseline = Baseline.sql(kinds)
        clauses.append(baseline.sql)
        whereArgs.append(contentsOf: baseline.args)

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

    // MARK: - Baseline

    /// The predicates every listing shares — and, just as importantly,
    /// every *count* that labels one. A sidebar count derived from a
    /// different baseline than the grid it sits beside is a number that
    /// lies, so both read these.
    public enum Baseline {
        /// The media-kind hard filter. `MediaKinds` cannot be empty, so
        /// this can never compile to a no-op.
        public static func kindClause(_ kinds: MediaKinds) -> String {
            let placeholders = Array(repeating: "?", count: kinds.ordered.count)
                .joined(separator: ", ")
            return "mediaItem.kind IN (\(placeholders))"
        }

        /// An embedded clip row whose range has been exported to its own
        /// file is hidden everywhere.
        public static let liveRows = "mediaItem.clipExported = 0"

        /// A disabled source's items leave every listing — distinct from
        /// *offline*, which hides nothing.
        public static let enabledSource = """
            EXISTS (SELECT 1 FROM source \
            WHERE source.id = mediaItem.sourceID AND source.enabled)
            """

        /// All three, ANDed, with the kind arguments to bind.
        public static func sql(
            _ kinds: MediaKinds
        ) -> (sql: String, args: [any DatabaseValueConvertible]) {
            (
                "\(kindClause(kinds)) AND \(liveRows) AND \(enabledSource)",
                kinds.ordered.map(\.rawValue)
            )
        }

        /// What a structural status flag means in SQL. One name, one
        /// place: the filter term and the sidebar's count of that flag
        /// are the same predicate, so "Clip (any)" cannot come to mean
        /// two different things.
        public static func status(_ flag: StatusFlag) -> String {
            switch flag {
            case .needsReview: "mediaItem.needsReview"
            case .playbackIssue: "mediaItem.playbackIssue"
            case .markedForDeletion: "mediaItem.markedForDeletion"
            case .favorite: "mediaItem.isFavorite"
            case .clip:
                """
                (mediaItem.parentMediaItemID IS NOT NULL \
                OR mediaItem.isClip OR mediaItem.isExportedClip)
                """
            case .embedded: "mediaItem.parentMediaItemID IS NOT NULL"
            case .exported: "mediaItem.isExportedClip"
            case .edited: "mediaItem.isEdited"
            // The analyzer version is a code constant, interpolated as an
            // integer literal — never user input.
            case .analyzedCurrent:
                """
                EXISTS (SELECT 1 FROM tagAnalysisState \
                WHERE tagAnalysisState.mediaItemID = mediaItem.id \
                AND tagAnalysisState.analyzerVersion >= \(ItemAnalysis.analyzerVersion))
                """
            case .analyzedStale:
                """
                EXISTS (SELECT 1 FROM tagAnalysisState \
                WHERE tagAnalysisState.mediaItemID = mediaItem.id \
                AND tagAnalysisState.analyzerVersion < \(ItemAnalysis.analyzerVersion))
                """
            case .neverAnalyzed:
                """
                NOT EXISTS (SELECT 1 FROM tagAnalysisState \
                WHERE tagAnalysisState.mediaItemID = mediaItem.id)
                """
            }
        }

        /// Items carrying a hidden-by-default tag leave every listing
        /// unless the filter explicitly names that tag. The listing
        /// itself builds this with its own exemption list; the counts
        /// use these two forms so a sidebar number and the grid beside
        /// it agree about what is hidden.
        public static let notHidden = """
            NOT EXISTS (SELECT 1 FROM mediaItemTag AS hiddenLink             JOIN tag AS hiddenTag ON hiddenTag.id = hiddenLink.tagID             WHERE hiddenLink.mediaItemID = mediaItem.id             AND hiddenTag.hiddenByDefault)
            """

        /// The same rule for a per-tag count, where the tag being counted
        /// is by definition named by the filter that would show it — so
        /// a hidden tag's own row reports what requiring it would show.
        public static let notHiddenExceptCountedTag = """
            NOT EXISTS (SELECT 1 FROM mediaItemTag AS hiddenLink             JOIN tag AS hiddenTag ON hiddenTag.id = hiddenLink.tagID             WHERE hiddenLink.mediaItemID = mediaItem.id             AND hiddenTag.hiddenByDefault             AND hiddenLink.tagID <> mediaItemTag.tagID)
            """

        /// What "this item has no tag in that category" means in SQL —
        /// shared by the `missingCategory` term and the sidebar's
        /// `Missing — no <Category> tag` count.
        public static let missingCategory = """
            NOT EXISTS (SELECT 1 FROM mediaItemTag \
            JOIN tag ON tag.id = mediaItemTag.tagID \
            WHERE mediaItemTag.mediaItemID = mediaItem.id \
            AND tag.tagCategoryID = ?)
            """
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
            return (Baseline.missingCategory, [categoryID])

        case .status(let flag):
            return (Baseline.status(flag), [])
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
