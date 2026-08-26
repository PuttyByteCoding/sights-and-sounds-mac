import Foundation

/// One cross-format metadata field — the Picard-derived table, ported.
/// `key` is what `TagCategory.writebackField` stores; `mp4Freeform` means
/// the MP4 side writes a `----:com.apple.iTunes:<vorbisName>` atom.
public struct StandardField: Sendable, Equatable {
    public let key: String
    public let vorbisName: String
    public let mp4Atom: String
    public let mp4Freeform: Bool
}

public enum StandardFields {
    public static let all: [StandardField] = [
        StandardField(key: "TITLE", vorbisName: "TITLE", mp4Atom: "©nam", mp4Freeform: false),
        StandardField(key: "ARTIST", vorbisName: "ARTIST", mp4Atom: "©ART", mp4Freeform: false),
        StandardField(key: "ALBUMARTIST", vorbisName: "ALBUMARTIST", mp4Atom: "aART", mp4Freeform: false),
        StandardField(key: "ALBUM", vorbisName: "ALBUM", mp4Atom: "©alb", mp4Freeform: false),
        StandardField(key: "DATE", vorbisName: "DATE", mp4Atom: "©day", mp4Freeform: false),
        StandardField(key: "GENRE", vorbisName: "GENRE", mp4Atom: "©gen", mp4Freeform: false),
        StandardField(key: "TRACKNUMBER", vorbisName: "TRACKNUMBER", mp4Atom: "trkn", mp4Freeform: false),
        StandardField(key: "PERFORMER", vorbisName: "PERFORMER", mp4Atom: "PERFORMER", mp4Freeform: true),
        StandardField(key: "COMPOSER", vorbisName: "COMPOSER", mp4Atom: "©wrt", mp4Freeform: false),
        StandardField(key: "DESCRIPTION", vorbisName: "DESCRIPTION", mp4Atom: "desc", mp4Freeform: false),
        StandardField(key: "COMMENT", vorbisName: "COMMENT", mp4Atom: "©cmt", mp4Freeform: false),
        StandardField(key: "LOCATION", vorbisName: "LOCATION", mp4Atom: "LOCATION", mp4Freeform: true),
        StandardField(key: "ORGANIZATION", vorbisName: "ORGANIZATION", mp4Atom: "ORGANIZATION", mp4Freeform: true),
    ]

    public static func find(_ key: String?) -> StandardField? {
        guard let key else { return nil }
        return all.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }
    }

    /// Effective Vorbis field name for a category: the explicit mapping's
    /// name, or an auto-custom fold of the category name — constrained to
    /// `[A-Z0-9_]`, ASCII only (ported: non-ASCII alnum is NOT safe as a
    /// Vorbis field name and folds to `_` like any other junk).
    public static func effectiveVorbisName(categoryName: String, writebackField: String?) -> String {
        if let field = find(writebackField) { return field.vorbisName }
        let cleaned = String(categoryName.trimmingCharacters(in: .whitespaces).map { ch -> Character in
            if (ch >= "a" && ch <= "z") || (ch >= "A" && ch <= "Z") || (ch >= "0" && ch <= "9") {
                return Character(ch.uppercased())
            }
            return "_"
        })
        return cleaned.replacingOccurrences(of: "_", with: "").isEmpty ? "TAG" : cleaned
    }
}

/// One resolved field to write: name, MP4 shape, ordered values.
public struct FieldWrite: Sendable, Equatable {
    public let vorbisName: String
    public let mp4Atom: String
    public let mp4Freeform: Bool
    public let values: [String]

    public init(vorbisName: String, mp4Atom: String, mp4Freeform: Bool, values: [String]) {
        self.vorbisName = vorbisName
        self.mp4Atom = mp4Atom
        self.mp4Freeform = mp4Freeform
        self.values = values
    }
}

public struct CategoryMapping: Sendable, Equatable {
    public let categoryName: String
    public let enabled: Bool
    public let writebackField: String?

    public init(categoryName: String, enabled: Bool, writebackField: String?) {
        self.categoryName = categoryName
        self.enabled = enabled
        self.writebackField = writebackField
    }
}

/// Category tags → FieldWrites, ported merge semantics: one FieldWrite
/// per distinct Vorbis name (case-insensitive); colliding categories merge
/// in mapping order with exact (case-sensitive) duplicates dropped keeping
/// the first, and the first collider's MP4 shape retained.
public enum WritebackMapping {
    public static func resolve(
        mappings: [CategoryMapping],
        tagsByCategory: [String: [String]]
    ) -> [FieldWrite] {
        var unmerged: [FieldWrite] = []
        for mapping in mappings where mapping.enabled {
            guard let values = tagsByCategory[mapping.categoryName], !values.isEmpty else { continue }
            if let field = StandardFields.find(mapping.writebackField) {
                unmerged.append(FieldWrite(
                    vorbisName: field.vorbisName, mp4Atom: field.mp4Atom,
                    mp4Freeform: field.mp4Freeform, values: values))
            } else if mapping.writebackField != nil {
                continue  // stale key — defensive, ported
            } else {
                let name = StandardFields.effectiveVorbisName(
                    categoryName: mapping.categoryName, writebackField: nil)
                unmerged.append(FieldWrite(
                    vorbisName: name, mp4Atom: name, mp4Freeform: true, values: values))
            }
        }

        var order: [String] = []
        var merged: [String: FieldWrite] = [:]
        for write in unmerged {
            let key = write.vorbisName.lowercased()
            if let existing = merged[key] {
                var values = existing.values
                var seen = Set(existing.values)
                for value in write.values where seen.insert(value).inserted {
                    values.append(value)
                }
                merged[key] = FieldWrite(
                    vorbisName: existing.vorbisName, mp4Atom: existing.mp4Atom,
                    mp4Freeform: existing.mp4Freeform, values: values)
            } else {
                merged[key] = write
                order.append(key)
            }
        }
        return order.compactMap { merged[$0] }
    }
}
