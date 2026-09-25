import Foundation
import SightsAndSoundsKit

/// The tags, across every category, that a typed query finds.
///
/// Pure, so the rule is tested without a window: name or alias contains
/// the query under the one fold every tag search uses (case, accents and
/// punctuation set aside); a tag with an active filter slot is
/// always found, so a filter can never hide behind a search; categories
/// come back in vocabulary order, empty ones left out; and the whole
/// result is capped, since a one-letter query over thousands of tags is
/// not a list anyone will read.
enum SidebarTagSearch {
    static let limit = 80

    static func matches(
        _ query: String, in vocabulary: [CategoryTags], aliases: [UUID: [String]],
        isSlotted: (UUID) -> Bool
    ) -> [CategoryTags] {
        let query = TagSearchEntry.fold(query).trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        var budget = limit
        var found: [CategoryTags] = []
        for entry in vocabulary where budget > 0 {
            let tags = entry.tags.filter { tag in
                isSlotted(tag.id)
                    || TagSearchEntry.fold(tag.name).contains(query)
                    || (aliases[tag.id] ?? []).contains { TagSearchEntry.fold($0).contains(query) }
            }
            guard !tags.isEmpty else { continue }
            let kept = Array(tags.prefix(budget))
            budget -= kept.count
            found.append(CategoryTags(category: entry.category, tags: kept))
        }
        return found
    }
}
