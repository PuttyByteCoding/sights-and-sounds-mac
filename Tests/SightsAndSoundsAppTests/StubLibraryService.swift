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
    private var lateAnswers: [String: Duration] = [:]
    private var started: [String: Int] = [:]
    private var finished: [String: Int] = [:]
    private var streams = 0
    private var events: [PlaybackEvent] = []

    init(_ base: LocalLibraryService) {
        self.base = base
    }

    /// Every later call of this operation throws.
    func fail(_ operation: String) { lock.withLock { _ = failing.insert(operation) } }
    /// The next call of this operation waits this long before it is
    /// answered; calls after it are answered at once.
    func delay(_ operation: String, by duration: Duration) { lock.withLock { delays[operation] = duration } }
    /// The next call of this operation is carried out at once and its
    /// answer held this long: what it read is already out of date by the
    /// time it arrives.
    func holdAnswer(_ operation: String, by duration: Duration) { lock.withLock { lateAnswers[operation] = duration } }
    /// How many calls of this operation have been made.
    func calls(_ operation: String) -> Int { lock.withLock { started[operation, default: 0] } }
    /// How many calls of this operation have returned or thrown.
    func answered(_ operation: String) -> Int { lock.withLock { finished[operation, default: 0] } }
    /// Every playback event that reached the library, in order.
    var playbackEvents: [PlaybackEvent] { lock.withLock { events } }
    /// Change streams handed out and not yet let go of.
    var openChangeStreams: Int { lock.withLock { streams } }

    private func run<T>(_ operation: String = #function, _ body: () async throws -> T) async throws -> T {
        let (fails, delay, late) = lock.withLock { () -> (Bool, Duration?, Duration?) in
            started[operation, default: 0] += 1
            return (
                failing.contains(operation), delays.removeValue(forKey: operation),
                lateAnswers.removeValue(forKey: operation))
        }
        defer { lock.withLock { finished[operation, default: 0] += 1 } }
        if let delay { try? await Task.sleep(for: delay) }
        if fails { throw Failure(operation: operation) }
        let answer = try await body()
        if let late { try? await Task.sleep(for: late) }
        return answer
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

    // MARK: BrowseWriting

    func renameSource(_ id: UUID, to name: String) async throws {
        try await run { try await base.renameSource(id, to: name) }
    }
    func setSourceEnabled(_ id: UUID, _ enabled: Bool) async throws {
        try await run { try await base.setSourceEnabled(id, enabled) }
    }
    func addSource(named name: String, rootPath: String) async throws -> Source {
        try await run { try await base.addSource(named: name, rootPath: rootPath) }
    }
    @discardableResult
    func saveFilter(named name: String, _ filter: MediaFilter) async throws -> SavedFilter {
        try await run { try await base.saveFilter(named: name, filter) }
    }
    func updateSavedFilter(_ id: UUID, to filter: MediaFilter) async throws {
        try await run { try await base.updateSavedFilter(id, to: filter) }
    }
    func renameSavedFilter(_ id: UUID, to name: String) async throws {
        try await run { try await base.renameSavedFilter(id, to: name) }
    }
    func deleteSavedFilter(_ id: UUID) async throws {
        try await run { try await base.deleteSavedFilter(id) }
    }
    func assignTag(_ tagID: UUID, to itemIDs: [UUID]) async throws {
        try await run { try await base.assignTag(tagID, to: itemIDs) }
    }
    func removeTag(_ tagID: UUID, from itemIDs: [UUID]) async throws {
        try await run { try await base.removeTag(tagID, from: itemIDs) }
    }
    func setFavorite(_ itemIDs: [UUID], _ isFavorite: Bool) async throws {
        try await run { try await base.setFavorite(itemIDs, isFavorite) }
    }
    func setNeedsReview(_ itemIDs: [UUID], _ needsReview: Bool) async throws {
        try await run { try await base.setNeedsReview(itemIDs, needsReview) }
    }
    func setStaging(
        _ folder: StagingFolder, on: Bool, itemIDs: [UUID]
    ) async throws -> [StagingFailure] {
        try await run { try await base.setStaging(folder, on: on, itemIDs: itemIDs) }
    }

    // MARK: JobRequesting

    @discardableResult
    func run(_ request: JobRequest, wait: JobWait) async throws -> JobRecord? {
        try await run { try await base.run(request, wait: wait) }
    }

    // MARK: PlayerReading

    func playable(itemID: UUID) async throws -> Playable { try await run { try await base.playable(itemID: itemID) } }
    func items(ids: [UUID]) async throws -> [MediaItem] { try await run { try await base.items(ids: ids) } }
    func queueItems(_ definition: QueueDefinition) async throws -> [MediaItem] {
        try await run { try await base.queueItems(definition) }
    }
    func tagMembership(itemIDs: [UUID]) async throws -> [UUID: Set<UUID>] {
        try await run { try await base.tagMembership(itemIDs: itemIDs) }
    }
    func pendingTextScan(itemID: UUID) async throws -> UUID? {
        try await run { try await base.pendingTextScan(itemID: itemID) }
    }
    func textLines(itemID: UUID) async throws -> [OcrTextLine] {
        try await run { try await base.textLines(itemID: itemID) }
    }
    func opened(itemID: UUID) async throws -> OpenedItem { try await run { try await base.opened(itemID: itemID) } }
    func itemTags(itemID: UUID) async throws -> [CategoryTags] {
        try await run { try await base.itemTags(itemID: itemID) }
    }
    func tagging(itemID: UUID) async throws -> PlayerTagging { try await run { try await base.tagging(itemID: itemID) } }
    func segments(parentID: UUID) async throws -> PlayerSegments {
        try await run { try await base.segments(parentID: parentID) }
    }
    func searchContext(itemID: UUID) async throws -> SearchContext {
        try await run { try await base.searchContext(itemID: itemID) }
    }
    func recentlyWatched(limit: Int) async throws -> [MediaItem] {
        try await run { try await base.recentlyWatched(limit: limit) }
    }

    // MARK: PlayerWriting

    func recordPlayback(_ event: PlaybackEvent) async throws {
        try await run {
            try await base.recordPlayback(event)
            lock.withLock { events.append(event) }
        }
    }
    func setFlag(_ flag: PlayerToggleFlag, _ on: Bool, itemID: UUID) async throws -> Playable {
        try await run { try await base.setFlag(flag, on, itemID: itemID) }
    }
}
