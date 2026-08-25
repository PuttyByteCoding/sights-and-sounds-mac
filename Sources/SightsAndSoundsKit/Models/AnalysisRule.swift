import Foundation
import GRDB

/// A persisted tag-analysis rule: match → ordered actions. Authored by the
/// user, never derived — which is why the migrator must carry these while
/// it skips everything recomputable.
///
/// Phase 2 lands the storage; the rule *engine* ports in Phase 4. Matcher
/// and actions are JSON documents with a `type` discriminator, the exact
/// wire vocabulary the old engine used — except `assignGroup`, which the
/// migrator translates to `assignCategory` on the way in:
///   matchers: keyEquals · valueStartsWith · numericRange · pathRootStartsWith
///   actions:  ignore · setKind · stripPrefix · onlyIfTrue · assignCategory · hidePrefix
/// Action order inside `actionsJSON` and `sortOrder` across rules are both
/// significant — the engine folds actions in list order.
public struct AnalysisRule: Codable, Equatable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "analysisRule"

    public var id: UUID
    public var sortOrder: Int
    /// One matcher object, e.g. `{"type":"keyEquals","key":"band"}`.
    public var matchJSON: String
    /// An ordered array of action objects.
    public var actionsJSON: String

    public init(id: UUID = UUID(), sortOrder: Int = 0, matchJSON: String, actionsJSON: String) {
        self.id = id
        self.sortOrder = sortOrder
        self.matchJSON = matchJSON
        self.actionsJSON = actionsJSON
    }
}
