import Foundation
import GRDB

/// One way to fix a broken file: what it matches, what it runs, roughly
/// what it costs, and how much it risks.
///
/// A recipe is **data**, not a switch statement in a view — so adding
/// "untrunc for truncated MP4s" is a settings change rather than a
/// release, and the Settings ▸ Repair pane has something to edit.
///
/// Every recipe inherits `RemuxJob`'s discipline: write to a temporary
/// file, re-probe it, and only then move the original aside. That is
/// what lets a fix be offered without a confirmation in front of it —
/// the original is never the thing at risk.
public struct RepairRecipe: Codable, Equatable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "repairRecipe"

    /// How much a fix costs you if it goes wrong.
    public enum Risk: String, Codable, Sendable, CaseIterable {
        /// A stream copy: the bits are unchanged.
        case lossless
        /// Re-encodes, losing a generation. Legitimate, and a last
        /// resort — the row says so where it is offered.
        case lossy

        public var displayName: String {
            switch self {
            case .lossless: "Lossless — stream copy"
            case .lossy: "Last resort — re-encodes"
            }
        }
    }

    public var id: UUID
    public var name: String
    /// A new recipe arrives **disabled**: it is a command line that will
    /// be run against real files, and the enable box is the "I have
    /// tested this" gesture.
    public var enabled: Bool
    /// An optional substring the probe output must contain, for a
    /// recipe that is narrower than a whole failure kind.
    public var matchPattern: String?
    /// The failure kind this addresses (`PlaybackFailureKind`), or nil
    /// for a recipe worth trying against anything.
    public var matchesFailureKind: String?
    /// The tool to run. Looked up on PATH at run time, so a recipe for a
    /// tool nobody installed is offered as unavailable rather than
    /// silently missing.
    public var tool: String
    /// Arguments with `{input}` and `{output}` placeholders.
    public var argumentTemplate: [String]
    /// Roughly how long, in words — "seconds", "about a minute per GB".
    public var estimate: String
    public var risk: Risk
    /// Cheapest first. The order the queue offers them in.
    public var sortOrder: Int
    public var notes: String

    public init(
        id: UUID = UUID(),
        name: String,
        enabled: Bool = true,
        matchPattern: String? = nil,
        matchesFailureKind: String? = nil,
        tool: String = "ffmpeg",
        argumentTemplate: [String],
        estimate: String,
        risk: Risk = .lossless,
        sortOrder: Int = 0,
        notes: String = ""
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.matchPattern = matchPattern
        self.matchesFailureKind = matchesFailureKind
        self.tool = tool
        self.argumentTemplate = argumentTemplate
        self.estimate = estimate
        self.risk = risk
        self.sortOrder = sortOrder
        self.notes = notes
    }

    /// The command as it will run, for showing in the row. The command
    /// is visible because "run a fix" with nothing to read is a thing
    /// people are right to refuse.
    public func command(input: String, output: String) -> String {
        ([tool] + resolvedArguments(input: input, output: output))
            .joined(separator: " ")
    }

    public func resolvedArguments(input: String, output: String) -> [String] {
        argumentTemplate.map {
            $0.replacingOccurrences(of: "{input}", with: input)
                .replacingOccurrences(of: "{output}", with: output)
        }
    }

    /// The four that ship. Deliberately few and deliberately ordinary:
    /// three stream copies and one re-encode, ordered cheapest first.
    public static var shipped: [RepairRecipe] {
        [
            RepairRecipe(
                name: "Rebuild the index (faststart remux)",
                matchesFailureKind: PlaybackFailureKind.missingIndex.rawValue,
                argumentTemplate: [
                    "-v", "error", "-i", "{input}", "-c", "copy",
                    "-movflags", "+faststart", "{output}",
                ],
                estimate: "seconds — copies streams, rewrites the index",
                risk: .lossless, sortOrder: 0,
                notes: "Moves the moov atom to the front. The bits are unchanged."),
            RepairRecipe(
                name: "Repair the container",
                matchesFailureKind: PlaybackFailureKind.truncated.rawValue,
                argumentTemplate: [
                    "-v", "error", "-err_detect", "ignore_err", "-i", "{input}",
                    "-c", "copy", "{output}",
                ],
                estimate: "seconds — copies what parses, drops what does not",
                risk: .lossless, sortOrder: 1,
                notes: "Keeps every frame that survives the damage."),
            RepairRecipe(
                name: "Drop the undecodable stream",
                matchesFailureKind: PlaybackFailureKind.badStream.rawValue,
                argumentTemplate: [
                    "-v", "error", "-i", "{input}", "-map", "0:v:0", "-map", "0:a?",
                    "-c", "copy", "{output}",
                ],
                estimate: "seconds — keeps the first video and any audio",
                risk: .lossless, sortOrder: 2,
                notes: "Useful when a second video stream is the broken one."),
            RepairRecipe(
                name: "Salvage by re-encoding",
                matchesFailureKind: nil,
                argumentTemplate: [
                    "-v", "error", "-err_detect", "ignore_err", "-i", "{input}",
                    "-c:v", "libx264", "-crf", "18", "-c:a", "aac", "{output}",
                ],
                estimate: "about a minute per GB",
                risk: .lossy, sortOrder: 9,
                notes: "Loses a generation and may lose material. Try the copies first."),
        ]
    }
}

extension AppDatabase {
    /// The recipes, cheapest first. Empty on a fresh install until
    /// `seedRepairRecipes` runs.
    public func repairRecipes() throws -> [RepairRecipe] {
        try writer.read { db in
            try RepairRecipe.order(sql: "sortOrder, name").fetchAll(db)
        }
    }

    /// Recipes that address this failure kind, plus the ones that match
    /// anything — cheapest first, so the row order is the advice.
    /// Disabled recipes are never offered: enabling one is the gesture
    /// that says it has been tested.
    public func repairRecipes(forFailureKind kind: String?, probeOutput: String? = nil) throws
        -> [RepairRecipe] {
        try repairRecipes().filter { recipe in
            guard recipe.enabled else { return false }
            if let pattern = recipe.matchPattern, !pattern.isEmpty {
                guard let probeOutput,
                      probeOutput.range(of: pattern, options: .caseInsensitive) != nil
                else { return false }
            }
            return recipe.matchesFailureKind == nil || recipe.matchesFailureKind == kind
        }
    }

    /// Write the shipped recipes once. They are editable data from then
    /// on, so this never overwrites an existing table.
    public func seedRepairRecipes() throws {
        try writer.write { db in
            guard try RepairRecipe.fetchCount(db) == 0 else { return }
            for recipe in RepairRecipe.shipped { try recipe.insert(db) }
        }
    }

    public func saveRepairRecipe(_ recipe: RepairRecipe) throws {
        try writer.write { try recipe.upsert($0) }
    }

    public func deleteRepairRecipe(_ id: UUID) throws {
        _ = try writer.write { try RepairRecipe.deleteOne($0, key: id) }
    }
}
