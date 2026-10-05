import Foundation

extension Source {
    /// Where one of this source's items is on disk: the source's folder
    /// and the item's path. A segment's row carries its video's path
    /// (every move of the file brings its segments along), so for a
    /// segment this is the video's file.
    ///
    /// It says where the file would be, not that it is there: whether the
    /// source is enabled and in reach is the caller's to know. And it is
    /// a path on the machine that holds the library — see
    /// `LibraryService.filesAreOnThisMac`.
    public func fileURL(for item: MediaItem) -> URL {
        URL(fileURLWithPath: rootPath, isDirectory: true).appendingPathComponent(item.relativePath)
    }
}
