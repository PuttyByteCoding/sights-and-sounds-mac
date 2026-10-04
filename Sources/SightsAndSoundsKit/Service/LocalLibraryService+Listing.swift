import Foundation
import GRDB

// MARK: - BrowseListing

extension LocalLibraryService {
    public func listing(_ request: ListingRequest) async throws -> BrowseListingAnswer {
        let filter = request.filter, kinds = request.kinds
        // Timed because how the grid should react to a filter change
        // depends on how long the query actually takes, and that is a
        // fact about a real library rather than a guess. Debug level:
        // it is diagnostic, and the Log window can filter to it.
        let started = ContinuousClock.now
        let rows = try library.mediaItems(matching: filter, kinds: kinds, orderedBy: request.ordering)
        // Both components: `attoseconds` carries only the sub-second
        // remainder, so seconds must be added or a 1.5s query reports as
        // 500ms — the exact case worth knowing about.
        let took = started.duration(to: .now).components
        let elapsed = Double(took.seconds) * 1000 + Double(took.attoseconds) / 1e15
        AppLog.shared.debug(
            "browse", "listing query \(String(format: "%.1f", elapsed))ms — \(rows.count) items")

        var answer = BrowseListingAnswer(
            items: rows,
            // Faceted counts ride along with the listing they describe,
            // so the numbers and the grid can never be from different
            // filters.
            filteredTagCounts: try library.filteredTagCounts(kinds: kinds, filter: filter),
            filteredMissingCounts: try library.filteredMissingCategoryCounts(kinds: kinds, filter: filter),
            menuFacts: try await tileMenuFacts(snapshotsPerItem: request.snapshotsPerItem))

        if request.includesTagData {
            let vocabulary = try library.vocabulary().filter { !$0.category.hiddenFromBrowse }
            // Category order decides pill order, so a tile reads
            // Band · Venue · Year the way the sidebar lists them.
            var categoryRank: [UUID: Int] = [:]
            var tagInfo: [UUID: TagPill] = [:]
            for (rank, entry) in vocabulary.enumerated() {
                categoryRank[entry.category.id] = rank
                for tag in entry.tags {
                    tagInfo[tag.id] = TagPill(
                        id: tag.id, name: tag.name, categoryID: entry.category.id,
                        categoryName: entry.category.name, colorIndex: entry.category.colorIndex)
                }
            }
            // The ids leave the closure, never the rows: `Row` is not
            // Sendable, and Swift 6.4 resolves a read inside an async
            // context to the async overload. The explicit closure type
            // keeps the older CI toolchain's inference unambiguous.
            let links = try await library.writer.read { db -> [(item: UUID, tag: UUID)] in
                try Row.fetchAll(db, sql: "SELECT mediaItemID, tagID FROM mediaItemTag")
                    .map { (item: $0["mediaItemID"], tag: $0["tagID"]) }
            }
            var tagsByItem: [UUID: [UUID]] = [:]
            for link in links {
                tagsByItem[link.item, default: []].append(link.tag)
            }
            for item in rows {
                let tagIDs = tagsByItem[item.id] ?? []
                answer.tags[item.id] = tagIDs
                    .compactMap { tagInfo[$0] }
                    .sorted {
                        (categoryRank[$0.categoryID] ?? 0, $0.name)
                            < (categoryRank[$1.categoryID] ?? 0, $1.name)
                    }
                let covered = Set(tagIDs.compactMap { tagInfo[$0]?.categoryID })
                answer.missingCategories[item.id] = vocabulary
                    .filter { !covered.contains($0.category.id) }
                    .map(\.category.name)
            }
        }
        if request.includesDuplicateData {
            answer.duplicateIDs = Set(
                try library.pendingCandidates().flatMap { [$0.itemAID, $0.itemBID] })
        }
        return answer
    }
}
