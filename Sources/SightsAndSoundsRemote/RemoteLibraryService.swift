import Foundation
import SightsAndSoundsKit

/// A library another Mac holds, as the app's windows see any library.
///
/// Every operation is a request to the host, which carries it out on the
/// library it holds and answers with the result. Nothing of the library
/// is kept here.
public final class RemoteLibraryService: LibraryService, @unchecked Sendable {
    /// How the connection to the host stands.
    public enum State: Equatable, Sendable {
        case connecting
        case connected
        /// Lost, and being tried again. What was last wrong, in words.
        case reconnecting(String)
        /// The host will not have this Mac: not approved, or revoked, or
        /// a different version. Not tried again.
        case refused(String)
    }

    private let client: RemoteClient
    /// What this Mac's players play the library's items from.
    private let relay: MediaRelay
    private let lock = NSLock()
    private var currentState: State = .connecting
    private var stateWatchers: [UUID: AsyncStream<State>.Continuation] = [:]

    /// - Parameters:
    ///   - endpoint: where the host is, and who this Mac is to it.
    ///   - libraryID: which of the host's libraries.
    public convenience init(endpoint: RemoteEndpoint, libraryID: UUID) {
        self.init(client: RemoteClient(endpoint: endpoint, libraryID: libraryID))
    }

    init(client: RemoteClient) {
        self.client = client
        relay = MediaRelay { [client] itemID, offset, length in
            try await client.media(MediaRead(itemID: itemID, offset: offset, length: length))
        }
    }

    /// The host's name and the libraries it offers, asked on a connection
    /// of its own. For a list of hosts, before any library is opened.
    public static func welcome(from endpoint: RemoteEndpoint, timeout: Duration = .seconds(10)) async throws -> Welcome {
        let client = RemoteClient(endpoint: endpoint, libraryID: nil, connectTimeout: timeout)
        let (connection, welcome) = try await client.connect()
        await connection.close()
        return welcome
    }

    /// Let go of the host: every connection is closed.
    public func close() {
        relay.stop()
        Task { await client.close() }
    }

    // MARK: - State

    public var state: State { lock.withLock { currentState } }

    /// The state now, and each change of it.
    public func states() -> AsyncStream<State> {
        AsyncStream { continuation in
            let id = UUID()
            let now = lock.withLock { () -> State in
                stateWatchers[id] = continuation
                return currentState
            }
            continuation.yield(now)
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { self?.stateWatchers[id] = nil }
            }
        }
    }

    private func set(_ state: State) {
        let watchers = lock.withLock { () -> [AsyncStream<State>.Continuation] in
            guard currentState != state else { return [] }
            // Refused is the end of it: a later failure to connect does
            // not turn it back into "trying again".
            if case .refused = currentState, state != .connected { return [] }
            currentState = state
            return Array(stateWatchers.values)
        }
        for watcher in watchers { watcher.yield(state) }
    }

    private func note(_ error: any Error) {
        switch RemoteClient.remote(error) {
        case .refused(let refusal): set(.refused(refusal.message))
        case .unreachable(let why): set(.reconnecting(why))
        case .failed: set(.connected)  // the host answered: the connection is fine
        }
    }

    // MARK: - Asking

    private func ask<T: Decodable>(_ request: ServiceRequest) async throws -> T {
        do {
            let json = try await client.send(request)
            set(.connected)
            return try RemoteProtocol.decode(T.self, from: json)
        } catch {
            note(error)
            throw RemoteClient.remote(error)
        }
    }

    private func tell(_ request: ServiceRequest) async throws {
        do {
            _ = try await client.send(request)
            set(.connected)
        } catch {
            note(error)
            throw RemoteClient.remote(error)
        }
    }

    /// The host's answer names a file on the host, which means nothing
    /// here. What it says is that the host can reach the file; a player
    /// on this Mac is given the relay's address for it instead.
    private func here(_ playable: Playable) async -> Playable {
        guard let item = playable.item, let onTheHost = playable.url else {
            return Playable(item: playable.item, url: nil)
        }
        let url = try? await relay.url(for: item.id, fileExtension: onTheHost.pathExtension)
        return Playable(item: item, url: url)
    }

    /// Some of an item's file, straight from the host. What the relay
    /// reads with.
    public func fileBytes(itemID: UUID, offset: Int64, length: Int) async throws -> MediaBytes {
        do {
            let bytes = try await client.media(MediaRead(itemID: itemID, offset: offset, length: length))
            set(.connected)
            return bytes
        } catch {
            note(error)
            throw RemoteClient.remote(error)
        }
    }

    // MARK: - LibraryService

    public var filesAreOnThisMac: Bool { false }

    /// The library's changes, as the host hears of them. The stream has a
    /// connection of its own. When that is lost it is made again, and the
    /// first thing said afterwards is that everything may have changed —
    /// whatever happened while nothing could be heard was not heard.
    public func changes() -> AsyncStream<LibraryChange> {
        AsyncStream { continuation in
            let following = Task { [weak self, client] in
                var delay: Duration = .milliseconds(500)
                var connectedBefore = false
                while !Task.isCancelled {
                    do {
                        let (connection, _) = try await client.connect()
                        defer { Task { await connection.close() } }
                        try await connection.send(Frame(kind: RemoteProtocol.Kind.subscribe))
                        self?.set(.connected)
                        delay = .milliseconds(500)
                        if connectedBefore {
                            continuation.yield(LibraryChange(domains: Set(LibraryChangeDomain.allCases)))
                        }
                        connectedBefore = true
                        while true {
                            let frame = try await connection.receive()
                            guard frame.kind == RemoteProtocol.Kind.change else { continue }
                            let names = try RemoteProtocol.decode([String].self, from: frame.payload)
                            let domains = Set(names.compactMap(LibraryChangeDomain.init(rawValue:)))
                            if !domains.isEmpty { continuation.yield(LibraryChange(domains: domains)) }
                        }
                    } catch {
                        if Task.isCancelled { break }
                        self?.note(error)
                        if case .refused = RemoteClient.remote(error) { break }
                        try? await Task.sleep(for: delay)
                        delay = min(delay * 2, .seconds(10))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in following.cancel() }
        }
    }

    // BrowseReading

    public func sourceStates() async throws -> [SourceState] { try await ask(.sourceStates) }
    public func browseVocabulary() async throws -> BrowseVocabulary { try await ask(.browseVocabulary) }
    public func sidebarCounts(kinds: MediaKinds) async throws -> SidebarCounts {
        try await ask(.sidebarCounts(kinds: kinds))
    }
    public func pendingDuplicateCount() async throws -> Int { try await ask(.pendingDuplicateCount) }
    public func savedFilters() async throws -> [SavedFilter] { try await ask(.savedFilters) }
    public func savedFilterCounts(kinds: MediaKinds) async throws -> [UUID: Int] {
        try await ask(.savedFilterCounts(kinds: kinds))
    }
    public func tileMenuFacts(snapshotsPerItem: Int) async throws -> TileMenuFacts {
        try await ask(.tileMenuFacts(snapshotsPerItem: snapshotsPerItem))
    }
    public func storedThumbnail(itemID: UUID) async throws -> Data? {
        try await ask(.storedThumbnail(itemID: itemID))
    }
    public func thumbnailQueueStatus() async throws -> ThumbnailQueueStatus? {
        try await ask(.thumbnailQueueStatus)
    }

    // BrowseListing

    public func listing(_ request: ListingRequest) async throws -> BrowseListingAnswer {
        try await ask(.listing(request))
    }

    // BrowseWriting

    public func renameSource(_ id: UUID, to name: String) async throws {
        try await tell(.renameSource(id: id, name: name))
    }
    public func setSourceEnabled(_ id: UUID, _ enabled: Bool) async throws {
        try await tell(.setSourceEnabled(id: id, enabled: enabled))
    }
    /// Not offered: a source is a folder on the host's disk. Refused
    /// here without being asked, and the host refuses it too.
    public func addSource(named name: String, rootPath: String) async throws -> Source {
        throw RemoteError.failed(
            ServiceRequest.addSource(name: name, rootPath: rootPath).refusalForAnotherMac
                ?? "A source is added on the Mac that holds the library.")
    }
    @discardableResult
    public func saveFilter(named name: String, _ filter: MediaFilter) async throws -> SavedFilter {
        try await ask(.saveFilter(name: name, filter: filter))
    }
    public func updateSavedFilter(_ id: UUID, to filter: MediaFilter) async throws {
        try await tell(.updateSavedFilter(id: id, filter: filter))
    }
    public func renameSavedFilter(_ id: UUID, to name: String) async throws {
        try await tell(.renameSavedFilter(id: id, name: name))
    }
    public func deleteSavedFilter(_ id: UUID) async throws {
        try await tell(.deleteSavedFilter(id: id))
    }
    public func assignTag(_ tagID: UUID, to itemIDs: [UUID]) async throws {
        try await tell(.assignTag(tagID: tagID, itemIDs: itemIDs))
    }
    public func removeTag(_ tagID: UUID, from itemIDs: [UUID]) async throws {
        try await tell(.removeTag(tagID: tagID, itemIDs: itemIDs))
    }
    public func setFavorite(_ itemIDs: [UUID], _ isFavorite: Bool) async throws {
        try await tell(.setFavorite(itemIDs: itemIDs, isFavorite: isFavorite))
    }
    public func setNeedsReview(_ itemIDs: [UUID], _ needsReview: Bool) async throws {
        try await tell(.setNeedsReview(itemIDs: itemIDs, needsReview: needsReview))
    }
    public func setStaging(
        _ folder: StagingFolder, on: Bool, itemIDs: [UUID]
    ) async throws -> [StagingFailure] {
        try await ask(.setStaging(folder: folder, on: on, itemIDs: itemIDs))
    }

    // JobRequesting

    @discardableResult
    public func run(_ request: JobRequest, wait: JobWait) async throws -> JobRecord? {
        try await ask(.run(request: request, wait: wait))
    }

    // PlayerReading

    public func playable(itemID: UUID) async throws -> Playable {
        await here(try await ask(.playable(itemID: itemID)))
    }
    public func opened(itemID: UUID) async throws -> OpenedItem {
        var opened: OpenedItem = try await ask(.opened(itemID: itemID))
        opened.playable = await here(opened.playable)
        return opened
    }
    public func itemTags(itemID: UUID) async throws -> [CategoryTags] { try await ask(.itemTags(itemID: itemID)) }
    public func tagging(itemID: UUID) async throws -> PlayerTagging { try await ask(.tagging(itemID: itemID)) }
    public func segments(parentID: UUID) async throws -> PlayerSegments {
        try await ask(.segments(parentID: parentID))
    }
    public func searchContext(itemID: UUID) async throws -> SearchContext {
        try await ask(.searchContext(itemID: itemID))
    }
    public func recentlyWatched(limit: Int) async throws -> [MediaItem] {
        try await ask(.recentlyWatched(limit: limit))
    }
    public func items(ids: [UUID]) async throws -> [MediaItem] { try await ask(.items(ids: ids)) }
    public func queueItems(_ definition: QueueDefinition) async throws -> [MediaItem] {
        try await ask(.queueItems(definition))
    }
    public func tagMembership(itemIDs: [UUID]) async throws -> [UUID: Set<UUID>] {
        try await ask(.tagMembership(itemIDs: itemIDs))
    }
    public func pendingTextScan(itemID: UUID) async throws -> UUID? {
        try await ask(.pendingTextScan(itemID: itemID))
    }
    public func textLines(itemID: UUID) async throws -> [OcrTextLine] {
        try await ask(.textLines(itemID: itemID))
    }

    // PlayerWriting

    public func recordPlayback(_ event: PlaybackEvent) async throws {
        try await tell(.recordPlayback(event))
    }
    public func setFlag(_ flag: PlayerToggleFlag, _ on: Bool, itemID: UUID) async throws -> Playable {
        await here(try await ask(.setFlag(flag: flag, on: on, itemID: itemID)))
    }
    public func toggleTag(_ tagID: UUID, on itemID: UUID) async throws -> Bool {
        try await ask(.toggleTag(tagID: tagID, itemID: itemID))
    }
    public func renameTag(_ tagID: UUID, to name: String) async throws {
        try await tell(.renameTag(tagID: tagID, name: name))
    }
    public func ensureTag(named name: String, inCategory categoryID: UUID) async throws -> Tag {
        try await ask(.ensureTag(name: name, categoryID: categoryID))
    }
    public func addAlias(_ alias: String, toTag tagID: UUID) async throws {
        try await tell(.addAlias(alias: alias, tagID: tagID))
    }
    public func setCategoryOrder(_ categoryIDs: [UUID]) async throws {
        try await tell(.setCategoryOrder(categoryIDs: categoryIDs))
    }
    public func setKeyBinding(_ key: String, tagID: UUID, advance: Bool) async throws {
        try await tell(.setKeyBinding(key: key, tagID: tagID, advance: advance))
    }
    public func removeKeyBinding(_ key: String) async throws {
        try await tell(.removeKeyBinding(key: key))
    }
    public func createSegment(
        parentID: UUID, name: String, startSeconds: Double, endSeconds: Double, role: SegmentRole
    ) async throws -> MediaItem {
        try await ask(.createSegment(
            parentID: parentID, name: name, startSeconds: startSeconds, endSeconds: endSeconds, role: role))
    }
    public func renameSegment(_ itemID: UUID, to name: String) async throws {
        try await tell(.renameSegment(itemID: itemID, name: name))
    }
    public func deleteSegment(_ itemID: UUID) async throws {
        try await tell(.deleteSegment(itemID: itemID))
    }
    public func addBlock(
        to itemID: UUID, startSeconds: Double, endSeconds: Double, kind: VideoBlockKind
    ) async throws -> VideoBlock {
        try await ask(.addBlock(itemID: itemID, startSeconds: startSeconds, endSeconds: endSeconds, kind: kind))
    }
    public func deleteBlock(_ blockID: UUID) async throws {
        try await tell(.deleteBlock(blockID: blockID))
    }
    public func setSearchFormats(_ formats: SearchFormats, replacingUnreadable: Bool) async throws {
        try await tell(.setSearchFormats(formats: formats, replacingUnreadable: replacingUnreadable))
    }
}
