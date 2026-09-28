import SightsAndSoundsKit

/// What a tile's drawn states say to VoiceOver. The tile shows them in
/// colour and glyphs only — dimmed when offline, the deletion mark, the
/// won't-play badge, the star, the duplicate flag — and VoiceOver heard
/// just the file name.
enum TileAccessibility {
    /// The tile's states, most consequential first; empty when it has
    /// none to tell.
    static func value(for item: MediaItem, online: Bool, duplicate: Bool) -> String {
        var states: [String] = []
        if !online { states.append("offline") }
        if item.markedForDeletion { states.append("marked for deletion") }
        if item.playbackIssue { states.append("won't play") }
        if item.isFavorite { states.append("favourite") }
        if item.needsReview { states.append("needs review") }
        if duplicate { states.append("possible duplicate") }
        return states.joined(separator: ", ")
    }
}
