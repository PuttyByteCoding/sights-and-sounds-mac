import Foundation

/// What the Browse window asks its library to change. The library's
/// rules are applied where the library is: a single-select category
/// replaces, an overlapping source is refused, a staged file is moved
/// with its paper trail.
public protocol BrowseWriting: Sendable {
    /// The name is a label only. Trimmed; an empty one is refused.
    func renameSource(_ id: UUID, to name: String) async throws
    func setSourceEnabled(_ id: UUID, _ enabled: Bool) async throws
    /// Register a folder as a source. Refused when it already is one, or
    /// lies inside one, or holds one.
    func addSource(named name: String, rootPath: String) async throws -> Source

    @discardableResult
    func saveFilter(named name: String, _ filter: MediaFilter) async throws -> SavedFilter
    func updateSavedFilter(_ id: UUID, to filter: MediaFilter) async throws
    func renameSavedFilter(_ id: UUID, to name: String) async throws
    func deleteSavedFilter(_ id: UUID) async throws

    /// One transaction: the bulk edit lands whole or not at all.
    func assignTag(_ tagID: UUID, to itemIDs: [UUID]) async throws
    func removeTag(_ tagID: UUID, from itemIDs: [UUID]) async throws
    func setFavorite(_ itemIDs: [UUID], _ isFavorite: Bool) async throws
    func setNeedsReview(_ itemIDs: [UUID], _ needsReview: Bool) async throws

    /// Flag each item and move its file into the staging folder, or
    /// clear the flag and move it back. Returns the items that could not
    /// be staged, each with why, and stages the others.
    func setStaging(
        _ folder: StagingFolder, on: Bool, itemIDs: [UUID]
    ) async throws -> [StagingFailure]
}

/// One item a staging request could not carry out. The caller names it:
/// it is the one that knows what the item was called on screen, which an
/// item removed since has no other record of.
public struct StagingFailure: Codable, Equatable, Sendable {
    public var itemID: UUID
    public var reason: String

    public init(itemID: UUID, reason: String) {
        self.itemID = itemID
        self.reason = reason
    }
}

/// What a service refuses that no model type already has an error for.
public enum ServiceError: Error, Equatable, Sendable, CustomStringConvertible {
    case emptyName

    public var description: String {
        switch self {
        case .emptyName: "a name cannot be empty"
        }
    }
}
