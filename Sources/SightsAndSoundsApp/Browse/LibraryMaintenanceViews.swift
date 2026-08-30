import SwiftUI
import SightsAndSoundsKit

/// Purging moved into the Review window, where the marked files can
/// actually be seen. A count in a confirmation dialog was not
/// reviewable: you could not tell what the 47 items were, and the mark
/// could be four months old.
struct PurgeButton: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(BrowseModel.self) private var model

    var body: some View {
        Button("Review Marked Items…", systemImage: "trash") {
            openWindow(
                id: "aux", value: AuxWindowRequest(libraryID: model.libraryID, kind: .review))
        }
        .help("The delete list, with each file, why it is there, and what it reclaims")
    }
}
