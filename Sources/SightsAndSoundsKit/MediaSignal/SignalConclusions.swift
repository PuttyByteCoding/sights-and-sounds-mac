import Foundation
import GRDB

/// A measurement read as a sign of something: "a 4:3 picture inside a
/// wider frame", "detail far below the encoded size".
///
/// Evidence is where thresholds live. It says what was seen and how
/// strongly, and what kind of thing it bears on, and stops there. One sign
/// rarely proves anything, which is why conclusions are a separate step
/// that has to cite the evidence it rests on.
public struct SignalEvidence: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "mediaSignalEvidence"

    public enum About: String, Codable, Sendable {
        /// The file as it stands: how this encode was made.
        case encode
        /// Where the picture or sound originally came from.
        case source
        /// Something done to it between the two.
        case processing
    }

    public var id: Int64?
    public var mediaItemID: UUID
    public var key: String
    public var about: About
    /// 0...1: how clearly the sign is there, not how much it proves.
    public var strength: Double
    /// The reading, in words, with its numbers.
    public var detail: String

    public init(mediaItemID: UUID = UUID(), key: String, about: About, strength: Double, detail: String) {
        self.mediaItemID = mediaItemID
        self.key = key
        self.about = about
        self.strength = min(max(strength, 0), 1)
        self.detail = detail
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// A conclusion, which is always an opinion: a category, how confident the
/// rules are in it, and the evidence that says so. Never shown as a fact,
/// and never stored without its evidence.
public struct SignalInference: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "mediaSignalInference"

    public enum Kind: String, Codable, Sendable {
        /// What the material originally was. Usually one; sometimes none.
        case sourceCharacter
        /// What has been done to it. Any number may hold at once.
        case history
    }

    public var id: Int64?
    public var mediaItemID: UUID
    public var kind: Kind
    public var category: String
    public var confidence: Double

    public init(mediaItemID: UUID = UUID(), kind: Kind, category: String, confidence: Double) {
        self.mediaItemID = mediaItemID
        self.kind = kind
        self.category = category
        self.confidence = min(max(confidence, 0), 1)
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// An inference together with the evidence behind it, as the rules produce
/// it and as a reader is given it.
public struct SignalConclusion: Equatable, Sendable {
    public var kind: SignalInference.Kind
    public var category: String
    public var confidence: Double
    /// Keys of the evidence that raised the confidence.
    public var supportedBy: [String]
    /// Keys of the evidence that lowered it.
    public var contradictedBy: [String]
}

/// Everything known about one item, as the rules read it.
public struct SignalFacts: Sendable {
    public var declared: [String: String]
    var measured: [String: Double]

    public init(declared: [String: String], measurements: [SignalMeasurement]) {
        self.declared = declared
        measured = [:]
        for row in measurements where row.scope != .frame && row.scope != .window {
            measured["\(row.key)|\(row.scope.rawValue)"] = row.value
        }
    }

    public init(declared: [String: String] = [:], findings: SignalFindings) {
        self.declared = declared.merging(findings.declared) { _, new in new }
        measured = [:]
        for row in findings.measured where row.scope != .frame && row.scope != .window {
            measured["\(row.key)|\(row.scope.rawValue)"] = row.value
        }
    }

    public func value(_ key: String, _ scope: SignalMeasurement.Scope = .file) -> Double? {
        measured["\(key)|\(scope.rawValue)"]
    }

    func number(_ key: String) -> Double? { declared[key].flatMap(Double.init) }
}

extension LibraryDatabase {
    /// The stage name the conclusions are marked under. Not a stage that
    /// reads files: it reads the other stages' rows.
    public static let conclusionsStage = "conclusions"

    public func signalFacts(itemID: UUID) throws -> SignalFacts {
        SignalFacts(
            declared: try signalDeclared(itemID: itemID),
            measurements: try signalMeasurements(itemID: itemID))
    }

    /// Replace an item's evidence and inferences, and the links between
    /// them, in one transaction.
    public func replaceSignalConclusions(
        itemID: UUID, evidence: [SignalEvidence], conclusions: [SignalConclusion], rulesVersion: Int
    ) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM mediaSignalInference WHERE mediaItemID = ?", arguments: [itemID])
            try db.execute(sql: "DELETE FROM mediaSignalEvidence WHERE mediaItemID = ?", arguments: [itemID])
            var evidenceIDs: [String: Int64] = [:]
            for var row in evidence {
                row.mediaItemID = itemID
                try row.insert(db)
                evidenceIDs[row.key] = row.id
            }
            for conclusion in conclusions {
                var row = SignalInference(
                    mediaItemID: itemID, kind: conclusion.kind, category: conclusion.category,
                    confidence: conclusion.confidence)
                try row.insert(db)
                for key in Set(conclusion.supportedBy + conclusion.contradictedBy) {
                    guard let evidenceID = evidenceIDs[key], let inferenceID = row.id else { continue }
                    try db.execute(
                        sql: "INSERT INTO mediaSignalInferenceEvidence (inferenceID, evidenceID) VALUES (?, ?)",
                        arguments: [inferenceID, evidenceID])
                }
            }
            try SignalStageState(mediaItemID: itemID, stage: Self.conclusionsStage, version: rulesVersion)
                .upsert(db)
        }
    }

    public func signalEvidence(itemID: UUID) throws -> [SignalEvidence] {
        try writer.read { db in
            try SignalEvidence.filter(sql: "mediaItemID = ?", arguments: [itemID])
                .order(sql: "strength DESC, key").fetchAll(db)
        }
    }

    /// An item's inferences, most confident first, each with the evidence
    /// linked to it.
    public func signalInferences(itemID: UUID) throws -> [(inference: SignalInference, evidence: [SignalEvidence])] {
        try writer.read { db in
            let inferences = try SignalInference.filter(sql: "mediaItemID = ?", arguments: [itemID])
                .order(sql: "confidence DESC, category").fetchAll(db)
            return try inferences.map { inference in
                let evidence = try SignalEvidence.fetchAll(
                    db,
                    sql: """
                    SELECT mediaSignalEvidence.* FROM mediaSignalEvidence \
                    JOIN mediaSignalInferenceEvidence ON evidenceID = mediaSignalEvidence.id \
                    WHERE inferenceID = ? ORDER BY strength DESC, key
                    """,
                    arguments: [inference.id])
                return (inference, evidence)
            }
        }
    }

    /// Items with findings whose conclusions are missing or were drawn by
    /// older rules. Re-drawing them reads rows, not files.
    public func itemsNeedingSignalConclusions(rulesVersion: Int) throws -> [UUID] {
        try writer.read { db in
            try UUID.fetchAll(
                db,
                sql: """
                SELECT DISTINCT mediaItemID FROM mediaSignalStage AS done \
                WHERE done.stage <> ? AND done.failureMessage IS NULL \
                AND NOT EXISTS (SELECT 1 FROM mediaSignalStage AS drawn \
                                WHERE drawn.mediaItemID = done.mediaItemID \
                                AND drawn.stage = ? AND drawn.version >= ? \
                                AND drawn.completedAt >= done.completedAt)
                """,
                arguments: [Self.conclusionsStage, Self.conclusionsStage, rulesVersion])
        }
    }
}
