import SwiftUI
import SightsAndSoundsKit

/// The vocabulary of the three-way filter.
///
/// `cycleTag` has existed since Phase 1; what it never had was a way to
/// *look* like anything. Three colours and three glyphs, defined once
/// here, so the sidebar row, the chip above the grid and the legend at
/// the foot of the sidebar cannot drift apart — and so a filter slot
/// means the same thing in every window that grows one.
extension MediaFilter.TagSlot {
    /// The glyph in the row's slot chip.
    var mark: String {
        switch self {
        case .required: "+"
        case .optional: "~"
        case .excluded: "−"
        }
    }

    var color: Color {
        switch self {
        case .required: Theme.Status.green
        case .optional: Theme.Status.blue
        case .excluded: Theme.Status.red
        }
    }

    /// The legend line — verbatim from the spec.
    var legend: String {
        switch self {
        case .required: "Required — item must carry it"
        case .optional: "Optional — any one of these"
        case .excluded: "Excluded — item must not carry it"
        }
    }

    /// The word alone, for a chip's tooltip.
    var name: String {
        switch self {
        case .required: "Required"
        case .optional: "Optional"
        case .excluded: "Excluded"
        }
    }
}

/// The small square at the head of a filter row: tinted and glyphed when
/// the row holds a slot, an empty outline when it does not. The outline
/// stays visible at rest because a row that only grows a control once you
/// have used it teaches nobody that the control is there.
struct FilterSlotChip: View {
    let slot: MediaFilter.TagSlot?
    var size: CGFloat = 14

    var body: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.chip)
            .fill(slot?.color.opacity(0.15) ?? .clear)
            .stroke(slot?.color ?? Theme.Border.subtleButton, lineWidth: 1)
            .frame(width: size, height: size)
            .overlay {
                if let slot {
                    Text(slot.mark)
                        .font(Theme.ui(10, .bold))
                        .foregroundStyle(slot.color)
                }
            }
    }
}

/// The four-way state picker on a filter summary row.
///
/// Both summaries — the block at the top of the sidebar and the chip bar
/// over the grid — could only ever *remove* a term. Moving one from
/// required to optional meant going back to its row in the category tree
/// and cycling it, which is a long way to walk to fix a mis-click.
///
/// A menu rather than another click-cycle: `MediaFilter.cycle` says a
/// four-state cycle you can only walk forwards is "a guessing game every
/// time you overshoot", and a summary row is exactly where you go to
/// correct an overshoot. Naming the states is the cure for that.
///
/// The label is the caller's, so the sidebar keeps its glyph and the chip
/// bar its dot; only the menu behind them is shared — the same reason the
/// colours and glyphs above live in one file.
struct SlotMenu<Label: View>: View {
    let slot: MediaFilter.TagSlot
    let set: (MediaFilter.TagSlot?) -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Menu {
            ForEach(MediaFilter.TagSlot.allCases, id: \.self) { option in
                Button {
                    set(option)
                } label: {
                    // The tick is the only thing naming the current state
                    // once the menu is covering the row's own glyph.
                    if option == slot {
                        SwiftUI.Label(option.name, systemImage: "checkmark")
                    } else {
                        Text(option.name)
                    }
                }
            }
            Divider()
            Button("Remove From Filter", role: .destructive) { set(nil) }
        } label: {
            label()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("\(slot.name) — \(slot.legend). Click to change.")
    }
}

extension StatusFlag {
    /// The one place a status flag is named — the sidebar row, the chip
    /// above the grid and any tooltip read the same string. Unchanged
    /// wording: these labels have been in the sidebar since Phase 1.
    var displayName: String {
        switch self {
        case .needsReview: "Needs Review"
        case .playbackIssue: "Playback Issue"
        case .markedForDeletion: "Marked for Deletion"
        case .favorite: "Favorite"
        case .clip: "Clip (any)"
        case .embedded: "Embedded Clip"
        case .exported: "Exported Clip"
        case .edited: "Edited"
        }
    }
}
