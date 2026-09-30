import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// Organise made its plan on the main actor — two queries per item over
/// every video — and remade it on each listing refresh and again on each
/// items change, so an unscoped window stalled through an import. The
/// plan is now made off the main actor, one walk at a time. A plan lands
/// only if it was made with the template in the field — a newer listing
/// with the same template does not stop it, an older template always does.
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

    /// Move applies the plan on screen. While a newer request is still
    /// being planned that plan is out of date, and Move must say so by
    /// being unavailable: it would move files by the old template.
    @Test func thePlanIsNotCurrentWhileANewerOneIsBeingMade() async throws {
        let (planner, plans, library) = try planner()
        plans.open()
        planner.preview(template: "%Band", ids: [UUID()], categoryNames: ["Band"], library: library)
        try await waitUntil { planner.isCurrent }
        #expect(planner.plannedTemplate == "%Band")

        let held = GatedPlans()
        planner.makePlan = held.make
        planner.preview(template: "%Band/Live", ids: [UUID()], categoryNames: ["Band"], library: library)
        #expect(!planner.isCurrent, "the old plan still counts as current right after the edit")
        try await waitUntil { held.started == 1 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(!planner.isCurrent, "the old plan counts as current while the new one is made")
        #expect(planner.plannedTemplate == "%Band")

        held.open()
        try await waitUntil { planner.isCurrent }
        #expect(planner.plannedTemplate == "%Band/Live")
    }

    @Test func anInvalidTemplateMakesNoPlanAndDropsOneInFlight() async throws {
        let (planner, plans, library) = try planner()
        planner.preview(template: "%Band", ids: [UUID()], categoryNames: ["Band"], library: library)
        try await waitUntil { plans.started == 1 }
        planner.preview(template: "", ids: [UUID()], categoryNames: ["Band"], library: library)
        #expect(!planner.validationErrors.isEmpty)
        #expect(planner.isCurrent, "nothing is being made: the errors say why Move is unavailable")
        #expect(plans.started == 1)

        // Walks run one at a time, so a later request's walk starts only
        // once the held walk has finished and decided whether to land.
        // Holding that later walk at a second gate leaves the moment in
        // between to look at — whatever the timing.
        let later = GatedPlans()
        planner.makePlan = later.make
        plans.open()
        planner.preview(template: "%Band/Live", ids: [UUID()], categoryNames: ["Band"], library: library)
        try await waitUntil { later.started == 1 }
        #expect(planner.plannedIDs.isEmpty, "a plan for the template before the bad one landed")
        later.open()
        try await waitUntil { planner.plannedTemplate == "%Band/Live" }
    }

    /// An import refreshes the listing several times a second, and each
    /// refresh asks for a plan with the same template. Move stays usable
    /// through it — the plan on screen is for the template in the field —
    /// and plans still land rather than waiting for the import to stop.
    @Test(.timeLimit(.minutes(1)))
    func aSteadyStreamOfRequestsForOneTemplateKeepsLandingPlans() async throws {
        let (planner, plans, library) = try planner()
        plans.open()
        planner.preview(template: "%Band", ids: [UUID()], categoryNames: ["Band"], library: library)
        try await waitUntil { planner.isCurrent && !planner.plannedIDs.isEmpty }
        let before = plans.started

        // Streams until a newer plan lands (bounded), so a slow pool only
        // makes the stream longer, never the test fail. Every request is
        // still arriving 50 ms after the last when the plan lands.
        let first = planner.plannedIDs
        var alwaysCurrent = true
        var landedMidStream = false
        for _ in 0..<400 where !landedMidStream {
            planner.preview(template: "%Band", ids: [UUID()], categoryNames: ["Band"], library: library,
                            settle: .milliseconds(300))
            alwaysCurrent = alwaysCurrent && planner.isCurrent
            try await Task.sleep(for: .milliseconds(50))
            landedMidStream = planner.plannedIDs != first
        }
        #expect(alwaysCurrent, "Move went unavailable though the template never changed")
        #expect(plans.started > before, "no plan was made while the requests kept coming")
        #expect(landedMidStream, "the plan on screen never moved while the requests kept coming")
    }

    /// A request replaced in the same turn never runs. An immediate one
    /// (opening the window) replaced by a settling one (the listing
    /// arriving) used to run anyway and drop its replacement's handle; that
    /// orphaned settle could not be cancelled, and it walked the next
    /// request long before that request's own pause was over.
    @Test func aReplacedRequestNeverRunsAndLeavesNoOrphanedSettle() async throws {
        let (planner, plans, library) = try planner()
        plans.open()
        let clock = ContinuousClock()
        let start = clock.now
        planner.preview(template: "%Band", ids: [UUID()], categoryNames: ["Band"], library: library)
        planner.preview(template: "%Band", ids: [UUID()], categoryNames: ["Band"], library: library,
                        settle: .milliseconds(150))
        try await Task.sleep(for: .milliseconds(50))
        let later = [UUID(), UUID()]
        let sent = clock.now
        planner.preview(template: "%Band", ids: later, categoryNames: ["Band"], library: library,
                        settle: .milliseconds(800))
        try await Task.sleep(for: .milliseconds(300))
        // Only meaningful when the machine kept time: a stall long enough
        // to make the burst overdue (sent more than 1.2 s after it began)
        // or to reach the 800 ms settle lands the plan legitimately.
        if sent - start < .milliseconds(1000), clock.now - sent < .milliseconds(700) {
            #expect(planner.plannedIDs != later, "an orphaned settle walked the request before its pause was over")
        }
        try await waitUntil { planner.plannedIDs == later }
    }

    @Test func aPlanThatFailsLeavesMoveAvailableOnNothing() async throws {
        let planner = OrganisePlanner()
        planner.makePlan = { _, _, _ in throw CancellationError() }
        planner.preview(template: "%Band", ids: [UUID()], categoryNames: ["Band"],
                        library: try LibraryDatabase.openInMemory())
        try await waitUntil { planner.isCurrent }
        #expect(planner.plan.isEmpty)
    }
}
