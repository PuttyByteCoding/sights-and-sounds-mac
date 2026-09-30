import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// Organise made its plan on the main actor — two queries per item over
/// every video — and remade it on each listing refresh and again on each
/// items change, so an unscoped window stalled through an import. The
/// plan is now made off the main actor and only the newest one lands.
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

    @Test func thePlanIsMadeOffTheMainActorAndTheNewestLands() async throws {
        let (planner, plans, library) = try planner()
        let first = [UUID()], second = [UUID(), UUID()]
        planner.preview(template: "%Band", ids: first, categoryNames: ["Band"], library: library)
        planner.preview(template: "%Band/Live", ids: second, categoryNames: ["Band"], library: library)
        try await waitUntil { plans.started == 2 }
        #expect(planner.plannedIDs.isEmpty, "nothing lands while the plans are held")
        plans.open()
        try await waitUntil { !planner.plannedIDs.isEmpty }
        try await Task.sleep(for: .milliseconds(100))
        #expect(planner.plannedIDs == second)
        #expect(planner.plannedTemplate == "%Band/Live", "Move must apply the template its plan was made for")
        #expect(plans.onMain == 0, "a plan was made on the main thread")
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
