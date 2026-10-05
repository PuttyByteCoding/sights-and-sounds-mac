import Foundation
import Observation
import SightsAndSoundsKit

/// Organise's plan: what a template would do to a set of items.
///
/// Making it reads two rows per item across every video, and it is asked
/// for whenever the template, the listing or the library's items change.
/// It ran on the main actor, so an unscoped window stalled through an
/// import. It now runs off the main actor, and like the Rules tab's dry
/// run, one walk at a time: a walk cannot be stopped part-way, and each
/// holds a pool thread, so a request arriving during one only marks it
/// stale. When it ends, one more walk runs for the newest request. A plan
/// lands only if it was made with the template in the field.
@Observable
@MainActor
final class OrganisePlanner {
    private(set) var plan: [ReorganizePlanEntry] = []
    /// The ids and template the plan on screen was made for. Move applies
    /// exactly these, not whatever the listing or the field holds by the
    /// time it is pressed.
    private(set) var plannedIDs: [UUID] = []
    private(set) var plannedTemplate = ""
    private(set) var validationErrors: [String] = []
    /// The plan on screen was made with the template in the field. Move
    /// applies the plan on screen, and its ids and template always travel
    /// together, so the one unsafe moment is a template edit whose plan
    /// has not landed: Move would move files by a template the field no
    /// longer shows. A newer listing with the same template is not that —
    /// an import changes the listing several times a second, and Move
    /// must stay usable through it.
    var isCurrent: Bool { latestTemplate.map { $0 == plannedTemplate } ?? true }

    /// The latest valid template asked for; nil while the field is invalid.
    private var latestTemplate: String?

    /// How a plan is made; tests hold it at a gate.
    var makePlan: @Sendable (any LibraryService, String, [UUID]) async throws -> [ReorganizePlanEntry] = {
        try await $0.organisePlan(template: $1, itemIDs: $2)
    }

    private struct Request {
        let template: String
        let ids: [UUID]
        let service: any LibraryService
    }

    /// The newest request not yet walked.
    private var pending: Request?
    /// A walk is running. Readable so tests can tell when one has ended
    /// and decided whether its plan lands (both happen in one turn).
    private(set) var walking = false
    private var settling: Task<Void, Never>?
    /// When the current burst of settling requests began. A steady stream
    /// (an import's listing refreshes) would otherwise push the settle back
    /// for as long as it lasts, and no plan would be made at all.
    private var burstStarted: ContinuousClock.Instant?
    static let longestSettle: Duration = .seconds(2)

    /// Ask for a plan. `settle` waits for a pause first, so a burst of
    /// requests (listing refreshes during an import, typing) makes one —
    /// but never waits more than `longestSettle` in all.
    func preview(
        template: String, ids: [UUID], categoryNames: [String], service: any LibraryService,
        settle: Duration = .zero
    ) {
        validationErrors = OrganizeTemplate.validate(template, categoryNames: categoryNames).map(\.message)
        guard validationErrors.isEmpty else {
            settling?.cancel()
            settling = nil
            burstStarted = nil
            pending = nil
            latestTemplate = nil
            plan = []
            plannedIDs = []
            plannedTemplate = ""
            return
        }
        latestTemplate = template
        pending = Request(template: template, ids: ids, service: service)

        let now = ContinuousClock.now
        let started = burstStarted ?? now
        burstStarted = started
        // Overdue: leave the settle already running to fire; it walks
        // whatever request is newest by then.
        // Counting this request's own pause, so the burst's first walk
        // starts within `longestSettle` of its first request.
        if settle > .zero, settling != nil, now - started + settle >= Self.longestSettle { return }
        settling?.cancel()
        settling = Task {
            if settle > .zero { try? await Task.sleep(for: settle) }
            // Also for an immediate request: one replaced in the same turn
            // must not run, or it drops its replacement's handle and leaves
            // that settle orphaned, uncancellable, walking early.
            guard !Task.isCancelled else { return }
            settling = nil
            burstStarted = nil
            startWalk()
        }
    }

    private func startWalk() {
        guard !walking, let request = pending else { return }
        pending = nil
        walking = true
        let make = makePlan
        Task {
            let made = try? await Task.detached(priority: .userInitiated) {
                try await make(request.service, request.template, request.ids)
            }.value
            walking = false
            // A plan for the template in the field lands even if newer
            // requests (a newer listing) arrived meanwhile: it is whole and
            // consistent, and under a steady stream no walk would otherwise
            // ever land. A plan for an older template never does.
            if request.template == latestTemplate {
                plan = made ?? []
                plannedIDs = request.ids
                plannedTemplate = request.template
            }
            // What arrived meanwhile is walked now only if its pause is
            // over. One still pausing is its own settle's to start; taken
            // up here it was walked the moment this ended, and under a
            // stream of requests each walk ran straight into the next.
            if settling == nil { startWalk() }
        }
    }

    /// The window closed: drop a request still settling and one waiting
    /// behind the running walk. A running walk cannot be stopped part-way;
    /// it ends on its own and nothing follows it.
    func cancel() {
        settling?.cancel()
        settling = nil
        burstStarted = nil
        pending = nil
    }
}
