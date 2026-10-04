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
public protocol LibraryService: BrowseReading, BrowseListing, BrowseWriting {
    /// What changed in the library, whoever wrote it. The subscription is
    /// made when the stream is, and ends when the stream is let go of.
    func changes() -> AsyncStream<LibraryChange>
}
