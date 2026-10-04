import Foundation
import SightsAndSoundsKit

/// A library service for tests: a real local one, any of whose
/// operations can be made to fail or to take its time. It stands in for
/// what a library on another Mac does that one on this Mac never does —
/// answer late, answer out of order, or not answer.
///
/// Operations are named as `#function` spells them: `"savedFilters()"`,
/// `"listing(_:)"`.
final class StubLibraryService: LibraryService, @unchecked Sendable {
    struct Failure: Error, CustomStringConvertible {
        let operation: String
        var description: String { "stubbed failure of \(operation)" }
    }

    private let base: LocalLibraryService
    private let lock = NSLock()
    private var failing: Set<String> = []
    private var delays: [String: Duration] = [:]
    private var started: [String: Int] = [:]
    private var finished: [String: Int] = [:]
    private var streams = 0

    init(_ base: LocalLibraryService) {
        self.base = base
    }

    /// Every later call of this operation throws.
    func fail(_ operation: String) { lock.withLock { _ = failing.insert(operation) } }
    /// The next call of this operation waits this long before it is
    /// answered; calls after it are answered at once.
    func delay(_ operation: String, by duration: Duration) { lock.withLock { delays[operation] = duration } }
    /// How many calls of this operation have been made.
    func calls(_ operation: String) -> Int { lock.withLock { started[operation, default: 0] } }
    /// How many calls of this operation have returned or thrown.
    func answered(_ operation: String) -> Int { lock.withLock { finished[operation, default: 0] } }
    /// Change streams handed out and not yet let go of.
    var openChangeStreams: Int { lock.withLock { streams } }

    private func run<T>(_ operation: String = #function, _ body: () async throws -> T) async throws -> T {
        let (fails, delay) = lock.withLock { () -> (Bool, Duration?) in
            started[operation, default: 0] += 1
            return (failing.contains(operation), delays.removeValue(forKey: operation))
        }
        defer { lock.withLock { finished[operation, default: 0] += 1 } }
        if let delay { try? await Task.sleep(for: delay) }
        if fails { throw Failure(operation: operation) }
        return try await body()
    }

    func changes() -> AsyncStream<LibraryChange> {
        let inner = base.changes()
        lock.withLock { streams += 1 }
        return AsyncStream { continuation in
            let forwarding = Task {
                for await change in inner { continuation.yield(change) }
                continuation.finish()
            }
            continuation.onTermination = { [weak self] _ in
                forwarding.cancel()
                self?.lock.withLock { self?.streams -= 1 }
            }
        }
    }

    // MARK: BrowseReading

    func sourceStates() async throws -> [SourceState] { try await run { try await base.sourceStates() } }
    func browseVocabulary() async throws -> BrowseVocabulary { try await run { try await base.browseVocabulary() } }
    func sidebarCounts(kinds: MediaKinds) async throws -> SidebarCounts {
        try await run { try await base.sidebarCounts(kinds: kinds) }
    }
    func pendingDuplicateCount() async throws -> Int { try await run { try await base.pendingDuplicateCount() } }
    func savedFilters() async throws -> [SavedFilter] { try await run { try await base.savedFilters() } }
    func savedFilterCounts(kinds: MediaKinds) async throws -> [UUID: Int] {
        try await run { try await base.savedFilterCounts(kinds: kinds) }
    }
    func tileMenuFacts(snapshotsPerItem: Int) async throws -> TileMenuFacts {
        try await run { try await base.tileMenuFacts(snapshotsPerItem: snapshotsPerItem) }
    }
    func thumbnailQueueStatus() async throws -> ThumbnailQueueStatus? {
        try await run { try await base.thumbnailQueueStatus() }
    }

    // MARK: BrowseListing

    func listing(_ request: ListingRequest) async throws -> BrowseListingAnswer {
        try await run { try await base.listing(request) }
    }
}
