import Foundation
import GRDB

// MARK: - PlayerReading

extension LocalLibraryService {
    public func playable(itemID: UUID) async throws -> Playable {
        let item = try await library.writer.read { try MediaItem.fetchOne($0, key: itemID) }
        // Embedded clips resolve to the PARENT's file. The lookup touches
        // the filesystem, which is why it is here and not on the main
        // actor: a slow volume used to hitch the UI on every item switch.
        let url = try item.flatMap { try library.resolvedFileURL(for: $0, fileAccess: fileAccess) }
        return Playable(item: item, url: url)
    }

    public func opened(itemID: UUID) async throws -> OpenedItem {
        let playable = try await playable(itemID: itemID)
        guard let item = playable.item else {
            return OpenedItem(playable: playable, tagging: nil, segments: nil)
        }
        return OpenedItem(
            playable: playable,
            tagging: try await tagging(itemID: item.id),
            segments: try await segments(parentID: item.parentMediaItemID ?? item.id))
    }

    public func itemTags(itemID: UUID) async throws -> [CategoryTags] {
        try library.tags(of: itemID).map { CategoryTags(category: $0.category, tags: $0.tags) }
    }

    public func tagging(itemID: UUID) async throws -> PlayerTagging {
        PlayerTagging(
            itemTags: try await itemTags(itemID: itemID),
            vocabulary: try library.vocabulary().map { CategoryTags(category: $0.category, tags: $0.tags) },
            // An alias IS a name, so typing "SBD" must offer "Soundboard".
            aliases: Dictionary(
                grouping: try await library.writer.read { try TagAlias.fetchAll($0) },
                by: \.tagID
            ).mapValues { $0.map(\.alias) },
            keyBindings: try library.keyBindings())
    }

    public func segments(parentID: UUID) async throws -> PlayerSegments {
        PlayerSegments(
            clips: try library.clips(of: parentID),
            hideBlocks: try library.blocks(of: parentID).filter { $0.kind == .hide })
    }

    public func searchContext(itemID: UUID) async throws -> SearchContext {
        SearchContext(
            formats: try library.searchFormats(),
            subject: try library.searchSubject(for: itemID))
    }

    public func recentlyWatched(limit: Int) async throws -> [MediaItem] {
        try library.recentlyWatched(limit: limit)
    }

    public func items(ids: [UUID]) async throws -> [MediaItem] {
        try library.items(ids: ids)
    }

    public func queueItems(_ definition: QueueDefinition) async throws -> [MediaItem] {
        try library.queueItems(definition)
    }

    public func tagMembership(itemIDs: [UUID]) async throws -> [UUID: Set<UUID>] {
        try library.tagIDsByItem(forItems: itemIDs)
    }

    public func pendingTextScan(itemID: UUID) async throws -> UUID? {
        try library.pendingOcrScan(of: itemID)
    }

    public func textLines(itemID: UUID) async throws -> [OcrTextLine] {
        // Explicit return type — the async `read` overload's inference
        // is ambiguous to the CI toolchain (Xcode 16).
        try await library.writer.read { db -> [OcrTextLine] in
            try OcrTextLine
                .filter(sql: "mediaItemID = ?", arguments: [itemID])
                .order(sql: "timeSeconds")
                .fetchAll(db)
        }
    }
}
