import Foundation
import Testing

@testable import SightsAndSoundsKit

/// `RepairJob`'s refusals.
///
/// The job's whole promise is that the original is never the thing at
/// risk, so the paths worth pinning are the ones that stop *before* any
/// file is touched: a clip has no file to repair, and an item that no
/// longer exists has nothing to repair. Both must fail with a message
/// that says which case it was — a repair that stops for a reason nobody
/// can read is the same as one that stopped for no reason.
///
/// The success path runs ffmpeg against a real file and is covered by the
/// operations tests instead; there is nothing to assert here that would
/// not just be asserting ffmpeg exists.
@Suite struct RepairJobTests {

    private func record(_ library: LibraryDatabase, _ id: UUID) throws -> JobRecord {
        try library.writer.read { try JobRecord.fetchOne($0, key: id)! }
    }

    /// A clip is a range of its parent, not a file. Repairing one has to
    /// say so and point at the item that does have a file — this used to
    /// throw `ClipError.notAClip`, whose message ("this item is not an
    /// embedded clip") was the exact opposite of the condition that threw it.
    @Test func repairingAClipIsRefusedAndPointsAtTheParent() async throws {
        let f = try FilterFixture()
        let runner = JobRunner(library: f.library)
        await runner.register(RepairJob.self)

        let queued = try await RepairJob.enqueue(
            on: runner, itemID: f.embeddedClip.id, recipe: RepairRecipe.shipped[0])
        try await runner.runPending()

        let failed = try record(f.library, queued.id)
        #expect(failed.state == .failed)
        #expect(failed.error?.contains("clip") == true)
        // The advice is the point: repair the thing that has a file.
        #expect(failed.error?.contains("repair the item it was cut from") == true)
        // And it must NOT claim the item is not a clip, which is what it
        // said before.
        #expect(failed.error?.contains("is not an embedded clip") == false)
    }

    @Test func repairingAnItemThatIsGoneFailsWithoutTouchingAnything() async throws {
        let f = try FilterFixture()
        let runner = JobRunner(library: f.library)
        await runner.register(RepairJob.self)

        let queued = try await RepairJob.enqueue(
            on: runner, itemID: UUID(), recipe: RepairRecipe.shipped[0])
        try await runner.runPending()

        let failed = try record(f.library, queued.id)
        #expect(failed.state == .failed)
        #expect(failed.error?.contains("no longer exists") == true)
    }

    /// Queued rows outlive code, so the kind string is a compatibility
    /// surface — renaming it strands every repair already in the queue.
    @Test func theKindIsStableBecauseQueuedRowsOutliveCode() {
        #expect(RepairJob.kind == "operations.repair")
    }

    @Test func thePayloadCarriesTheWholeRecipeNotJustItsID() throws {
        let recipe = RepairRecipe.shipped[3]
        let data = try JSONEncoder().encode(
            RepairJob.Payload(itemID: UUID(), recipe: recipe))
        let job = try RepairJob(payload: data)
        // The recipe travels with the job: editing the row afterwards must
        // not change what an already-queued repair will run.
        #expect(job.payload.recipe == recipe)
        #expect(job.payload.recipe.risk == .lossy)
    }

    @Test func aJobWithNoPayloadRefusesToConstruct() {
        #expect(throws: (any Error).self) { try RepairJob(payload: nil) }
    }

    /// Both failure messages promise the original survived. That sentence
    /// is the reason the fix is offered without a confirmation in front of
    /// it, so it is worth a test.
    @Test func theSafetyPromiseIsInTheFailureMessages() {
        #expect(RepairError.toolMissing("untrunc").description.contains("original is untouched"))
        #expect(RepairError.resultUnplayable.description.contains("original is untouched"))
        #expect(RepairError.toolMissing("untrunc").description.contains("untrunc"))
    }
}
