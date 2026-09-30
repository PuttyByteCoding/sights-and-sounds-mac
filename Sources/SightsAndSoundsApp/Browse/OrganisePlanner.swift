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
/// stale. When it ends, one more walk runs for the newest request, and
/// only a plan for the newest request lands.
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

    /// How a plan is made; tests hold it at a gate.
    var makePlan: @Sendable (LibraryDatabase, String, [UUID]) async throws -> [ReorganizePlanEntry] = {
        try $0.previewReorganize(template: $1, itemIDs: $2)
    }

    private struct Request {
        let generation: Int
        let template: String
        let ids: [UUID]
        let library: LibraryDatabase
    }

    /// Bumped by every request, valid or not: a plan lands only if it was
    /// made for the latest.
    private var generation = 0
    /// The newest request not yet walked.
    private var pending: Request?
    private var walking = false
    private var settling: Task<Void, Never>?

    /// Ask for a plan. `settle` waits for a pause first, so a burst of
    /// requests (listing refreshes during an import, typing) makes one.
    func preview(
        template: String, ids: [UUID], categoryNames: [String], library: LibraryDatabase,
        settle: Duration = .zero
    ) {
        generation += 1
        settling?.cancel()
        validationErrors = OrganizeTemplate.validate(template, categoryNames: categoryNames).map(\.message)
        guard validationErrors.isEmpty else {
            pending = nil
            plan = []
            plannedIDs = []
            plannedTemplate = ""
            return
        }
        pending = Request(generation: generation, template: template, ids: ids, library: library)
        settling = Task {
            if settle > .zero {
                try? await Task.sleep(for: settle)
                guard !Task.isCancelled else { return }
            }
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
                try await make(request.library, request.template, request.ids)
            }.value
            walking = false
            if request.generation == generation {
                plan = made ?? []
                plannedIDs = request.ids
                plannedTemplate = request.template
            } else {
                // Stale: a newer request is waiting (or was invalid and
                // cleared, in which case there is nothing to walk).
                startWalk()
            }
        }
    }
}
