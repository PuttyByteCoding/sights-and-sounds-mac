import Foundation

/// Everything a window asks of a library, and everything it asks the
/// library to do.
///
/// A window is given a service, never the database: the library may be a
/// file on this Mac (`LocalLibraryService`) or one that another Mac holds
/// and answers for. So every operation is asynchronous, can fail, and
/// takes and returns plain values that survive being encoded — no GRDB
/// type crosses this boundary.
///
/// The operations are grouped by who needs them, one protocol per group;
/// the groups arrive as the windows move onto the service.
///
/// See docs/superpowers/specs/2026-10-03-remote-library-design.md.
public protocol LibraryService: BrowseReading, BrowseListing, BrowseWriting, JobRequesting, PlayerReading,
    PlayerWriting, TagManaging, VocabularyManaging, SupportingReading, ReviewManaging, MaintenanceManaging
{
    /// Whether the library's files are on this Mac. When they are, a
    /// source's folder and an item's path name a file the Finder can be
    /// shown, a drag can carry and Quick Look can open. When the library
    /// is held by another Mac those paths are that Mac's, and none of
    /// that is offered; an item is still played, and its thumbnail made,
    /// from the URL `playable(itemID:)` gives.
    var filesAreOnThisMac: Bool { get }

    /// What changed in the library, whoever wrote it. The subscription is
    /// made when the stream is, and ends when the stream is let go of.
    func changes() -> AsyncStream<LibraryChange>
}
