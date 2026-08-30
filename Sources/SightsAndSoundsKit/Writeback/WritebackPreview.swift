import Foundation
import GRDB

/// What a write-back would do, computed without writing anything.
///
/// Write-back is a **wipe and rewrite**: `TagWriters` replaces a file's
/// tag set with exactly the fields it is given, which is why a pre-write
/// snapshot is mandatory. It is also why the preview has to show the
/// value that is about to be replaced — the count of overwrites is the
/// headline figure, not a footnote.
///
/// The preview cannot come from the job's own execution; it is computed
/// from the two halves that already exist — `TagWriters.readTagsJSON`
/// for what is in the file, `WritebackMapping.resolve` for what would go
/// in.
public struct WritebackPreview: Sendable, Equatable {
    public struct Field: Sendable, Equatable {
        public var name: String
        /// What would be written.
        public var newValues: [String]
        /// What is there now. Empty means the field is being added.
        public var previousValues: [String]

        /// A non-empty value being replaced is the case worth an amber
        /// row: something a person put there is going away.
        public var replacesSomething: Bool {
            !previousValues.isEmpty && previousValues != newValues
        }
    }

    public struct File: Sendable, Equatable, Identifiable {
        public var itemID: UUID
        public var fileName: String
        public var relativePath: String
        public var fields: [Field]
        /// Set when this file would be skipped rather than written — an
        /// offline source, a container the ladder cannot write, or
        /// nothing mapped to write. Skipped is a first-class outcome and
        /// is listed by name, never quietly rewritten.
        public var skipReason: String?

        public var id: UUID { itemID }
        public var replacedCount: Int { fields.count(where: \.replacesSomething) }
    }

    public var files: [File]

    public var writableFiles: [File] { files.filter { $0.skipReason == nil } }
    public var skippedFiles: [File] { files.filter { $0.skipReason != nil } }
    public var fieldCount: Int { writableFiles.reduce(0) { $0 + $1.fields.count } }
    public var replacedCount: Int { writableFiles.reduce(0) { $0 + $1.replacedCount } }
}

extension LibraryDatabase {
    /// Dry-run a write-back over these items.
    ///
    /// Reading a file's current tags costs an ffprobe per file, so this
    /// is for a scope someone is looking at — the window previews what is
    /// on screen, not the whole library at once.
    public func previewWriteback(
        itemIDs: [UUID], fileAccess: any FileAccess = LiveFileAccess()
    ) throws -> WritebackPreview {
        let mappings = try writer.read { db -> [CategoryMapping] in
            try TagCategory.order(sql: "sortOrder, name").fetchAll(db).map {
                CategoryMapping(
                    categoryName: $0.name, enabled: $0.writebackEnabled,
                    writebackField: $0.writebackField)
            }
        }

        var files: [WritebackPreview.File] = []
        for itemID in itemIDs {
            guard let item = try writer.read({ try MediaItem.fetchOne($0, key: itemID) }),
                  item.parentMediaItemID == nil
            else { continue }

            var file = WritebackPreview.File(
                itemID: itemID, fileName: item.fileName,
                relativePath: item.relativePath, fields: [])

            guard let url = try resolvedFileURL(for: item, fileAccess: fileAccess),
                  fileAccess.isReachable(url)
            else {
                // Offline is skipped whole, everywhere — an unplugged
                // drive is not data loss, and saying so beats letting it
                // look like one.
                file.skipReason = "source offline or file missing"
                files.append(file)
                continue
            }

            let tags = try writer.read { db -> [String: [String]] in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT tagCategory.name AS category, tag.name AS tag FROM tag \
                    JOIN tagCategory ON tagCategory.id = tag.tagCategoryID \
                    JOIN mediaItemTag ON mediaItemTag.tagID = tag.id \
                    WHERE mediaItemTag.mediaItemID = ? ORDER BY tag.name
                    """,
                    arguments: [itemID])
                var byCategory: [String: [String]] = [:]
                for row in rows {
                    byCategory[row["category"] as String, default: []].append(row["tag"] as String)
                }
                return byCategory
            }

            let writes = WritebackMapping.resolve(mappings: mappings, tagsByCategory: tags)
            guard !writes.isEmpty else {
                file.skipReason = "no write-back-enabled tags"
                files.append(file)
                continue
            }

            let existing = (try? TagWriters.readTagsJSON(url: url))
                .flatMap { WritebackPreview.parseTags(json: $0) } ?? [:]
            file.fields = writes.map { write in
                WritebackPreview.Field(
                    name: write.vorbisName,
                    newValues: write.values,
                    previousValues: existing[write.vorbisName.lowercased()] ?? [])
            }
            files.append(file)
        }
        return WritebackPreview(files: files)
    }
}

extension WritebackPreview {
    /// ffprobe's `format_tags` / `stream_tags` JSON, flattened to
    /// lowercase field names. Values arrive as one string; a
    /// multi-value field is written back semicolon-joined by the
    /// writers, so it is split the same way here.
    static func parseTags(json: String) -> [String: [String]] {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        var result: [String: [String]] = [:]
        func absorb(_ tags: [String: Any]) {
            for (key, value) in tags {
                guard let text = value as? String, !text.isEmpty else { continue }
                let values = text.components(separatedBy: ";")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                result[key.lowercased()] = values
            }
        }
        if let format = root["format"] as? [String: Any],
           let tags = format["tags"] as? [String: Any] {
            absorb(tags)
        }
        if let streams = root["streams"] as? [[String: Any]] {
            for stream in streams {
                if let tags = stream["tags"] as? [String: Any] { absorb(tags) }
            }
        }
        return result
    }
}
