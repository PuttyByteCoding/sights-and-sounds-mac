import SightsAndSoundsKit

/// What the Import window's rail has chosen: the folders in scope, whose
/// files the table shows; the files ticked for import; and the focused
/// folder, whose words are offered as tag suggestions.
///
/// Clicking a folder's name makes it the scope, on its own. The flow is
/// one folder at a time — pick a folder, stage its tags, import it, pick
/// the next — and the click used to tick the folder only while nothing
/// else was ticked: with one folder in scope, a click on another
/// highlighted it and the table went on showing the first folder's
/// files. The tick box is for the other case, several folders in one
/// import: it adds a folder to the scope, or takes it out.
struct ImportFolderSelection: Equatable {
    /// The folders whose files the table shows.
    private(set) var checked: Set<String> = []
    /// The files Import will take.
    private(set) var paths: Set<String> = []
    var focused: String?

    init(focused: String? = nil) {
        self.focused = focused
    }

    /// This folder, alone: its new files are what the table shows and
    /// what Import would take. A folder with nothing new is still shown —
    /// its known files are the answer to "is this one in yet?"
    mutating func click(_ folder: String, in outcome: ScanOutcome) {
        focused = folder
        checked = [folder]
        paths = outcome.newPaths(under: folder)
    }

    /// Add a folder to the scope, subfolders included, or take it out.
    mutating func toggle(_ folder: String, in outcome: ScanOutcome) {
        if checked.contains(folder) {
            checked.remove(folder)
            paths.subtract(outcome.candidates
                .filter { ScanOutcome.isUnder($0.folderPath, folder) }.map(\.relativePath))
        } else {
            checked.insert(folder)
            paths.formUnion(outcome.newPaths(under: folder))
        }
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
    /// first — with the first folder focused for its suggestions.
    mutating func reset(focusing folder: String?) {
        self = ImportFolderSelection(focused: folder)
    }
}
