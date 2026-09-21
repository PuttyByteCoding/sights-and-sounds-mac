import Foundation

public enum FileReplacementError: Error, CustomStringConvertible, Equatable {
    /// The name the result would take belongs to another file.
    case targetExists(String)
    /// The result could not be moved into place; the original is back
    /// where it was.
    case landingFailed(reason: String)
    /// The result could not be moved into place and neither could the
    /// original: it is safe, in the archive, at this path.
    case originalLeftInArchive(archive: String, reason: String)

    public var description: String {
        switch self {
        case .targetExists(let path):
            "another file is already at \(path) — nothing was changed"
        case .landingFailed(let reason):
            "the new file could not be moved into place (\(reason)) — the original was put back"
        case .originalLeftInArchive(let archive, let reason):
            "the new file could not be moved into place (\(reason)), and the original could not be put back: it is at \(archive)"
        }
    }
}

/// Swapping an item's file for a new one — what Remux and Repair both do
/// once their result is verified.
///
/// Between archiving the original and landing the result the item has no
/// file. So: whatever can be known to fail is checked before the first
/// move, the working file lives on the item's own volume so the landing
/// is a rename rather than a copy that can run out of space halfway, and
/// a landing that fails anyway puts the original back.
extension LibraryDatabase {
    /// A scratch location on the same volume as `fileURL`, inside a
    /// directory the system provides for exactly this. Remove the
    /// directory when done. The system temp directory is on the boot
    /// volume: for a library on an external drive that made the final
    /// move a cross-volume copy, and a long remux had to fit on the boot
    /// disk first.
    static func workingURL(toReplace fileURL: URL, fileExtension: String) throws -> URL {
        let directory = try FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask,
            appropriateFor: fileURL, create: true)
        return directory.appendingPathComponent("working.\(fileExtension)")
    }

    /// Archive `currentRelative` under the archive folder and move
    /// `replacement` to `newRelative`. Returns the archive's relative path.
    /// Where `currentRelative` would be archived: under the archive
    /// folder, stamped if that name is already taken there.
    static func archivePath(for currentRelative: String, under root: URL, fileAccess: any FileAccess) -> String {
        let plain = "\(MediaPath.archiveFolder)/\(currentRelative)"
        guard fileAccess.isReachable(root.appendingPathComponent(plain)) else { return plain }
        let ext = (plain as NSString).pathExtension
        let base = (plain as NSString).deletingPathExtension
        return ext.isEmpty ? "\(base)-\(collisionStamp())" : "\(base)-\(collisionStamp()).\(ext)"
    }

    @discardableResult
    static func replaceFile(
        under root: URL, currentRelative: String, newRelative: String,
        with replacement: URL, archiveRelative: String? = nil, fileAccess: any FileAccess
    ) throws -> String {
        let currentURL = root.appendingPathComponent(currentRelative)
        let newURL = root.appendingPathComponent(newRelative)
        // A renamed result (x.mkv → x.mp4) must not meet a file that is
        // already called that. Same name, compared like the stored paths
        // and the volume do, is the file being replaced.
        if currentRelative.caseInsensitiveCompare(newRelative) != .orderedSame,
           fileAccess.isReachable(newURL) {
            throw FileReplacementError.targetExists(newRelative)
        }

        let archiveRelative = archiveRelative
            ?? archivePath(for: currentRelative, under: root, fileAccess: fileAccess)
        let archiveURL = root.appendingPathComponent(archiveRelative)

        try moveWithRetries(fileAccess: fileAccess, from: currentURL, to: archiveURL)
        do {
            try moveWithRetries(fileAccess: fileAccess, from: replacement, to: newURL)
        } catch {
            let reason = "\(error)"
            do {
                try fileAccess.moveFile(at: archiveURL, to: currentURL)
            } catch {
                throw FileReplacementError.originalLeftInArchive(archive: archiveRelative, reason: reason)
            }
            throw FileReplacementError.landingFailed(reason: reason)
        }
        return archiveRelative
    }
}
