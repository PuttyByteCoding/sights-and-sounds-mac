import SwiftUI

/// The text on a tag pill, wherever one is drawn — a tile, the strip
/// under the video, the tag panel, the bulk remover: the name, then how
/// many items wear the tag, dimmer so the name stays the thing you read.
/// One builder, so every pill says it the same way.
enum TagPillLabel {
    static func text(_ name: String, count: Int?, countColor: Color) -> Text {
        guard let count else { return Text(name) }
        return Text(name) + Text(" \(count)").foregroundStyle(countColor)
    }
}
