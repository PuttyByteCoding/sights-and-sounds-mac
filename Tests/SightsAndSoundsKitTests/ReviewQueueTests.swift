import Foundation
import Testing
@testable import SightsAndSoundsKit

/// The three review queues: a reviewed subset that purges exactly what
/// was ticked, evidence that survives the moment it was captured, and
/// repair recipes as data.
@Suite struct ReviewQueueTests {

    // MARK: - Purge

    /// A reviewed subset purges exactly what was ticked — and the FLAG
    /// stays the guard, so a stale list cannot take a file nobody marked.
    @Test func purgingASubsetTakesOnlyThatSubset() throws {
        let f = try FilterFixture()
        try f.library.writer.write { db in
            try db.execute(
                sql: "UPDATE mediaItem SET markedForDeletion = 1 WHERE id IN (?, ?)",
                arguments: [f.show2001.id, f.underscoreDir.id])
        }
        let outcome = try f.library.purgeDeleted(
            itemIDs: [f.show2001.id], fileAccess: PretendFiles())
        #expect(outcome.rowsDeleted == 1)
        // The other flagged item is untouched.
        #expect(try f.names(MediaFilter()).contains("f.mp4"))
        #expect(!(try f.names(MediaFilter()).contains("c.mp4")))
    }

    @Test func purgingRefusesAnythingNotFlagged() throws {
        let f = try FilterFixture()
        let outcome = try f.library.purgeDeleted(
            itemIDs: [f.show1995.id], fileAccess: PretendFiles())
        #expect(outcome.rowsDeleted == 0)
        #expect(try f.names(MediaFilter()).contains("a.mp4"))
    }

    @Test func reclaimableBytesSumTheFlaggedRows() throws {
        let f = try FilterFixture()
        try f.library.writer.write { db in
            try db.execute(
                sql: "UPDATE mediaItem SET markedForDeletion = 1, fileSize = 1000 WHERE id = ?",
                arguments: [f.show2001.id])
        }
        #expect(try f.library.reclaimableBytes() == 1000)
    }

    // MARK: - Keep both

    /// Keep both is not Not-duplicates: the match was right, and both
    /// copies are wanted. Either way the row survives so the sweeps
    /// cannot re-flag the pair.
    @Test func keepBothLeavesTheQueueWithoutStagingEither() throws {
        let f = try FilterFixture()
        let candidate = DuplicateCandidate(
            itemA: f.show1995.id, itemB: f.show2001.id, source: .fingerprint)
        try f.library.writer.write { try candidate.insert($0) }

        try f.library.keepBothCandidate(candidate.id)
        #expect(try f.library.pendingCandidates().isEmpty)
        let stored = try f.library.writer.read {
            try DuplicateCandidate.fetchOne($0, key: candidate.id)
        }
        #expect(stored?.status == .keptBoth)
        // Neither file was staged.
        let items = try f.library.writer.read { db in
            try MediaItem.fetchAll(db, keys: [f.show1995.id, f.show2001.id])
        }
        #expect(items.allSatisfy { !$0.markedForDeletion })
    }

    // MARK: - Evidence

    /// Probe output is classified so recipes can match it. Substring
    /// matching on ffmpeg's own stable strings.
    @Test func probeOutputIsClassified() {
        #expect(PlaybackFailureKind.classify("moov atom not found") == .missingIndex)
        #expect(PlaybackFailureKind.classify("Invalid data found when processing input") == .truncated)
        #expect(PlaybackFailureKind.classify("Error while decoding stream #0:0") == .badStream)
        #expect(PlaybackFailureKind.classify("all fine here") == .unknown)
    }

    @Test func evidenceStoresBesideTheItemAndCascades() throws {
        let f = try FilterFixture()
        let evidence = PlaybackIssueEvidence(
            mediaItemID: f.show2001.id,
            probeOutput: "moov atom not found",
            failureKind: PlaybackFailureKind.missingIndex.rawValue)
        try f.library.writer.write { try evidence.insert($0) }
        #expect(try f.library.playbackIssueEvidence(of: f.show2001.id)?.failureKind
            == PlaybackFailureKind.missingIndex.rawValue)

        // Deleting the item takes its evidence with it.
        try f.library.writer.write { db in
            _ = try MediaItem.deleteOne(db, key: f.show2001.id)
        }
        #expect(try f.library.playbackIssueEvidence(of: f.show2001.id) == nil)
    }

    // MARK: - Recipes

    @Test func recipesMatchAFailureKindPlusTheCatchAlls() throws {
        let app = try AppDatabase.openInMemory()
        try app.seedRepairRecipes()
        let forIndex = try app.repairRecipes(
            forFailureKind: PlaybackFailureKind.missingIndex.rawValue)
        #expect(forIndex.contains { $0.name.contains("index") })
        // The last-resort re-encode matches anything, and sorts last.
        #expect(forIndex.last?.risk == .lossy)
        // Cheapest first.
        #expect(forIndex.first?.risk == .lossless)
    }

    @Test func seedingIsIdempotentBecauseRecipesAreEditableData() throws {
        let app = try AppDatabase.openInMemory()
        try app.seedRepairRecipes()
        var recipe = try app.repairRecipes()[0]
        recipe.name = "Renamed by hand"
        try app.saveRepairRecipe(recipe)
        try app.seedRepairRecipes()
        #expect(try app.repairRecipes().contains { $0.name == "Renamed by hand" })
        #expect(try app.repairRecipes().count == RepairRecipe.shipped.count)
    }

    @Test func aRecipeRendersTheCommandItWillRun() {
        let recipe = RepairRecipe.shipped[0]
        let command = recipe.command(input: "/in.mp4", output: "/out.mp4")
        #expect(command.hasPrefix("ffmpeg"))
        #expect(command.contains("/in.mp4"))
        #expect(command.contains("/out.mp4"))
        #expect(!command.contains("{input}"))
    }
}

/// A file boundary where everything is present and removal is a no-op:
/// these tests are about which ROWS a purge takes, not about the disk.
private struct PretendFiles: FileAccess {
    func isReachable(_ url: URL) -> Bool { true }
    func contentsOfDirectory(at url: URL) throws -> [URL] { [] }
    func allFiles(under url: URL) throws -> [URL] { [] }
    func fileSize(at url: URL) throws -> Int64 { 0 }
    func readFile(at url: URL, chunk: (Data) throws -> Void) throws {}
    func moveFile(at url: URL, to destination: URL) throws {}
    func removeFile(at url: URL) throws {}
}

/// Tools declared once, recipes that arrive disabled, and a narrower
/// match than a whole failure kind.
@Suite struct RepairConfigurationTests {

    @Test func aDisabledRecipeIsNeverOffered() throws {
        let app = try AppDatabase.openInMemory()
        try app.seedRepairRecipes()
        var recipe = try app.repairRecipes()[0]
        recipe.enabled = false
        try app.saveRepairRecipe(recipe)
        let offered = try app.repairRecipes(
            forFailureKind: recipe.matchesFailureKind, probeOutput: "moov atom not found")
        #expect(!offered.contains { $0.id == recipe.id })
    }

    /// A pattern narrows a recipe below a whole failure kind — and a
    /// recipe with one is not offered when there is nothing to match
    /// against.
    @Test func aMatchPatternNarrowsARecipe() throws {
        let app = try AppDatabase.openInMemory()
        try app.saveRepairRecipe(RepairRecipe(
            name: "untrunc", matchPattern: "moov atom not found",
            tool: "untrunc", argumentTemplate: ["{input}", "{output}"],
            estimate: "minutes"))
        #expect(try app.repairRecipes(
            forFailureKind: nil, probeOutput: "moov atom not found").count == 1)
        #expect(try app.repairRecipes(
            forFailureKind: nil, probeOutput: "something else").isEmpty)
        #expect(try app.repairRecipes(forFailureKind: nil).isEmpty)
    }

    @Test func aToolRemembersWhereItWasAndWhetherItIsThere() throws {
        let app = try AppDatabase.openInMemory()
        try app.saveExternalTool(ExternalTool(name: "untrunc"))
        #expect(try app.externalTools().first?.isAvailable == false)
        try app.saveExternalTool(
            ExternalTool(name: "untrunc", path: "/usr/local/bin/untrunc", version: "1.0"))
        #expect(try app.externalTools().first?.isAvailable == true)
        #expect(try app.externalTools().first?.version == "1.0")
    }
}
