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
