import Foundation
import GRDB

/// A user-defined key → tag binding: pressing the key in the player toggles
/// the tag on the current item. Library-owned (bindings name tags), stored
/// in the library file — the old app kept these in browser localStorage,
/// which is exactly what the brief's "library owns its key bindings" fixes.
public struct TagKeyBinding: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "tagKeyBinding"

    /// Canonical key: "F1"…"F9" verbatim, letters lowercase.
    public var key: String
    public var tagID: UUID
    /// When true, APPLYING the tag via its key also advances to the next
    /// item (removing never advances) — "stamp + move on" triage.
    public var advance: Bool

    public init(key: String, tagID: UUID, advance: Bool = false) {
        self.key = key
        self.tagID = tagID
        self.advance = advance
    }

    /// Keys offered for binding — everything the player's fixed map leaves
    /// free. Same set the old app offered: F-keys minus reserved ones, and
    /// letters the player doesn't claim now or in the phases ahead
    /// (f/r/d/w today; t/i/u/k/g are spoken for by later features).
    public static let bindableKeys: [String] = [
        "F1", "F2", "F3", "F4", "F6", "F7", "F8", "F9",
        "a", "b", "c", "e", "h", "j", "l", "m",
        "n", "o", "p", "q", "s", "v", "x", "y", "z",
    ]
}
