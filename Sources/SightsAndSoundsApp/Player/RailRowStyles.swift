import SwiftUI

/// The two selection treatments the player's rail uses, each in one
/// place (design review 2026-10-20, S6).
///
/// A **list row** — a segment, a history entry — that is selected takes
/// `Theme.Surface.selectedSegment`, square corners, and the 2pt amber
/// rule down its leading edge. A **suggestion** under a field — a
/// category's autocomplete, the Universal field, Tag Analysis Results —
/// that the arrows have landed on takes `Theme.Surface.selectedRow` on
/// the chip radius. Which rows are selectable is each list's business;
/// how a selected one reads is settled here.
extension View {
    func railRowSelection(_ selected: Bool) -> some View {
        modifier(RailRowSelection(selected: selected))
    }

    func highlightedSuggestion(_ active: Bool) -> some View {
        background(
            RoundedRectangle(cornerRadius: Theme.Radius.chip)
                .fill(active ? Theme.Surface.selectedRow : .clear))
    }
}

private struct RailRowSelection: ViewModifier {
    let selected: Bool

    func body(content: Content) -> some View {
        content
            .background(selected ? Theme.Surface.selectedSegment : .clear)
            .overlay(alignment: .leading) {
                if selected {
                    Rectangle()
                        .fill(Theme.Border.selectionInset)
                        .frame(width: Theme.Border.selectionInsetWidth)
                }
            }
    }
}
