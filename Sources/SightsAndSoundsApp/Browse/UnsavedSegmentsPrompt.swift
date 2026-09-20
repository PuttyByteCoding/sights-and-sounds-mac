import SightsAndSoundsKit
import SwiftUI

/// Asked in place of the ordinary purge confirmation when a video on the
/// delete list still has segments nobody has saved as files.
///
/// A segment plays from its video's file, so deleting the video would
/// take its segments with it. The purge itself refuses those videos; this
/// is where the user hears about it *before* anything leaves disk, and
/// can save the segments first.
struct UnsavedSegmentsPrompt: ViewModifier {
    /// Non-nil presents the dialog.
    @Binding var unsaved: [LibraryDatabase.UnsavedSegments]?
    /// How many items in this purge have nothing unsaved and can go now.
    let deletableCount: Int
    let saveSegments: ([UUID]) -> Void
    let deleteTheOthers: () -> Void

    private var videos: [LibraryDatabase.UnsavedSegments] { unsaved ?? [] }
    private var segmentCount: Int { videos.reduce(0) { $0 + $1.segmentIDs.count } }

    private var title: String {
        let videoWord = videos.count == 1 ? "video still has" : "videos still have"
        let segmentWord = segmentCount == 1 ? "segment that is" : "segments that are"
        return "\(videos.count) \(videoWord) \(segmentCount) \(segmentWord) not saved as files"
    }

    func body(content: Content) -> some View {
        content.confirmationDialog(
            title,
            isPresented: Binding(get: { unsaved != nil }, set: { if !$0 { unsaved = nil } })
        ) {
            Button("Save \(segmentCount == 1 ? "the Segment" : "\(segmentCount) Segments") as Files") {
                saveSegments(videos.flatMap(\.segmentIDs))
            }
            if deletableCount > 0 {
                Button("Delete the Other \(deletableCount)", role: .destructive) { deleteTheOthers() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "A segment plays from its video's file, so these videos stay until their segments are saved: "
                    + videos.prefix(5).map(\.parentFileName).joined(separator: ", ")
                    + (videos.count > 5 ? ", and \(videos.count - 5) more" : "")
                    + ". Saving writes each segment to a file of its own beside the video; delete the videos after that.")
        }
    }
}

extension View {
    func unsavedSegmentsPrompt(
        _ unsaved: Binding<[LibraryDatabase.UnsavedSegments]?>, deletableCount: Int,
        saveSegments: @escaping ([UUID]) -> Void, deleteTheOthers: @escaping () -> Void
    ) -> some View {
        modifier(UnsavedSegmentsPrompt(
            unsaved: unsaved, deletableCount: deletableCount,
            saveSegments: saveSegments, deleteTheOthers: deleteTheOthers))
    }
}
