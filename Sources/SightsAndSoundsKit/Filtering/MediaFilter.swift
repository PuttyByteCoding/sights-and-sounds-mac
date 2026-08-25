import Foundation

/// A structural status flag a filter can test. These are system-managed
/// columns on `MediaItem`, not tags — same set the web app's Status filter
/// exposed. Raw values match the old wire strings for the migrator's sake.
public enum StatusFlag: String, Codable, Sendable, CaseIterable {
    case needsReview
    case playbackIssue
    case markedForDeletion
    case favorite
    /// The umbrella: an embedded clip (has a parent), user-marked clip, or
    /// exported clip. The narrower flags below subdivide it.
    case clip
    case embedded
    case exported
    case edited
}

/// One term of the three-way filter.
///
/// The old app's terms arrived as strings and a malformed value silently
/// matched nothing; here every payload is typed, so that failure mode is
/// gone by construction.
public enum FilterTerm: Hashable, Sendable {
    /// The item carries this tag.
    case tag(UUID)
    /// The item's file sits in exactly this directory (source-relative).
    /// In the web app this was the one term that forced an in-memory pass;
    /// here it compiles to an indexed equality on `folderPath`.
    case folder(String)
    /// The item's file sits in this directory or anywhere below it.
    case subtree(String)
    /// The item has no tags from this category.
    case missingCategory(UUID)
    /// A structural status flag is set.
    case status(StatusFlag)
}

/// The three-way filter: every `required` term must match, at least one
/// `optional` term must match (when any are present), and no `excluded`
/// term may match.
public struct MediaFilter: Hashable, Sendable {
    public var required: [FilterTerm]
    public var optional: [FilterTerm]
    public var excluded: [FilterTerm]

    public init(
        required: [FilterTerm] = [],
        optional: [FilterTerm] = [],
        excluded: [FilterTerm] = []
    ) {
        self.required = required
        self.optional = optional
        self.excluded = excluded
    }

    public var isEmpty: Bool {
        required.isEmpty && optional.isEmpty && excluded.isEmpty
    }

    /// Tag ids referenced anywhere in the filter. A hidden-by-default tag
    /// that is explicitly referenced is exempt from auto-hide suppression.
    public var referencedTagIDs: Set<UUID> {
        var ids: Set<UUID> = []
        for term in required + optional + excluded {
            if case .tag(let id) = term { ids.insert(id) }
        }
        return ids
    }
}

/// How a listing is ordered. Typed — never raw SQL from callers.
///
/// `.fieldValue` is the Phase 1 requirement the old app could not express:
/// its browse sorts stopped at file properties, so ordering a Learning
/// course by a Lesson Number field was impossible. Number fields sort by
/// `numericValue` ("10" after "2"); everything else sorts as NOCASE text.
/// Items without a value for the field sort last; `relativePath` breaks
/// ties so ordering is total and stable.
public enum MediaOrdering: Hashable, Sendable {
    case relativePath
    case fileName
    case fieldValue(UUID, ascending: Bool = true)
}
