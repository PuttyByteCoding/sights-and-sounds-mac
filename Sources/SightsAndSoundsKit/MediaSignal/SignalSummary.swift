import Foundation

/// An item's conclusions, ready to show: what it probably was, what has
/// been done to it, and for each the readings that say so.
///
/// The wording is the point. An origin is "probably" or "possibly", with
/// its confidence beside it, because it is an opinion; only a line marked
/// `isFact` may be stated flatly.
public struct SignalSummary: Equatable, Sendable {
    public struct Line: Equatable, Sendable, Identifiable {
        public var category: String
        public var confidence: Double
        /// True for the one conclusion read from the file's own metadata.
        public var isFact: Bool
        /// One sentence per piece of evidence, strongest first.
        public var evidence: [String]

        public var id: String { category }

        /// "Probably VHS-like", "Possibly film", or the bare category for
        /// a fact.
        public var phrase: String {
            if isFact { return category }
            if category == "Unknown" { return "Origin unknown" }
            return (confidence >= 0.7 ? "Probably " : "Possibly ") + category
        }
    }

    public var origins: [Line]
    public var history: [Line]

    public var isEmpty: Bool { origins.isEmpty && history.isEmpty }
}

extension LibraryDatabase {
    /// Nil when the item has not been through the sweep. A segment is a
    /// range of its parent's file, so it is given its parent's summary.
    public func signalSummary(for item: MediaItem) throws -> SignalSummary? {
        let itemID = item.parentMediaItemID ?? item.id
        let drawn = try signalStageStates(itemID: itemID).contains { $0.stage == Self.conclusionsStage }
        guard drawn else { return nil }
        let lines = try signalInferences(itemID: itemID).map { entry in
            (entry.inference.kind, SignalSummary.Line(
                category: entry.inference.category, confidence: entry.inference.confidence,
                isFact: entry.inference.category == "Re-encoded by a transcoder",
                evidence: entry.evidence.map(\.detail)))
        }
        return SignalSummary(
            origins: lines.filter { $0.0 == .sourceCharacter }.map(\.1),
            history: lines.filter { $0.0 == .history }.map(\.1))
    }
}
