import Foundation

/// Why a new library file was not made. The text says what happened and
/// no more: what to do next depends on what the person chose — a name in
/// New Library, only a folder for the signal-samples library — so each
/// caller adds that.
public enum LibraryCreationError: Error, Equatable, CustomStringConvertible {
    case fileExists(String)

    public var description: String {
        switch self {
        case .fileExists(let name):
            "“\(name)” already exists — a new library is never made over a file."
        }
    }
}

extension LibraryDatabase {
    /// A new library file, made whole or not at all. Never over a file
    /// that is already there (it may be a library open right now: opening
    /// it would migrate it and pour a template into it), and on any
    /// failure in `fill` — registering it included — the library is closed
    /// and removed with its WAL and shared-memory files, so the same name
    /// can simply be tried again. New Library and the signal-samples
    /// library both make theirs here.
    static func createFresh(at url: URL, fill: (LibraryDatabase) throws -> Void) throws -> LibraryDatabase {
        let library = try openFresh(at: url)
        do {
            try fill(library)
        } catch {
            discard(library, at: url)
            throw error
        }
        return library
    }

    static func createFresh(
        at url: URL, fill: (LibraryDatabase) async throws -> Void
    ) async throws -> LibraryDatabase {
        let library = try openFresh(at: url)
        do {
            try await fill(library)
        } catch {
            discard(library, at: url)
            throw error
        }
        return library
    }

    private static func openFresh(at url: URL) throws -> LibraryDatabase {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw LibraryCreationError.fileExists(url.lastPathComponent)
        }
        return try LibraryDatabase.open(at: url)
    }

    private static func discard(_ library: LibraryDatabase, at url: URL) {
        try? library.close()
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }
}
