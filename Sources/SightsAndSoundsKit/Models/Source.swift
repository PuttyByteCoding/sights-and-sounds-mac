import Foundation
import GRDB

/// Where a source's files physically live.
public enum SourceKind: String, Codable, Sendable, CaseIterable {
    case internalDrive = "internal"
    case externalDrive = "external"
    case network
}

/// A folder that contributes media to exactly one library.
///
/// Ownership is a real foreign key (`MediaItem.sourceID`), never a path
/// prefix — the old model's string-prefix ownership rippled into every
/// operation and was eventually deleted. Item paths stay source-relative
/// (the good half of the old design), so relocating a source updates one
/// row.
///
/// A source is a folder, not a volume: one drive can host sources for
/// several libraries at different paths.
public struct Source: Codable, Equatable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "source"

    public var id: UUID
    public var name: String
    /// Absolute path of the source's root folder.
    public var rootPath: String
    public var kind: SourceKind
    /// User off-switch. A disabled source's items leave every listing;
    /// distinct from *offline*, which is observed, never stored.
    public var enabled: Bool
    /// Last time the root was observed reachable.
    public var lastSeenAt: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        rootPath: String,
        kind: SourceKind = .internalDrive,
        enabled: Bool = true,
        lastSeenAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.kind = kind
        self.enabled = enabled
        self.lastSeenAt = lastSeenAt
    }

    /// Whether the source is reachable right now. Online-ness is observed
    /// state — there is no column for it. Mount/unmount notifications drive
    /// UI transitions later (Phase 5); this is the ground-truth check.
    public func isOnline(using fileAccess: any FileAccess) -> Bool {
        fileAccess.isReachable(URL(fileURLWithPath: rootPath, isDirectory: true))
    }
}
