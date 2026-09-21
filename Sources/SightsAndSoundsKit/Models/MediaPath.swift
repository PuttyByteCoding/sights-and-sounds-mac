import Foundation

/// Canonical path handling for source-relative media paths.
///
/// Stored paths always use forward slashes, no leading or trailing slash, and
/// no empty segments. Every write path goes through `normalize` (the old app
/// did the same at import via `PathNormalizer`), so equality and prefix tests
/// against stored paths never need per-query normalization.
public enum MediaPath {
    /// Canonicalize a relative path: backslashes → `/`, collapse duplicate
    /// separators, strip leading/trailing separators and `./` segments.
    ///
    /// `..` segments are dropped, not followed. A stored path is always
    /// inside its source; one that climbs out of it is never something to
    /// honour, wherever the text came from (a template, a segment's name,
    /// an imported list).
    public static func normalize(_ path: String) -> String {
        let unified = path.replacingOccurrences(of: "\\", with: "/")
        let segments = unified
            .split(separator: "/", omittingEmptySubsequences: true)
            .filter { $0 != "." && $0 != ".." }
        return segments.joined(separator: "/")
    }

    /// The directory portion of a normalized relative path ("" for a file at
    /// the root). Stored denormalized on `MediaItem.folderPath` so the exact
    /// folder filter is a plain indexed equality — the one term the old app
    /// could not push into SQL.
    public static func folder(of normalizedPath: String) -> String {
        guard let idx = normalizedPath.lastIndex(of: "/") else { return "" }
        return String(normalizedPath[..<idx])
    }

    /// Where Remux and Repair keep the original they replaced. Machinery
    /// like the staging folders, with one difference: its files have no
    /// rows, on purpose.
    public static let archiveFolder = "_Replaced"

    /// True for a path under the source's top-level archive folder.
    /// Every surface that walks a source's disk asks this — the scan, the
    /// import and validation — so an archived original is never offered
    /// back as a new item or reported as an orphan. Compared without case,
    /// like every stored path.
    public static func isArchived(_ normalizedPath: String) -> Bool {
        let first = normalizedPath.prefix { $0 != "/" }
        return first.count < normalizedPath.count
            && first.caseInsensitiveCompare(archiveFolder) == .orderedSame
    }

    /// The file-name portion of a normalized relative path.
    public static func fileName(of normalizedPath: String) -> String {
        guard let idx = normalizedPath.lastIndex(of: "/") else { return normalizedPath }
        return String(normalizedPath[normalizedPath.index(after: idx)...])
    }
}
