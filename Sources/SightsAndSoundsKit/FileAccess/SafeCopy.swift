import Foundation

/// Copy a file over a destination that may already exist, without ever
/// losing the existing file: the copy lands beside it first, and only a
/// finished copy replaces it. Deleting the destination first meant a
/// copy that failed (disk full, source drive gone) left nothing at all.
public enum SafeCopy {
    public static func copy(from source: URL, to destination: URL) throws {
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).partial")
        do {
            try FileManager.default.copyItem(at: source, to: staging)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
            } else {
                try FileManager.default.moveItem(at: staging, to: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }
}
