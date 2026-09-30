import Foundation
import Observation
import SightsAndSoundsKit

/// Organise's plan: what a template would do to a set of items.
///
/// Making it reads two rows per item across every video, and it is remade
/// whenever the template, the listing or the library's items change. It
/// ran on the main actor, so an unscoped window stalled through an import.
/// Now it is made off the main actor, and only the newest request lands —
/// an older plan finishing last must not replace it.
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

    private var generation = 0

    func preview(template: String, ids: [UUID], categoryNames: [String], library: LibraryDatabase) {
        generation += 1
        let generation = generation
        validationErrors = OrganizeTemplate.validate(template, categoryNames: categoryNames).map(\.message)
        guard validationErrors.isEmpty else {
            plan = []
            plannedIDs = []
            plannedTemplate = ""
            return
        }
        let make = makePlan
        Task {
            let made = try? await Task.detached(priority: .userInitiated) {
                try await make(library, template, ids)
            }.value
            guard generation == self.generation else { return }
            plan = made ?? []
            plannedIDs = ids
            plannedTemplate = template
        }
    }
}
