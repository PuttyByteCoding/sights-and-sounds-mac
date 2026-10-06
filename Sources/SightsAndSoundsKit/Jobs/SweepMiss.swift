import Foundation
import GRDB

/// Why a sweep could not read a file: the file itself, or what is
/// around it.
///
/// A failure row stops a sweep retrying a broken file until someone
/// presses Retry. A drive that went away mid-sweep, or a file moved while
/// the sweep ran (staged, reorganised), is not a broken file; recording
/// it poisoned every remaining item of that drive until a manual retry.
/// A file that is simply gone from where its row still says it is IS
/// recorded, so the sweep stops trying it.
enum SweepMiss {
    /// Record it.
    case fileFailed
    /// The source's root is gone: skip it and the rest of that source.
    case sourceGone
    /// The row points somewhere else now: skip, the next sweep reads it
    /// where it went.
    case fileMoved
}

extension LibraryDatabase {
    func sweepMiss(for item: MediaItem, source: Source, fileAccess: any FileAccess) async throws -> SweepMiss {
        guard source.isOnline(using: fileAccess) else { return .sourceGone }
        let current = try await read { db in
            try String.fetchOne(
                db, sql: "SELECT relativePath FROM mediaItem WHERE id = ?", arguments: [item.id])
        }
        return current == item.relativePath ? .fileFailed : .fileMoved
    }
}
