import Foundation
import SightsAndSoundsKit

/// One thing asked of a library: an operation of `LibraryService`, with
/// what it was given. The client encodes it, the host decodes it and
/// calls the same operation on the library it holds. There is one case
/// per operation and nothing else, so a host does for a remote library
/// exactly what the app does for a local one.
public enum ServiceRequest: Codable, Equatable, Sendable {
    // BrowseReading
    case sourceStates
    case browseVocabulary
    case sidebarCounts(kinds: MediaKinds)
    case pendingDuplicateCount
    case savedFilters
    case savedFilterCounts(kinds: MediaKinds)
    case tileMenuFacts(snapshotsPerItem: Int)
    case thumbnailQueueStatus
    case storedThumbnail(itemID: UUID)

    // BrowseListing
    case listing(ListingRequest)

    // BrowseWriting
    case renameSource(id: UUID, name: String)
    case setSourceEnabled(id: UUID, enabled: Bool)
    case addSource(name: String, rootPath: String)
    case saveFilter(name: String, filter: MediaFilter)
    case updateSavedFilter(id: UUID, filter: MediaFilter)
    case renameSavedFilter(id: UUID, name: String)
    case deleteSavedFilter(id: UUID)
    case assignTag(tagID: UUID, itemIDs: [UUID])
    case removeTag(tagID: UUID, itemIDs: [UUID])
    case setFavorite(itemIDs: [UUID], isFavorite: Bool)
    case setNeedsReview(itemIDs: [UUID], needsReview: Bool)
    case setStaging(folder: StagingFolder, on: Bool, itemIDs: [UUID])

    // JobRequesting
    case run(request: JobRequest, wait: JobWait)

    // PlayerReading
    case playable(itemID: UUID)
    case opened(itemID: UUID)
    case itemTags(itemID: UUID)
    case tagging(itemID: UUID)
    case segments(parentID: UUID)
    case searchContext(itemID: UUID)
    case recentlyWatched(limit: Int)
    case items(ids: [UUID])
    case queueItems(QueueDefinition)
    case tagMembership(itemIDs: [UUID])
    case pendingTextScan(itemID: UUID)
    case textLines(itemID: UUID)

    // PlayerWriting
    case recordPlayback(PlaybackEvent)
    case setFlag(flag: PlayerToggleFlag, on: Bool, itemID: UUID)
    case toggleTag(tagID: UUID, itemID: UUID)
    case renameTag(tagID: UUID, name: String)
    case ensureTag(name: String, categoryID: UUID)
    case addAlias(alias: String, tagID: UUID)
    case setCategoryOrder(categoryIDs: [UUID])
    case setKeyBinding(key: String, tagID: UUID, advance: Bool)
    case removeKeyBinding(key: String)
    case createSegment(parentID: UUID, name: String, startSeconds: Double, endSeconds: Double, role: SegmentRole)
    case renameSegment(itemID: UUID, name: String)
    case deleteSegment(itemID: UUID)
    case addBlock(itemID: UUID, startSeconds: Double, endSeconds: Double, kind: VideoBlockKind)
    case deleteBlock(blockID: UUID)
    case setSearchFormats(formats: SearchFormats, replacingUnreadable: Bool)

    // TagManaging
    case fullVocabulary
    case tagUsageCounts(categoryID: UUID)
    case tagDetails(tagID: UUID)
    case setTagFavorite(tagID: UUID, isFavorite: Bool)
    case convertTagToAlias(tagID: UUID, targetID: UUID)
    case replaceTag(tagID: UUID, targetID: UUID, itemID: UUID?)
    case deleteTag(tagID: UUID)
    case removeAlias(alias: String, tagID: UUID)
    case saveTag(draft: TagDraft)

    // VocabularyManaging
    case categories
    case categoryTable(categoryID: UUID)
    case vocabularyIndex
    case fields(scope: FieldScope, categoryID: UUID?)
    case fieldValues(tagID: UUID)
    case takenNames(categoryID: UUID)
    case createCategory(category: TagCategory)
    case updateCategory(category: TagCategory)
    case deleteCategory(categoryID: UUID)
    case mergeTags(sourceIDs: [UUID], target: TagMergeTarget)
    case setTagHidden(tagID: UUID, hidden: Bool)
    case setTagNotes(tagID: UUID, notes: String)
    case setFieldValue(value: String, tagID: UUID, field: FieldDefinition)
    case createField(field: FieldDefinition)
    case deleteField(fieldID: UUID)

    // SupportingReading, and the one job hurried along
    case watchHistory(limit: Int)
    case signalSummary(itemID: UUID)
    case unsavedSegments(itemIDs: [UUID])
    case runNextAndWait(jobID: UUID)
    case job(id: UUID)
    case cancelJob(id: UUID)
    case wakeWorkers

    // ReviewManaging
    case reviewLists
    case mergeableTags(keeperID: UUID, loserID: UUID)
    case decideDuplicate(keeperID: UUID, loserID: UUID, candidateID: UUID?, mergeTagIDs: Set<UUID>)
    case rejectDuplicate(candidateID: UUID)
    case keepBothDuplicates(candidateID: UUID)
    case unsavedSegmentsOfMarked(itemIDs: [UUID]?)
    case purgeMarked(itemIDs: [UUID]?)
    case playbackIssueEvidence(itemID: UUID)
    case queueRepair(itemID: UUID, recipe: RepairRecipe)
    case repairQueue(startingQueue: Bool)

    // MaintenanceManaging
    case maintenanceSnapshot(includingBackups: Bool)
    case acceptDiskSize(itemID: UUID)
    case previewWriteback(itemIDs: [UUID]?)
    case backUp

    // OrganiseManaging
    case organisePlan(template: String, itemIDs: [UUID])
    case moveSessions
    case revertMove(logID: UUID)
    case revertMoveSession(sessionID: UUID)
    case jobQueue(kind: String, startingQueue: Bool)

    // PropertiesManaging
    case libraryProperties
    case libraryInfo
    case searchSettings
    case renameLibrary(name: String)
    case setSeparatorCharacters(characters: String)
    case setExtensionOverrides(video: [String]?, audio: [String]?)

    // AnalysisManaging
    case itemAnalysis(itemID: UUID)
    case markAnalyzed(itemID: UUID)
    case metadataSweepState(itemID: UUID)
    case resetMetadataSweep(itemIDs: [UUID])
    case existingTags(lines: [String])
    case analysisRules
    case saveAnalysisRule(rule: RuleEngine.Rule)
    case deleteAnalysisRule(id: UUID)
    case moveAnalysisRule(id: UUID, up: Bool)
    case ruleCovering(key: String?, value: String)
    case dryRun(rule: RuleEngine.Rule)
    case dryRuns(rules: [RuleEngine.Rule])
    case applyAnalysisRule(rule: RuleEngine.Rule)
    case jsonSchemas
    case saveJsonSchema(id: UUID?, name: String, keys: [SchemaKey])
    case deleteJsonSchema(id: UUID)

    // ImportManaging
    case importOverview
    case scanSource(sourceID: UUID)
    case probeFile(sourceID: UUID, relativePath: String)
    case importBoxes
    case setImportBoxes(boxes: [ImportBox])
    case enableExtension(fileExtension: String)

    // QueueManaging
    case jobLane(limit: Int)
    case moveJobToFront(id: UUID)
    case retryJob(id: UUID)
    case clearFinishedJobs
    case setQueuePaused(paused: Bool)
    case sweepStatuses
    case startSweep(kind: SweepKind, preparation: SweepPreparation)

    /// Asking again changes nothing: it is safe to ask a second time
    /// when the first try was lost with its connection. A request that
    /// changes the library is never asked twice on the client's own
    /// say-so — the first may have landed.
    public var onlyReads: Bool {
        switch self {
        case .sourceStates, .browseVocabulary, .sidebarCounts, .pendingDuplicateCount, .savedFilters,
             .savedFilterCounts, .tileMenuFacts, .thumbnailQueueStatus, .storedThumbnail, .listing, .playable,
             .opened,
             .itemTags, .tagging, .segments, .searchContext, .recentlyWatched, .items, .queueItems,
             .tagMembership, .pendingTextScan, .textLines, .fullVocabulary, .tagUsageCounts, .tagDetails, .categories,
             .categoryTable, .vocabularyIndex, .fields, .fieldValues, .takenNames, .watchHistory,
             .signalSummary, .unsavedSegments, .reviewLists, .mergeableTags, .unsavedSegmentsOfMarked,
             // Asking how the repair queue stands may start it, and a
             // queue started twice is a queue started: safe to ask again.
             .playbackIssueEvidence, .repairQueue, .maintenanceSnapshot, .previewWriteback,
             // Like the repair queue: asking may start it, and asking again is the same.
             .organisePlan, .moveSessions, .jobQueue, .libraryProperties,
             .itemAnalysis, .metadataSweepState, .analysisRules, .ruleCovering, .dryRun, .dryRuns,
             .jsonSchemas, .existingTags, .job,
             // A scan lists a folder and a probe measures a file; neither writes.
             .importOverview, .scanSource, .probeFile, .importBoxes, .jobLane, .sweepStatuses,
             .libraryInfo, .searchSettings:
            true
        default:
            false
        }
    }
}

extension ServiceRequest {
    /// Why this request is not carried out for another Mac, or nil when
    /// it is. A device that is paired can do with the library what the
    /// app's windows do — with the exception of what would let it reach
    /// outside the library, onto the rest of the host's disk.
    public var refusalForAnotherMac: String? {
        switch self {
        case .addSource:
            // A source is a folder on the host. Named from elsewhere it
            // could be any folder the host's user can read.
            return "A source is a folder on the Mac that holds the library, and is added there."
        case .run(.joinFolder(_, let folderPath), _), .run(.joinItems(_, let folderPath, _), _):
            // Inside a source, as the library spells it: nothing that
            // climbs out, and nothing absolute.
            guard MediaPath.normalize(folderPath) == folderPath, !folderPath.hasPrefix("/") else {
                return "That is not a folder of one of the library's sources."
            }
            return nil
        case .run(.importFiles(_, let relativePaths, _), _):
            // The same for the files of an import: each is a path inside
            // its source, as a scan lists them.
            guard relativePaths.allSatisfy(Self.isInsideASource) else {
                return "That is not a file of one of the library's sources."
            }
            return nil
        case .probeFile(_, let relativePath):
            guard Self.isInsideASource(relativePath) else {
                return "That is not a file of one of the library's sources."
            }
            return nil
        case .queueRepair(_, let recipe):
            // A recipe is a tool and its command line, run here as this
            // Mac's user. One written on the other Mac could name any
            // program; only the recipes the app ships, unchanged, are run
            // for another Mac. This Mac's own recipes are run from here.
            guard RepairRecipe.shipped.contains(where: {
                $0.tool == recipe.tool && $0.argumentTemplate == recipe.argumentTemplate
            }) else {
                return "Only the repairs the app comes with can be run from another Mac. Run this one on the Mac that holds the library."
            }
            return nil
        default:
            return nil
        }
    }

    private static func isInsideASource(_ path: String) -> Bool {
        !path.isEmpty && MediaPath.normalize(path) == path && !path.hasPrefix("/")
    }

    /// Carry the request out on a library, and encode what came of it.
    /// An operation that returns nothing answers with nothing.
    func answer(with service: any LibraryService) async throws -> Data {
        func json<T: Encodable>(_ value: T) throws -> Data { try RemoteProtocol.encode(value) }
        let nothing = Data()

        switch self {
        case .sourceStates:
            return try json(await service.sourceStates())
        case .browseVocabulary:
            return try json(await service.browseVocabulary())
        case .sidebarCounts(let kinds):
            return try json(await service.sidebarCounts(kinds: kinds))
        case .pendingDuplicateCount:
            return try json(await service.pendingDuplicateCount())
        case .savedFilters:
            return try json(await service.savedFilters())
        case .savedFilterCounts(let kinds):
            return try json(await service.savedFilterCounts(kinds: kinds))
        case .tileMenuFacts(let snapshotsPerItem):
            return try json(await service.tileMenuFacts(snapshotsPerItem: snapshotsPerItem))
        case .thumbnailQueueStatus:
            return try json(await service.thumbnailQueueStatus())
        case .storedThumbnail(let itemID):
            return try json(await service.storedThumbnail(itemID: itemID))

        case .listing(let request):
            return try json(await service.listing(request))

        case .renameSource(let id, let name):
            try await service.renameSource(id, to: name)
            return nothing
        case .setSourceEnabled(let id, let enabled):
            try await service.setSourceEnabled(id, enabled)
            return nothing
        case .addSource(let name, let rootPath):
            return try json(await service.addSource(named: name, rootPath: rootPath))
        case .saveFilter(let name, let filter):
            return try json(await service.saveFilter(named: name, filter))
        case .updateSavedFilter(let id, let filter):
            try await service.updateSavedFilter(id, to: filter)
            return nothing
        case .renameSavedFilter(let id, let name):
            try await service.renameSavedFilter(id, to: name)
            return nothing
        case .deleteSavedFilter(let id):
            try await service.deleteSavedFilter(id)
            return nothing
        case .assignTag(let tagID, let itemIDs):
            try await service.assignTag(tagID, to: itemIDs)
            return nothing
        case .removeTag(let tagID, let itemIDs):
            try await service.removeTag(tagID, from: itemIDs)
            return nothing
        case .setFavorite(let itemIDs, let isFavorite):
            try await service.setFavorite(itemIDs, isFavorite)
            return nothing
        case .setNeedsReview(let itemIDs, let needsReview):
            try await service.setNeedsReview(itemIDs, needsReview)
            return nothing
        case .setStaging(let folder, let on, let itemIDs):
            return try json(await service.setStaging(folder, on: on, itemIDs: itemIDs))

        case .run(let request, let wait):
            return try json(await service.run(request, wait: wait))

        case .playable(let itemID):
            return try json(await service.playable(itemID: itemID))
        case .opened(let itemID):
            return try json(await service.opened(itemID: itemID))
        case .itemTags(let itemID):
            return try json(await service.itemTags(itemID: itemID))
        case .tagging(let itemID):
            return try json(await service.tagging(itemID: itemID))
        case .segments(let parentID):
            return try json(await service.segments(parentID: parentID))
        case .searchContext(let itemID):
            return try json(await service.searchContext(itemID: itemID))
        case .recentlyWatched(let limit):
            return try json(await service.recentlyWatched(limit: limit))
        case .items(let ids):
            return try json(await service.items(ids: ids))
        case .queueItems(let definition):
            return try json(await service.queueItems(definition))
        case .tagMembership(let itemIDs):
            return try json(await service.tagMembership(itemIDs: itemIDs))
        case .pendingTextScan(let itemID):
            return try json(await service.pendingTextScan(itemID: itemID))
        case .textLines(let itemID):
            return try json(await service.textLines(itemID: itemID))

        case .recordPlayback(let event):
            try await service.recordPlayback(event)
            return nothing
        case .setFlag(let flag, let on, let itemID):
            return try json(await service.setFlag(flag, on, itemID: itemID))
        case .toggleTag(let tagID, let itemID):
            return try json(await service.toggleTag(tagID, on: itemID))
        case .renameTag(let tagID, let name):
            try await service.renameTag(tagID, to: name)
            return nothing
        case .ensureTag(let name, let categoryID):
            return try json(await service.ensureTag(named: name, inCategory: categoryID))
        case .addAlias(let alias, let tagID):
            try await service.addAlias(alias, toTag: tagID)
            return nothing
        case .setCategoryOrder(let categoryIDs):
            try await service.setCategoryOrder(categoryIDs)
            return nothing
        case .setKeyBinding(let key, let tagID, let advance):
            try await service.setKeyBinding(key, tagID: tagID, advance: advance)
            return nothing
        case .removeKeyBinding(let key):
            try await service.removeKeyBinding(key)
            return nothing
        case .createSegment(let parentID, let name, let startSeconds, let endSeconds, let role):
            return try json(await service.createSegment(
                parentID: parentID, name: name, startSeconds: startSeconds, endSeconds: endSeconds, role: role))
        case .renameSegment(let itemID, let name):
            try await service.renameSegment(itemID, to: name)
            return nothing
        case .deleteSegment(let itemID):
            try await service.deleteSegment(itemID)
            return nothing
        case .addBlock(let itemID, let startSeconds, let endSeconds, let kind):
            return try json(await service.addBlock(
                to: itemID, startSeconds: startSeconds, endSeconds: endSeconds, kind: kind))
        case .deleteBlock(let blockID):
            try await service.deleteBlock(blockID)
            return nothing
        case .setSearchFormats(let formats, let replacingUnreadable):
            try await service.setSearchFormats(formats, replacingUnreadable: replacingUnreadable)
            return nothing

        case .fullVocabulary:
            return try json(await service.fullVocabulary())
        case .tagUsageCounts(let categoryID):
            return try json(await service.tagUsageCounts(categoryID: categoryID))
        case .tagDetails(let tagID):
            return try json(await service.tagDetails(tagID: tagID))
        case .setTagFavorite(let tagID, let isFavorite):
            try await service.setTagFavorite(tagID, isFavorite)
            return nothing
        case .convertTagToAlias(let tagID, let targetID):
            try await service.convertTagToAlias(tagID, of: targetID)
            return nothing
        case .replaceTag(let tagID, let targetID, let itemID):
            try await service.replaceTag(tagID, with: targetID, on: itemID)
            return nothing
        case .deleteTag(let tagID):
            try await service.deleteTag(tagID)
            return nothing
        case .removeAlias(let alias, let tagID):
            try await service.removeAlias(alias, fromTag: tagID)
            return nothing
        case .saveTag(let draft):
            return try json(await service.saveTag(draft))

        case .categories:
            return try json(await service.categories())
        case .categoryTable(let categoryID):
            return try json(await service.categoryTable(categoryID: categoryID))
        case .vocabularyIndex:
            return try json(await service.vocabularyIndex())
        case .fields(let scope, let categoryID):
            return try json(await service.fields(scope: scope, categoryID: categoryID))
        case .fieldValues(let tagID):
            return try json(await service.fieldValues(tagID: tagID))
        case .takenNames(let categoryID):
            return try json(await service.takenNames(categoryID: categoryID))
        case .createCategory(let category):
            try await service.createCategory(category)
            return nothing
        case .updateCategory(let category):
            try await service.updateCategory(category)
            return nothing
        case .deleteCategory(let categoryID):
            try await service.deleteCategory(categoryID)
            return nothing
        case .mergeTags(let sourceIDs, let target):
            return try json(await service.mergeTags(sourceIDs, into: target))
        case .setTagHidden(let tagID, let hidden):
            try await service.setTagHidden(tagID, hidden)
            return nothing
        case .setTagNotes(let tagID, let notes):
            try await service.setTagNotes(tagID, notes)
            return nothing
        case .setFieldValue(let value, let tagID, let field):
            try await service.setFieldValue(value, tagID: tagID, field: field)
            return nothing
        case .createField(let field):
            return try json(await service.createField(field))
        case .deleteField(let fieldID):
            try await service.deleteField(fieldID)
            return nothing

        case .watchHistory(let limit):
            return try json(await service.watchHistory(limit: limit))
        case .signalSummary(let itemID):
            return try json(await service.signalSummary(itemID: itemID))
        case .unsavedSegments(let itemIDs):
            return try json(await service.unsavedSegments(itemIDs: itemIDs))
        case .runNextAndWait(let jobID):
            try await service.runNextAndWait(jobID: jobID)
            return nothing
        case .job(let id):
            return try json(await service.job(id: id))
        case .cancelJob(let id):
            try await service.cancelJob(id: id)
            return nothing
        case .wakeWorkers:
            try await service.wakeWorkers()
            return nothing

        case .reviewLists:
            return try json(await service.reviewLists())
        case .mergeableTags(let keeperID, let loserID):
            return try json(await service.mergeableTags(keeperID: keeperID, loserID: loserID))
        case .decideDuplicate(let keeperID, let loserID, let candidateID, let mergeTagIDs):
            return try json(await service.decideDuplicate(
                keeperID: keeperID, loserID: loserID, candidateID: candidateID, mergeTagIDs: mergeTagIDs))
        case .rejectDuplicate(let candidateID):
            try await service.rejectDuplicate(candidateID: candidateID)
            return nothing
        case .keepBothDuplicates(let candidateID):
            try await service.keepBothDuplicates(candidateID: candidateID)
            return nothing
        case .unsavedSegmentsOfMarked(let itemIDs):
            return try json(await service.unsavedSegmentsOfMarked(itemIDs: itemIDs))
        case .purgeMarked(let itemIDs):
            return try json(await service.purgeMarked(itemIDs: itemIDs))
        case .playbackIssueEvidence(let itemID):
            return try json(await service.playbackIssueEvidence(itemID: itemID))
        case .queueRepair(let itemID, let recipe):
            return try json(await service.queueRepair(itemID: itemID, recipe: recipe))
        case .repairQueue(let startingQueue):
            return try json(await service.repairQueue(startingQueue: startingQueue))

        case .maintenanceSnapshot(let includingBackups):
            return try json(await service.maintenanceSnapshot(includingBackups: includingBackups))
        case .acceptDiskSize(let itemID):
            try await service.acceptDiskSize(itemID: itemID)
            return nothing
        case .previewWriteback(let itemIDs):
            return try json(await service.previewWriteback(itemIDs: itemIDs))
        case .backUp:
            return try json(await service.backUp())

        case .organisePlan(let template, let itemIDs):
            return try json(await service.organisePlan(template: template, itemIDs: itemIDs))
        case .moveSessions:
            return try json(await service.moveSessions())
        case .revertMove(let logID):
            try await service.revertMove(logID: logID)
            return nothing
        case .revertMoveSession(let sessionID):
            return try json(await service.revertMoveSession(sessionID: sessionID))
        case .jobQueue(let kind, let startingQueue):
            return try json(await service.jobQueue(kind: kind, startingQueue: startingQueue))

        case .libraryProperties:
            return try json(await service.libraryProperties())
        case .libraryInfo:
            return try json(await service.libraryInfo())
        case .searchSettings:
            return try json(await service.searchSettings())
        case .renameLibrary(let name):
            try await service.renameLibrary(to: name)
            return nothing
        case .setSeparatorCharacters(let characters):
            try await service.setSeparatorCharacters(characters)
            return nothing
        case .setExtensionOverrides(let video, let audio):
            try await service.setExtensionOverrides(video: video, audio: audio)
            return nothing

        case .itemAnalysis(let itemID):
            return try json(await service.itemAnalysis(itemID: itemID))
        case .markAnalyzed(let itemID):
            try await service.markAnalyzed(itemID: itemID)
            return nothing
        case .metadataSweepState(let itemID):
            return try json(await service.metadataSweepState(itemID: itemID))
        case .resetMetadataSweep(let itemIDs):
            try await service.resetMetadataSweep(itemIDs: itemIDs)
            return nothing
        case .existingTags(let lines):
            return try json(await service.existingTags(inLines: lines))
        case .analysisRules:
            return try json(await service.analysisRules())
        case .saveAnalysisRule(let rule):
            try await service.saveAnalysisRule(rule)
            return nothing
        case .deleteAnalysisRule(let id):
            try await service.deleteAnalysisRule(id: id)
            return nothing
        case .moveAnalysisRule(let id, let up):
            try await service.moveAnalysisRule(id: id, up: up)
            return nothing
        case .ruleCovering(let key, let value):
            return try json(await service.ruleCovering(key: key, value: value))
        case .dryRun(let rule):
            return try json(await service.dryRun(of: rule))
        case .dryRuns(let rules):
            return try json(await service.dryRuns(of: rules))
        case .applyAnalysisRule(let rule):
            return try json(await service.applyAnalysisRule(rule))
        case .jsonSchemas:
            return try json(await service.jsonSchemas())
        case .saveJsonSchema(let id, let name, let keys):
            return try json(await service.saveJsonSchema(id: id, named: name, keys: keys))
        case .deleteJsonSchema(let id):
            try await service.deleteJsonSchema(id: id)
            return nothing

        case .importOverview:
            return try json(await service.importOverview())
        case .scanSource(let sourceID):
            return try json(await service.scanSource(sourceID: sourceID))
        case .probeFile(let sourceID, let relativePath):
            return try json(await service.probeFile(sourceID: sourceID, relativePath: relativePath))
        case .importBoxes:
            return try json(await service.importBoxes())
        case .setImportBoxes(let boxes):
            try await service.setImportBoxes(boxes)
            return nothing
        case .enableExtension(let fileExtension):
            try await service.enableExtension(fileExtension)
            return nothing

        case .jobLane(let limit):
            return try json(await service.jobLane(limit: limit))
        case .moveJobToFront(let id):
            try await service.moveJobToFront(id: id)
            return nothing
        case .retryJob(let id):
            try await service.retryJob(id: id)
            return nothing
        case .clearFinishedJobs:
            try await service.clearFinishedJobs()
            return nothing
        case .setQueuePaused(let paused):
            try await service.setQueuePaused(paused)
            return nothing
        case .sweepStatuses:
            return try json(await service.sweepStatuses())
        case .startSweep(let kind, let preparation):
            try await service.startSweep(kind, after: preparation)
            return nothing
        }
    }
}
