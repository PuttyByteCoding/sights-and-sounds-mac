import SightsAndSoundsKit

/// What the Import window's rail has chosen: the folders in scope, whose
/// files the table shows, and the files ticked for import.
///
/// Several folders go into one import. Clicking a folder's name, or its
/// tick box, adds it to the scope and clicking again takes it out; Clear
/// empties it. A click used to replace the scope with that one folder,
/// so only the small tick box could add a second, and the tree read as
/// one folder at a time.
struct ImportFolderSelection: Equatable {
    /// The folders whose files the table shows.
    private(set) var checked: Set<String> = []
    /// The files Import will take.
    private(set) var paths: Set<String> = []
    /// In or out of the scope, subfolders included. A folder with nothing
    /// new is still shown, since its known files are the answer to "is
    /// this one in yet?"
    mutating func click(_ folder: String, in outcome: ScanOutcome) {
        if checked.contains(folder) {
            checked.remove(folder)
            // What another folder still in the scope covers stays, and so
            // does a file unticked by hand: only what nothing covers goes.
            let covered = checked.reduce(into: Set<String>()) { $0.formUnion(outcome.newPaths(under: $1)) }
            paths.formIntersection(covered)
        } else {
            checked.insert(folder)
            paths.formUnion(outcome.newPaths(under: folder))
        }
    }

    /// Nothing in scope, nothing selected.
    mutating func clear() {
        checked = []
        paths = []
    }

    mutating func toggleFile(_ path: String) {
        if paths.contains(path) { paths.remove(path) } else { paths.insert(path) }
    }

    /// After an import landed: what went in is out of the selection, and
    /// a folder with nothing new left leaves the scope. A folder ticked
    /// for the next import while this one ran is kept.
    mutating func afterImport(_ imported: Set<String>, updated: ScanOutcome) {
        paths.subtract(imported)
        checked = checked.filter { !updated.newPaths(under: $0).isEmpty }
    }

    /// A fresh scan: nothing in scope, nothing selected — pick a folder
    /// first.
    mutating func reset() {
        self = ImportFolderSelection()
    }
}
