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
    /// Which of the three slots a term currently sits in, if any.
    public enum TagSlot: Sendable, CaseIterable {
        case required, optional, excluded
    }

    public func slot(of term: FilterTerm) -> TagSlot? {
        if required.contains(term) { return .required }
        if optional.contains(term) { return .optional }
        if excluded.contains(term) { return .excluded }
        return nil
    }

    public func slot(of tagID: UUID) -> TagSlot? { slot(of: .tag(tagID)) }

    /// Move a term to a slot, or (nil) take it out of the filter. Always
    /// removes it from the other two first, so a term can never occupy
    /// two slots at once.
    public mutating func setSlot(_ slot: TagSlot?, for term: FilterTerm) {
        required.removeAll { $0 == term }
        optional.removeAll { $0 == term }
        excluded.removeAll { $0 == term }
        switch slot {
        case .required: required.append(term)
        case .optional: optional.append(term)
        case .excluded: excluded.append(term)
        case nil: break
        }
    }

    /// The browse panel's click cycle, over all four states:
    /// none → required → optional → excluded → none.
    ///
    /// `reverse` is the right-click, and it is not optional garnish: a
    /// four-state cycle you can only walk forwards is a guessing game
    /// every time you overshoot.
    public mutating func cycle(_ term: FilterTerm, reverse: Bool = false) {
        let order: [TagSlot?] = [nil, .required, .optional, .excluded]
        let current = order.firstIndex(of: slot(of: term)) ?? 0
        let next = (current + (reverse ? order.count - 1 : 1)) % order.count
        setSlot(order[next], for: term)
    }

    public mutating func cycleTag(_ tagID: UUID, reverse: Bool = false) {
        cycle(.tag(tagID), reverse: reverse)
    }

    /// Every live slot, in the order the sidebar sets them — what the
    /// chip bar above the grid lists. Folder terms are excluded: the
    /// tree shows where you are, and a chip removing it would be a
    /// second, competing control over the same state.
    public var slottedTerms: [(term: FilterTerm, slot: TagSlot)] {
        let lists: [(TagSlot, [FilterTerm])] = [
            (.required, required), (.optional, optional), (.excluded, excluded),
        ]
        return lists.flatMap { slot, terms in
            terms.compactMap { term in
                switch term {
                case .folder, .subtree: nil
                default: (term, slot)
                }
            }
        }
    }

    /// Clear the three slots, keeping the folder selection and the
    /// search text — "Clear all" on the chip bar clears the chips.
    public mutating func clearSlots() {
        let folders = required.filter {
            if case .folder = $0 { return true }
            if case .subtree = $0 { return true }
            return false
        }
        required = folders
        optional = []
        excluded = []
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
