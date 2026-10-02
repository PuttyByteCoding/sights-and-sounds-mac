import Foundation
import GRDB

/// One file the scan found, classified but **not probed**.
///
/// Size comes free from the enumeration; duration and resolution do not —
/// `MediaProbe.probe` per file is most of what makes an import slow, so
/// probing four thousand candidates up front would make the scan cost as
/// much as the import it exists to precede. The window probes the rows on
/// screen and shows `—` until they resolve; the insert probes for real.
public struct ScanCandidate: Sendable, Equatable, Identifiable {
    public var relativePath: String
    public var folderPath: String
    public var fileName: String
    public var fileExtension: String
    public var kind: MediaKind
    public var fileSize: Int64
    /// Already in the library — shown, and unselectable. Seeing that a
    /// folder is 19-of-23 known IS the information; hiding the known
    /// rows makes a partial re-scan look empty.
    public var isKnown: Bool
    /// Removed from the library on purpose, file left in place. Shown as
    /// such, not ticked by default, and importable again.
    public var isRemoved: Bool

    /// Neither in the library nor removed from it: what a scan is for.
    public var isNew: Bool { !isKnown && !isRemoved }

    public var id: String { relativePath }
}

/// What one scan found, and what it deliberately did not list.
public struct ScanOutcome: Sendable, Equatable {
    public var candidates: [ScanCandidate]
    /// Extensions seen under the root that no enabled list claims, with
    /// counts. Free during enumeration, and it answers the question the
    /// file list provokes: why are there 38 files in this folder and 36
    /// here?
    public var skippedByExtension: [String: Int]
    public var scannedAt: Date

    public var newCount: Int { candidates.count(where: \.isNew) }
    public var knownCount: Int { candidates.count { $0.isKnown } }
    public var removedCount: Int { candidates.count { $0.isRemoved } }

    /// One folder of the source, with its subfolders, counted over the
    /// whole subtree: ticking a folder imports what is under it.
    public struct FolderNode: Equatable, Sendable, Identifiable {
        public var path: String
        public var name: String
        public var new: Int
        public var known: Int
        public var removed: Int
        public var children: [FolderNode]
        public var id: String { path }
    }

    /// The source's folders as a tree — the Update flow's rail. With
    /// `newOnly`, only folders holding something new, so a drive that is
    /// mostly imported shows just what is left to do.
    public func folderTree(newOnly: Bool) -> [FolderNode] {
        var byPath: [String: FolderNode] = [:]
        func node(_ path: String) -> FolderNode {
            byPath[path] ?? FolderNode(
                path: path, name: path.isEmpty ? "(root)" : MediaPath.fileName(of: path),
                new: 0, known: 0, removed: 0, children: [])
        }
        for candidate in candidates {
            // Each ancestor counts the file, the root folder included.
            var folder = candidate.folderPath
            while true {
                var n = node(folder)
                if candidate.isNew { n.new += 1 } else if candidate.isKnown { n.known += 1 } else { n.removed += 1 }
                byPath[folder] = n
                guard !folder.isEmpty else { break }
                folder = MediaPath.folder(of: folder)
                if folder.isEmpty { break }
            }
        }
        func children(of parent: String) -> [FolderNode] {
            byPath.values
                .filter { $0.path != parent && MediaPath.folder(of: $0.path) == parent && !$0.path.isEmpty }
                .filter { !newOnly || $0.new > 0 }
                .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                .map { var n = $0; n.children = children(of: $0.path); return n }
        }
        var top = children(of: "")
        if let root = byPath[""], !newOnly || root.new > 0 {
            var rootNode = root
            rootNode.children = []
            top.insert(rootNode, at: 0)
        }
        return top
    }

    /// The new files in a folder and its subfolders — what ticking the
    /// folder selects. The root folder means its own files only.
    public func newPaths(under folder: String) -> Set<String> {
        Set(candidates.filter { $0.isNew && Self.isUnder($0.folderPath, folder) }.map(\.relativePath))
    }

    public static func isUnder(_ folderPath: String, _ folder: String) -> Bool {
        folder.isEmpty ? folderPath.isEmpty : (folderPath == folder || folderPath.hasPrefix(folder + "/"))
    }

    /// The scan with these files now in the library — what the window
    /// shows once an import lands, in place of a rescan that threw away
    /// every tick and staged value. Paths compare without case, as the
    /// library's do.
    public func markingKnown(_ paths: Set<String>) -> ScanOutcome {
        let folded = Set(paths.map { $0.lowercased() })
        var copy = self
        for index in copy.candidates.indices where folded.contains(copy.candidates[index].relativePath.lowercased()) {
            copy.candidates[index].isKnown = true
            copy.candidates[index].isRemoved = false
        }
        return copy
    }

    /// Folders in the scan, with their new/known split — the scope rail.
    /// A removed file counts as neither.
    public func folders() -> [(path: String, new: Int, known: Int)] {
        Dictionary(grouping: candidates, by: \.folderPath)
            .map { path, rows in
                (path, rows.count(where: \.isNew), rows.count { $0.isKnown })
            }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}

/// Enumeration and classification, with nothing written.
///
/// This is the half of the old one-pass import that produces a *list*.
/// The other half — inserting a named list — stays `ImportJob`, where the
/// idempotence guard belongs: the scan classifies each row, but the disk
/// is not the snapshot, so the write re-checks.
public enum MediaScanner {
    public static func scan(
        source: Source,
        library: LibraryDatabase,
        fileAccess: any FileAccess = LiveFileAccess()
    ) async throws -> ScanOutcome {
        guard source.enabled else { throw ImportError.sourceDisabled(source.name) }
        let root = URL(fileURLWithPath: source.rootPath, isDirectory: true)
        guard source.isOnline(using: fileAccess) else {
            throw ImportError.sourceOffline(source.name)
        }

        // Effective extension sets: the library's override replaces the
        // app-wide lists; absent, it inherits them. Resolved once per run.
        let info = try await library.writer.read { try LibraryInfo.fetchOne($0) }
        let appSettings = AppSettingsStore.shared.current
        let videoSet = info?.effectiveVideoExtensions(appWide: appSettings.videoExtensions)
            ?? MediaProbe.videoExtensions
        let audioSet = info?.effectiveAudioExtensions(appWide: appSettings.audioExtensions)
            ?? MediaProbe.audioExtensions

        let existing = try await library.writer.read { db in
            Set(try String.fetchAll(
                db, sql: "SELECT relativePath FROM mediaItem WHERE sourceID = ?",
                arguments: [source.id]
            ).map { $0.lowercased() })
        }

        let removed = try library.removedPaths(in: source.id)

        let rootPath = root.standardizedFileURL.path
        var candidates: [ScanCandidate] = []
        var skipped: [String: Int] = [:]

        for url in try fileAccess.allFiles(under: root) {
            try Task.checkCancellation()
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(rootPath + "/") else { continue }
            let relative = MediaPath.normalize(String(full.dropFirst(rootPath.count + 1)))
            guard !MediaPath.isArchived(relative) else { continue }
            let ext = url.pathExtension.lowercased()
            guard let kind = MediaProbe.kind(
                forExtension: ext, video: videoSet, audio: audioSet) else {
                // Everything with an extension that no enabled list
                // claims — dotfiles and extensionless files are noise,
                // not a setting anyone would change.
                if !ext.isEmpty { skipped[ext, default: 0] += 1 }
                continue
            }
            candidates.append(ScanCandidate(
                relativePath: relative,
                folderPath: MediaPath.folder(of: relative),
                fileName: MediaPath.fileName(of: relative),
                fileExtension: ext,
                kind: kind,
                fileSize: (try? fileAccess.fileSize(at: url)) ?? 0,
                isKnown: existing.contains(relative.lowercased()),
                isRemoved: !existing.contains(relative.lowercased()) && removed.contains(relative.lowercased())))
        }

        candidates.sort { $0.relativePath < $1.relativePath }
        return ScanOutcome(
            candidates: candidates, skippedByExtension: skipped, scannedAt: Date())
    }
}
