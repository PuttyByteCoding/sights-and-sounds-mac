import Foundation

/// One node of the browse sidebar's folder tree. `path` is the full
/// source-relative folder path ("" = the library root); `directCount` is
/// the number of visible items whose files sit directly in this folder.
public struct FolderNode: Identifiable, Sendable, Equatable {
    public var id: String { path }
    public let path: String
    public let name: String
    public var directCount: Int
    public var children: [FolderNode]

    /// Items in this folder and everything below it.
    public var subtreeCount: Int {
        directCount + children.reduce(0) { $0 + $1.subtreeCount }
    }

    public init(path: String, name: String, directCount: Int = 0, children: [FolderNode] = []) {
        self.path = path
        self.name = name
        self.directCount = directCount
        self.children = children
    }
}

/// Builds the nested folder tree from flat `(folderPath, count)` rows —
/// including intermediate folders that hold no files directly.
public enum FolderTreeBuilder {
    public static func build(from folderCounts: [(path: String, count: Int)]) -> [FolderNode] {
        // Path → direct count, plus every ancestor with an implicit 0.
        var counts: [String: Int] = [:]
        for row in folderCounts {
            counts[row.path, default: 0] += row.count
            var parent = MediaPath.folder(of: row.path)
            while !parent.isEmpty, counts[parent] == nil {
                counts[parent] = 0
                parent = MediaPath.folder(of: parent)
            }
        }

        func children(of parent: String) -> [FolderNode] {
            let prefix = parent.isEmpty ? "" : parent + "/"
            return counts.keys
                .filter { path in
                    !path.isEmpty
                        && path.hasPrefix(prefix)
                        && !path.dropFirst(prefix.count).contains("/")
                }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .map { path in
                    FolderNode(
                        path: path,
                        name: MediaPath.fileName(of: path),
                        directCount: counts[path] ?? 0,
                        children: children(of: path))
                }
        }
        return children(of: "")
    }
}

extension MediaFilter {
    /// The tag's current slot in this filter, if any.
    public enum TagSlot: Sendable { case required, optional, excluded }

    public func slot(of tagID: UUID) -> TagSlot? {
        if required.contains(.tag(tagID)) { return .required }
        if optional.contains(.tag(tagID)) { return .optional }
        if excluded.contains(.tag(tagID)) { return .excluded }
        return nil
    }

    /// The browse panel's click cycle for a tag:
    /// none → required → excluded → none.
    public mutating func cycleTag(_ tagID: UUID) {
        switch slot(of: tagID) {
        case nil:
            required.append(.tag(tagID))
        case .required:
            required.removeAll { $0 == .tag(tagID) }
            excluded.append(.tag(tagID))
        case .optional:
            optional.removeAll { $0 == .tag(tagID) }
            excluded.append(.tag(tagID))
        case .excluded:
            excluded.removeAll { $0 == .tag(tagID) }
        }
    }

    /// Toggle a status-flag requirement on or off.
    public mutating func toggleStatus(_ flag: StatusFlag) {
        if required.contains(.status(flag)) {
            required.removeAll { $0 == .status(flag) }
        } else {
            required.append(.status(flag))
        }
    }

    /// Replace any folder/subtree term with the given subtree selection
    /// (nil clears it) — the sidebar's tree is single-selection navigation,
    /// mirroring the old app's "the Sources tree replaces any previous
    /// folder term".
    public mutating func selectSubtree(_ path: String?) {
        required.removeAll {
            if case .folder = $0 { return true }
            if case .subtree = $0 { return true }
            return false
        }
        if let path { required.append(.subtree(path)) }
    }
}
