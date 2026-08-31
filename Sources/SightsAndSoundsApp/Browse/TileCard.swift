import SwiftUI
import SightsAndSoundsKit

/// A tag as a tile draws it. Batched with the listing (never a query per
/// cell) and carrying the category's stored hue, so a pill is the same
/// colour here, in the sidebar and in the player.
struct TagPill: Hashable, Sendable, Identifiable {
    var id: UUID
    var name: String
    var categoryID: UUID
    var categoryName: String
    var colorIndex: Int
}

/// Everything a tile needs that is not on the item row itself.
struct TileContext {
    var isOnline = true
    var sourceName: String?
    var tags: [TagPill] = []
    var missingCategories: [String] = []
    var isDuplicate = false
}

/// One value rendered: a short run of text, a glyph, or a pill.
private struct TileBadge: Hashable {
    var text: String
    var color: Color
    var isPill = false
    var isGlyph = false
    /// Set on tag pills only. A badge is otherwise just text, but a tag
    /// pill IS a tag, and right-clicking one has to know which.
    var tagID: UUID?
}

/// A tile, drawn from the active view.
///
/// Shared by the browse grid and the player's queue strip — the queue is
/// the same tile at a different size, and two implementations of "what a
/// tile says" is how they drift apart.
struct TileCard: View {
    let item: MediaItem
    let context: TileContext
    let view: TileView
    let grid: GridSettings
    var thumbnail: NSImage?
    var isSelected = false
    /// Right-clicking a tag pill asks the caller to edit that tag. The
    /// player's queue strip passes nothing and its pills stay inert —
    /// the tile does not know what an editor is.
    var onEditTag: ((UUID) -> Void)?
    /// The queue strip sizes its own thumbnail; the browse grid lets the
    /// column width decide.
    var thumbnailHeight: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            strip(.above)
            HStack(alignment: .top, spacing: 6) {
                strip(.leading)
                thumbnailFrame
                strip(.trailing)
            }
            strip(.below)
        }
    }

    // MARK: - The frame

    /// One uniform frame per kind so the grid keeps its rhythm at 10,000
    /// items; anything narrower pillarboxes inside it against near-black.
    /// A 9:16 tile at true aspect is over three times the height of a
    /// landscape one, and one column of them wrecks the rows.
    private var frameAspect: CGFloat {
        if grid.fitToAspect, let width = item.width, let height = item.height, height > 0 {
            return CGFloat(width) / CGFloat(height)
        }
        return item.kind == .audio ? 16.0 / 10.0 : 16.0 / 9.0
    }

    private var thumbnailFrame: some View {
        ZStack {
            Theme.Surface.page
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    // An offline source's thumbnail is real and current —
                    // desaturated, not hidden behind a blocking overlay.
                    .saturation(context.isOnline ? 1 : 0.35)
            } else {
                Image(systemName: item.kind == .audio ? "waveform" : "film")
                    .font(.largeTitle)
                    .foregroundStyle(Theme.Text.disabled)
            }
            overlaySlots
            if isSelected {
                RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .stroke(Theme.Accent.amber, lineWidth: 2)
                Image(systemName: "checkmark")
                    .font(Theme.ui(11, .bold))
                    .foregroundStyle(Theme.Text.onAmber)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Theme.Accent.amber))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(6)
            }
        }
        .modifier(FrameShape(aspect: frameAspect, height: thumbnailHeight))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
    }

    private struct FrameShape: ViewModifier {
        let aspect: CGFloat
        let height: CGFloat?

        func body(content: Content) -> some View {
            if let height {
                content.frame(width: height * aspect, height: height)
            } else {
                content.aspectRatio(aspect, contentMode: .fit)
            }
        }
    }

    private var overlaySlots: some View {
        ZStack {
            ForEach(TileSlot.allCases.filter(\.isOverlay), id: \.self) { slot in
                slotContent(slot)
                    .frame(
                        maxWidth: .infinity, maxHeight: .infinity,
                        alignment: overlayAlignment(slot))
                    .padding(6)
            }
        }
        .allowsHitTesting(false)
    }

    private func overlayAlignment(_ slot: TileSlot) -> Alignment {
        switch slot {
        case .topLeft: .topLeading
        case .topCenter: .top
        case .topRight: .topTrailing
        case .middleCenter: .center
        case .bottomLeft: .bottomLeading
        case .bottomCenter: .bottom
        case .bottomRight: .bottomTrailing
        default: .center
        }
    }

    // MARK: - Slots

    @ViewBuilder
    private func strip(_ slot: TileSlot) -> some View {
        if !view.entries(in: slot).isEmpty {
            slotContent(slot)
                .frame(
                    maxWidth: slot == .above || slot == .below ? .infinity : nil,
                    alignment: slot.defaultAlignment.frameAlignment)
        }
    }

    /// A slot lays its values out in a row, except the middle and the
    /// gutters, which stack — a left gutter is tall and narrow, and a row
    /// there would push the thumbnail off the tile.
    @ViewBuilder
    private func slotContent(_ slot: TileSlot) -> some View {
        let entries = view.entries(in: slot)
        if !entries.isEmpty {
            let wraps = entries.contains { $0.wraps(in: slot) }
            if slot == .middleCenter || slot == .leading || slot == .trailing {
                VStack(alignment: slot.defaultAlignment.stackAlignment, spacing: 3) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                        badges(for: entry, in: slot)
                    }
                }
            } else if wraps {
                FlowRow(spacing: 4) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                        badges(for: entry, in: slot)
                    }
                }
            } else {
                HStack(spacing: 4) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                        badges(for: entry, in: slot)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func badges(for entry: TileEntry, in slot: TileSlot) -> some View {
        ForEach(Self.badges(for: entry.value, item: item, context: context), id: \.self) { badge in
            badgeView(badge, entry: entry, slot: slot)
        }
    }

    @ViewBuilder
    private func badgeView(_ badge: TileBadge, entry: TileEntry, slot: TileSlot) -> some View {
        let outside = !slot.isOverlay
        let text = Text(badge.text)
            .font(badge.isGlyph
                ? Theme.ui(outside ? 12 : 13)
                : Theme.mono(outside ? 10 : 9.5, .semibold))
            .foregroundStyle(badge.color)
            .lineLimit(entry.wraps(in: slot) ? nil : 1)
            .truncationMode(.middle)
            .multilineTextAlignment(entry.alignment(in: slot).textAlignment)
        if badge.isGlyph {
            // A glyph needs no plate; over an image it takes a shadow
            // instead, which costs no space at all.
            text.shadow(color: .black.opacity(outside ? 0 : 0.8), radius: 2, y: 1)
        } else if badge.isPill {
            // Tags are pills wherever they appear. Over the image the hue
            // is layered on a scrim so it stays legible; outside, the
            // tint alone carries it.
            text
                .padding(.vertical, 2)
                .padding(.horizontal, 8)
                .background {
                    ZStack {
                        if !outside { Capsule().fill(Theme.Surface.page.opacity(0.82)) }
                        Capsule().fill(badge.color.opacity(outside ? 0.12 : 0.2))
                    }
                }
                .overlay {
                    Capsule().stroke(badge.color.opacity(outside ? 0.2 : 0.35), lineWidth: 1)
                }
                .modifier(WidthRule(width: entry.width(in: slot)))
                // The innermost context menu wins, so right-clicking the
                // pill edits the TAG while right-clicking the tile around
                // it still gets the item's own menu.
                .modifier(TagPillMenu(tagID: badge.tagID, onEdit: onEditTag))
        } else if outside {
            text.modifier(WidthRule(width: entry.width(in: slot)))
        } else {
            text
                .padding(.vertical, 2)
                .padding(.horizontal, 6)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.chip)
                        .fill(Theme.Surface.page.opacity(0.78)))
                .modifier(WidthRule(width: entry.width(in: slot)))
        }
    }

    private struct WidthRule: ViewModifier {
        let width: TileWidth

        func body(content: Content) -> some View {
            switch width {
            case .auto: content
            case .fill: content.frame(maxWidth: .infinity)
            case .fixed(let points): content.frame(width: points)
            }
        }
    }

    // MARK: - The value registry

    /// What each value renders, and nothing at all when it does not
    /// apply — so a favourite star and an offline badge cost no space on
    /// an item that is neither.
    private static func badges(
        for value: TileValue, item: MediaItem, context: TileContext
    ) -> [TileBadge] {
        switch value {
        case .duration:
            guard let duration = item.durationSeconds else { return [] }
            return [TileBadge(text: format(duration: duration), color: Theme.Text.secondary)]
        case .format:
            guard let text = formatSummary(item) else { return [] }
            return [TileBadge(text: text, color: Theme.Text.secondary)]
        case .fileSize:
            return [TileBadge(text: format(bytes: item.fileSize), color: Theme.Text.tertiary)]
        case .fileName:
            return [TileBadge(text: item.fileName, color: Theme.Text.secondary)]
        case .path:
            return [TileBadge(text: item.relativePath, color: Theme.Text.tertiary)]
        case .source:
            guard let name = context.sourceName else { return [] }
            return [TileBadge(text: name, color: Theme.Text.tertiary)]
        case .mediaType:
            return [TileBadge(text: item.kind.displayName.lowercased(), color: Theme.Text.tertiary)]
        case .aspect:
            guard let label = aspectLabel(item) else { return [] }
            return [TileBadge(text: label, color: Theme.Status.blueBright)]
        case .importDate:
            return [TileBadge(
                text: item.ingestDate.formatted(date: .abbreviated, time: .omitted),
                color: Theme.Text.tertiary)]
        case .viewCount:
            guard item.watchCount > 0 else { return [] }
            return [TileBadge(text: "▶ \(item.watchCount)", color: Theme.Text.tertiary)]
        case .favorite:
            guard item.isFavorite else { return [] }
            return [TileBadge(text: "★", color: Theme.Accent.amber, isGlyph: true)]
        case .offline:
            guard !context.isOnline else { return [] }
            return [TileBadge(text: "◍ offline", color: Theme.Status.orange)]
        case .needsReview:
            guard item.needsReview else { return [] }
            return [TileBadge(text: "⟳ review", color: Theme.Status.blue)]
        case .playbackIssue:
            guard item.playbackIssue else { return [] }
            return [TileBadge(text: "⚠ issue", color: Theme.Status.red)]
        case .markedForDeletion:
            guard item.markedForDeletion else { return [] }
            return [TileBadge(text: "⌫ delete", color: Theme.Status.red)]
        case .clip:
            guard item.isClip || item.parentMediaItemID != nil else { return [] }
            return [TileBadge(
                text: item.isExportedClip ? "✂ exported" : "✂ clip", color: Theme.Text.tertiary)]
        case .duplicate:
            guard context.isDuplicate else { return [] }
            return [TileBadge(text: "⧉ duplicate", color: Theme.Status.mauve)]
        case .missingTags:
            guard !context.missingCategories.isEmpty else { return [] }
            return [TileBadge(
                text: "Missing: " + context.missingCategories.joined(separator: ", "),
                color: Theme.Status.orange)]
        case .tags:
            return context.tags.map {
                TileBadge(
                    text: $0.name, color: Theme.categoryHue($0.colorIndex),
                    isPill: true, tagID: $0.id)
            }
        case .tagsIn(let categoryID):
            return context.tags.filter { $0.categoryID == categoryID }.map {
                TileBadge(
                    text: $0.name, color: Theme.categoryHue($0.colorIndex),
                    isPill: true, tagID: $0.id)
            }
        }
    }

    /// Resolution for video; sample rate and channels for audio, because
    /// "1920×1080" on a FLAC says nothing and its sample rate says
    /// everything.
    static func formatSummary(_ item: MediaItem) -> String? {
        if item.kind == .audio {
            var parts: [String] = []
            if let rate = item.sampleRate { parts.append("\(rate / 1000)kHz") }
            if let channels = item.audioChannels {
                parts.append(channels == 1 ? "mono" : channels == 2 ? "stereo" : "\(channels)ch")
            }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
        guard let width = item.width, let height = item.height else { return nil }
        if width >= 3840 { return "4K" }
        if width >= 1920 { return "1080p" }
        if width >= 1280 { return "720p" }
        return "\(width)×\(height)"
    }

    /// Only when the media is not landscape — the badge exists to explain
    /// the pillarboxing beside it, and there is nothing to explain on a
    /// 16:9 frame.
    static func aspectLabel(_ item: MediaItem) -> String? {
        guard let width = item.width, let height = item.height, width > 0, height > 0,
              CGFloat(width) / CGFloat(height) < 1.2
        else { return nil }
        let divisor = greatestCommonDivisor(width, height)
        return "⇕ \(width / divisor):\(height / divisor)"
    }

    private static func greatestCommonDivisor(_ a: Int, _ b: Int) -> Int {
        var a = abs(a), b = abs(b)
        while b != 0 { (a, b) = (b, a % b) }
        return max(a, 1)
    }

    static func format(duration: Double) -> String {
        let total = Int(duration.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func format(bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

extension TileAlignment {
    var frameAlignment: Alignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    var stackAlignment: HorizontalAlignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    var textAlignment: TextAlignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}


/// The context menu on a tag pill. Applied only where a pill actually
/// carries a tag and the caller wants the gesture — everywhere else the
/// badge stays a plain piece of text and the tile's own menu is what a
/// right-click finds.
private struct TagPillMenu: ViewModifier {
    let tagID: UUID?
    let onEdit: ((UUID) -> Void)?

    func body(content: Content) -> some View {
        if let tagID, let onEdit {
            content.contextMenu {
                Button("Edit Tag…") { onEdit(tagID) }
            }
        } else {
            content
        }
    }
}
