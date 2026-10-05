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
    private var filesHere = true

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
    /// False to stand in for a library another Mac holds.
    var filesAreOnThisMac: Bool {
        get { lock.withLock { filesHere } }
        set { lock.withLock { filesHere = newValue } }
    }
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
    func storedThumbnail(itemID: UUID) async throws -> Data? {
        try await run { try await base.storedThumbnail(itemID: itemID) }
    }

    // MARK: TagManaging

    func fullVocabulary() async throws -> [CategoryTags] {
        try await run { try await base.fullVocabulary() }
    }
    func tagUsageCounts(categoryID: UUID) async throws -> [UUID: Int] {
        try await run { try await base.tagUsageCounts(categoryID: categoryID) }
    }
    func tagDetails(tagID: UUID) async throws -> TagDetails {
        try await run { try await base.tagDetails(tagID: tagID) }
    }
    func setTagFavorite(_ tagID: UUID, _ isFavorite: Bool) async throws {
        try await run { try await base.setTagFavorite(tagID, isFavorite) }
    }
    func convertTagToAlias(_ tagID: UUID, of targetID: UUID) async throws {
        try await run { try await base.convertTagToAlias(tagID, of: targetID) }
    }
    func replaceTag(_ tagID: UUID, with targetID: UUID, on itemID: UUID?) async throws {
        try await run { try await base.replaceTag(tagID, with: targetID, on: itemID) }
    }
    func deleteTag(_ tagID: UUID) async throws {
        try await run { try await base.deleteTag(tagID) }
    }
    func removeAlias(_ alias: String, fromTag tagID: UUID) async throws {
        try await run { try await base.removeAlias(alias, fromTag: tagID) }
    }
    func saveTag(_ draft: TagDraft) async throws -> SightsAndSoundsKit.Tag {
        try await run { try await base.saveTag(draft) }
    }

    // MARK: VocabularyManaging

    func categories() async throws -> [TagCategory] {
        try await run { try await base.categories() }
    }
    func categoryTable(categoryID: UUID) async throws -> CategoryTable {
        try await run { try await base.categoryTable(categoryID: categoryID) }
    }
    func vocabularyIndex() async throws -> VocabularyIndex {
        try await run { try await base.vocabularyIndex() }
    }
    func fields(scope: FieldScope, categoryID: UUID?) async throws -> [FieldDefinition] {
        try await run { try await base.fields(scope: scope, categoryID: categoryID) }
    }
    func fieldValues(tagID: UUID) async throws -> [UUID: String] {
        try await run { try await base.fieldValues(tagID: tagID) }
    }
    func takenNames(categoryID: UUID) async throws -> Set<String> {
        try await run { try await base.takenNames(categoryID: categoryID) }
    }
    func createCategory(_ category: TagCategory) async throws {
        try await run { try await base.createCategory(category) }
    }
    func updateCategory(_ category: TagCategory) async throws {
        try await run { try await base.updateCategory(category) }
    }
    func deleteCategory(_ categoryID: UUID) async throws {
        try await run { try await base.deleteCategory(categoryID) }
    }
    func mergeTags(_ sourceIDs: [UUID], into target: TagMergeTarget) async throws -> SightsAndSoundsKit.Tag {
        try await run { try await base.mergeTags(sourceIDs, into: target) }
    }
    func setTagHidden(_ tagID: UUID, _ hidden: Bool) async throws {
        try await run { try await base.setTagHidden(tagID, hidden) }
    }
    func setTagNotes(_ tagID: UUID, _ notes: String) async throws {
        try await run { try await base.setTagNotes(tagID, notes) }
    }
    func setFieldValue(_ value: String, tagID: UUID, field: FieldDefinition) async throws {
        try await run { try await base.setFieldValue(value, tagID: tagID, field: field) }
    }
    func createField(_ field: FieldDefinition) async throws -> FieldDefinition {
        try await run { try await base.createField(field) }
    }
    func deleteField(_ fieldID: UUID) async throws {
        try await run { try await base.deleteField(fieldID) }
    }

    // MARK: SupportingReading

    func watchHistory(limit: Int) async throws -> WatchHistory {
        try await run { try await base.watchHistory(limit: limit) }
    }
    func signalSummary(itemID: UUID) async throws -> SignalSummary? {
        try await run { try await base.signalSummary(itemID: itemID) }
    }
    func unsavedSegments(itemIDs: [UUID]) async throws -> [LibraryDatabase.UnsavedSegments] {
        try await run { try await base.unsavedSegments(itemIDs: itemIDs) }
    }
    func runNextAndWait(jobID: UUID) async throws {
        try await run { try await base.runNextAndWait(jobID: jobID) }
    }

    // MARK: ReviewManaging

    func reviewLists() async throws -> ReviewLists {
        try await run { try await base.reviewLists() }
    }
    func mergeableTags(keeperID: UUID, loserID: UUID) async throws -> [SightsAndSoundsKit.Tag] {
        try await run { try await base.mergeableTags(keeperID: keeperID, loserID: loserID) }
    }
    func decideDuplicate(
        keeperID: UUID, loserID: UUID, candidateID: UUID?, mergeTagIDs: Set<UUID>
    ) async throws -> DecideOutcome {
        try await run {
            try await base.decideDuplicate(
                keeperID: keeperID, loserID: loserID, candidateID: candidateID, mergeTagIDs: mergeTagIDs)
        }
    }
    func rejectDuplicate(candidateID: UUID) async throws {
        try await run { try await base.rejectDuplicate(candidateID: candidateID) }
    }
    func keepBothDuplicates(candidateID: UUID) async throws {
        try await run { try await base.keepBothDuplicates(candidateID: candidateID) }
    }
    func unsavedSegmentsOfMarked(itemIDs: [UUID]?) async throws -> [LibraryDatabase.UnsavedSegments] {
        try await run { try await base.unsavedSegmentsOfMarked(itemIDs: itemIDs) }
    }
    func purgeMarked(itemIDs: [UUID]?) async throws -> LibraryDatabase.PurgeOutcome {
        try await run { try await base.purgeMarked(itemIDs: itemIDs) }
    }
    func playbackIssueEvidence(itemID: UUID) async throws -> PlaybackIssueEvidence? {
        try await run { try await base.playbackIssueEvidence(itemID: itemID) }
    }
    func queueRepair(itemID: UUID, recipe: RepairRecipe) async throws -> JobRecord {
        try await run { try await base.queueRepair(itemID: itemID, recipe: recipe) }
    }
    func repairQueue(startingQueue: Bool) async throws -> RepairQueue {
        try await run { try await base.repairQueue(startingQueue: startingQueue) }
    }

    // MARK: MaintenanceManaging

    func maintenanceSnapshot(includingBackups: Bool) async throws -> MaintenanceSnapshot {
        try await run { try await base.maintenanceSnapshot(includingBackups: includingBackups) }
    }
    func acceptDiskSize(itemID: UUID) async throws {
        try await run { try await base.acceptDiskSize(itemID: itemID) }
    }
    func previewWriteback(itemIDs: [UUID]?) async throws -> WritebackPreview {
        try await run { try await base.previewWriteback(itemIDs: itemIDs) }
    }
    func backUp() async throws -> URL {
        try await run { try await base.backUp() }
    }

    // MARK: OrganiseManaging

    func organisePlan(template: String, itemIDs: [UUID]) async throws -> [ReorganizePlanEntry] {
        try await run { try await base.organisePlan(template: template, itemIDs: itemIDs) }
    }
    func moveSessions() async throws -> [LibraryDatabase.MoveSession] {
        try await run { try await base.moveSessions() }
    }
    func revertMove(logID: UUID) async throws {
        try await run { try await base.revertMove(logID: logID) }
    }
    func revertMoveSession(sessionID: UUID) async throws -> MoveRevertOutcome {
        try await run { try await base.revertMoveSession(sessionID: sessionID) }
    }
    func jobQueue(kind: String, startingQueue: Bool) async throws -> JobQueueState {
        try await run { try await base.jobQueue(kind: kind, startingQueue: startingQueue) }
    }

    // MARK: PropertiesManaging

    func libraryProperties() async throws -> LibraryProperties {
        try await run { try await base.libraryProperties() }
    }
    func renameLibrary(to name: String) async throws {
        try await run { try await base.renameLibrary(to: name) }
    }
    func setSeparatorCharacters(_ characters: String) async throws {
        try await run { try await base.setSeparatorCharacters(characters) }
    }
    func setExtensionOverrides(video: [String]?, audio: [String]?) async throws {
        try await run { try await base.setExtensionOverrides(video: video, audio: audio) }
    }

    // MARK: AnalysisManaging

    func itemAnalysis(itemID: UUID) async throws -> ItemAnalysisAnswer {
        try await run { try await base.itemAnalysis(itemID: itemID) }
    }
    func markAnalyzed(itemID: UUID) async throws {
        try await run { try await base.markAnalyzed(itemID: itemID) }
    }
    func metadataSweepState(itemID: UUID) async throws -> ItemSweepState {
        try await run { try await base.metadataSweepState(itemID: itemID) }
    }
    func resetMetadataSweep(itemIDs: [UUID]) async throws {
        try await run { try await base.resetMetadataSweep(itemIDs: itemIDs) }
    }
    func analysisRules() async throws -> [RuleEngine.Rule] {
        try await run { try await base.analysisRules() }
    }
    func saveAnalysisRule(_ rule: RuleEngine.Rule) async throws {
        try await run { try await base.saveAnalysisRule(rule) }
    }
    func deleteAnalysisRule(id: UUID) async throws {
        try await run { try await base.deleteAnalysisRule(id: id) }
    }
    func moveAnalysisRule(id: UUID, up: Bool) async throws {
        try await run { try await base.moveAnalysisRule(id: id, up: up) }
    }
    func ruleCovering(key: String?, value: String) async throws -> RuleEngine.Rule? {
        try await run { try await base.ruleCovering(key: key, value: value) }
    }
    func dryRun(of rule: RuleEngine.Rule) async throws -> RuleDryRun {
        try await run { try await base.dryRun(of: rule) }
    }
    func dryRuns(of rules: [RuleEngine.Rule]) async throws -> [UUID: RuleDryRun] {
        try await run { try await base.dryRuns(of: rules) }
    }
    func applyAnalysisRule(_ rule: RuleEngine.Rule) async throws -> RuleApplication {
        try await run { try await base.applyAnalysisRule(rule) }
    }
    func jsonSchemas() async throws -> [JsonSchemaDefinition] {
        try await run { try await base.jsonSchemas() }
    }
    func saveJsonSchema(id: UUID?, named name: String, keys: [SchemaKey]) async throws -> JsonSchemaDefinition {
        try await run { try await base.saveJsonSchema(id: id, named: name, keys: keys) }
    }
    func deleteJsonSchema(id: UUID) async throws {
        try await run { try await base.deleteJsonSchema(id: id) }
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
    func toggleTag(_ tagID: UUID, on itemID: UUID) async throws -> Bool {
        try await run { try await base.toggleTag(tagID, on: itemID) }
    }
    func renameTag(_ tagID: UUID, to name: String) async throws {
        try await run { try await base.renameTag(tagID, to: name) }
    }
    func ensureTag(named name: String, inCategory categoryID: UUID) async throws -> SightsAndSoundsKit.Tag {
        try await run { try await base.ensureTag(named: name, inCategory: categoryID) }
    }
    func addAlias(_ alias: String, toTag tagID: UUID) async throws {
        try await run { try await base.addAlias(alias, toTag: tagID) }
    }
    func setCategoryOrder(_ categoryIDs: [UUID]) async throws {
        try await run { try await base.setCategoryOrder(categoryIDs) }
    }
    func setKeyBinding(_ key: String, tagID: UUID, advance: Bool) async throws {
        try await run { try await base.setKeyBinding(key, tagID: tagID, advance: advance) }
    }
    func removeKeyBinding(_ key: String) async throws {
        try await run { try await base.removeKeyBinding(key) }
    }
    func createSegment(
        parentID: UUID, name: String, startSeconds: Double, endSeconds: Double, role: SegmentRole
    ) async throws -> MediaItem {
        try await run {
            try await base.createSegment(
                parentID: parentID, name: name, startSeconds: startSeconds, endSeconds: endSeconds, role: role)
        }
    }
    func renameSegment(_ itemID: UUID, to name: String) async throws {
        try await run { try await base.renameSegment(itemID, to: name) }
    }
    func deleteSegment(_ itemID: UUID) async throws {
        try await run { try await base.deleteSegment(itemID) }
    }
    func addBlock(
        to itemID: UUID, startSeconds: Double, endSeconds: Double, kind: VideoBlockKind
    ) async throws -> VideoBlock {
        try await run {
            try await base.addBlock(to: itemID, startSeconds: startSeconds, endSeconds: endSeconds, kind: kind)
        }
    }
    func deleteBlock(_ blockID: UUID) async throws {
        try await run { try await base.deleteBlock(blockID) }
    }
    func setSearchFormats(_ formats: SearchFormats, replacingUnreadable: Bool) async throws {
        try await run { try await base.setSearchFormats(formats, replacingUnreadable: replacingUnreadable) }
    }
}
