import Foundation
import GRDB

/// Why a folder was not registered as a source.
public enum SourceError: Error, Equatable, CustomStringConvertible {
    /// The folder is already a source, or lies inside one, or holds one.
    case overlaps(existing: String, relation: Relation)

    public enum Relation: Equatable, Sendable { case same, inside, contains }

    public var description: String {
        switch self {
        case .overlaps(let existing, .same):
            "this folder is already the source “\(existing)”"
        case .overlaps(let existing, .inside):
            "this folder is inside the source “\(existing)” — scan that source to pick up its new files"
        case .overlaps(let existing, .contains):
            "this folder holds the source “\(existing)”; two sources cannot share files"
        }
    }
}

extension LibraryDatabase {
    /// Register a folder as a source — once. A folder is one source: the
    /// table has no uniqueness on its path, and the same folder added twice
    /// made every file "new" to the second (the scan's known set is per
    /// source), so the import inserted a second row per file, with no
    /// un-import. A folder inside a source, or holding one, is refused for
    /// the same reason: two sources cannot share files.
    @discardableResult
    public func addSource(named name: String, rootPath: String) throws -> Source {
        let path = Self.canonicalRoot(rootPath)
        let existing = try writer.read { try Source.fetchAll($0) }
        for other in existing {
            let otherPath = Self.canonicalRoot(other.rootPath)
            if otherPath == path {
                throw SourceError.overlaps(existing: other.name, relation: .same)
            }
            if path.hasPrefix(otherPath + "/") {
                throw SourceError.overlaps(existing: other.name, relation: .inside)
            }
            if otherPath.hasPrefix(path + "/") {
                throw SourceError.overlaps(existing: other.name, relation: .contains)
            }
        }
        let source = Source(name: name, rootPath: path)
        try writer.write { try source.insert($0) }
        return source
    }

    /// One spelling per folder: resolved `.` and `..`, no trailing slash.
    /// Symlinks are not followed — a volume may be unmounted when this
    /// runs, and the stored path should be the one the user chose.
    static func canonicalRoot(_ rootPath: String) -> String {
        let standardized = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL.path
        return standardized.count > 1 && standardized.hasSuffix("/")
            ? String(standardized.dropLast()) : standardized
    }
}
