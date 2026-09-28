import Foundation

/// Which files on the delete list are ticked — the purge's selection.
///
/// A file is ticked when it first shows up on the list (it is there
/// because it was already marked), and from then on only the operator
/// changes it. A reload never re-ticks a file that was unticked: the
/// old rule ticked everything whenever the set happened to be empty,
/// so "Restore selected" on the ticked files turned every file held
/// back into the next "Delete N files".
struct DeleteListTicks {
    private(set) var ticked: Set<UUID> = []
    /// The list as last loaded — what counts as "already seen".
    private var listed: Set<UUID> = []

    mutating func listLoaded(_ ids: [UUID]) {
        let now = Set(ids)
        ticked = ticked.intersection(now).union(now.subtracting(listed))
        listed = now
    }

    mutating func toggle(_ id: UUID) {
        if ticked.remove(id) == nil { ticked.insert(id) }
    }

    mutating func untick(_ id: UUID) { ticked.remove(id) }

    mutating func clear() { ticked = [] }
}
