import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// Organise made its plan on the main actor — two queries per item over
/// every video — and remade it on each listing refresh and again on each
/// items change, so an unscoped window stalled through an import. The
/// plan is now made off the main actor, one walk at a time, and only the
/// newest request's plan lands.
@Suite @MainActor struct OrganisePlannerTests {
    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(25)) }
        #expect(condition())
    }

    /// Plans that wait at a gate the test opens, recording where they ran.
    /// A held plan is suspended, not blocking a thread.
    final class GatedPlans: @unchecked Sendable {
        private let lock = NSLock()
        private var isOpen = false
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private var counts = (started: 0, onMain: 0)

        var started: Int { lock.withLock { counts.started } }
        var onMain: Int { lock.withLock { counts.onMain } }

        func open() {
            let held = lock.withLock {
                isOpen = true
                defer { waiting = [] }
                return waiting
            }
            for plan in held { plan.resume() }
        }

        func make(_ library: LibraryDatabase, _ template: String, _ ids: [UUID]) async throws -> [ReorganizePlanEntry] {
            let main = Self.isMainThread()
            lock.withLock {
                counts.started += 1
                if main { counts.onMain += 1 }
            }
            await withCheckedContinuation { (plan: CheckedContinuation<Void, Never>) in
                let goNow = lock.withLock {
                    if isOpen { return true }
                    waiting.append(plan)
                    return false
                }
                if goNow { plan.resume() }
            }
            return []
        }

        private static func isMainThread() -> Bool { Thread.isMainThread }
    }

    private func planner() throws -> (OrganisePlanner, GatedPlans, LibraryDatabase) {
        let planner = OrganisePlanner()
        let plans = GatedPlans()
        planner.makePlan = plans.make
        return (planner, plans, try LibraryDatabase.openInMemory())
    }

    /// A plan cannot be stopped part-way, so a request arriving while one
    /// runs must not start a second beside it: each held a pool thread,
    /// and an import's listing refreshes piled them up faster than they
    /// finished. One runs; the newest request runs after it; only that lands.
    @Test func oneWalkAtATimeOffTheMainActorAndOnlyTheNewestLands() async throws {
        let (planner, plans, library) = try planner()
        let first = [UUID()], second = [UUID(), UUID()], third = [UUID(), UUID(), UUID()]
        planner.preview(template: "%Band", ids: first, categoryNames: ["Band"], library: library)
        try await waitUntil { plans.started == 1 }
        planner.preview(template: "%Band/Live", ids: second, categoryNames: ["Band"], library: library)
        planner.preview(template: "%Band/Encore", ids: third, categoryNames: ["Band"], library: library)
        try await Task.sleep(for: .milliseconds(200))
        #expect(plans.started == 1, "a request started a second walk beside the running one")
        #expect(planner.plannedIDs.isEmpty, "nothing lands while the walk is held")

        plans.open()
        try await waitUntil { !planner.plannedIDs.isEmpty }
        #expect(planner.plannedIDs == third, "the first plan to land was not the newest")
        #expect(planner.plannedTemplate == "%Band/Encore", "Move must apply the template its plan was made for")
        try await Task.sleep(for: .milliseconds(200))
        #expect(plans.started == 2, "one more walk, for the newest request only")
        #expect(plans.onMain == 0, "a plan was made on the main thread")
    }

    /// Listing refreshes come in bursts during an import; a burst inside the
    /// settle makes one walk, for its last request.
    @Test func aBurstOfRequestsInsideTheSettleMakesOneWalk() async throws {
        let (planner, plans, library) = try planner()
        plans.open()
        var last: [UUID] = []
        for _ in 0..<5 {
            last = [UUID()]
            planner.preview(template: "%Band", ids: last, categoryNames: ["Band"], library: library,
                            settle: .milliseconds(150))
        }
        try await waitUntil { !planner.plannedIDs.isEmpty }
        try await Task.sleep(for: .milliseconds(200))
        #expect(planner.plannedIDs == last)
        #expect(plans.started == 1)
    }

    @Test func anInvalidTemplateMakesNoPlanAndDropsOneInFlight() async throws {
        let (planner, plans, library) = try planner()
        planner.preview(template: "%Band", ids: [UUID()], categoryNames: ["Band"], library: library)
        try await waitUntil { plans.started == 1 }
        planner.preview(template: "", ids: [UUID()], categoryNames: ["Band"], library: library)
        #expect(!planner.validationErrors.isEmpty)
        plans.open()
        try await Task.sleep(for: .milliseconds(200))
        #expect(planner.plannedIDs.isEmpty, "a plan for the template before the bad one landed")
        #expect(plans.started == 1)
    }
}
