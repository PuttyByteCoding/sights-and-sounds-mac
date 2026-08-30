import SwiftUI
import SightsAndSoundsKit

/// One entry in the value registry: what it is called, what it looks
/// like, and whether it has anything to configure.
struct TileValueOption: Identifiable {
    var value: TileValue
    var label: String
    var hint: String
    /// A glyph has no overflow, no alignment and no width worth setting —
    /// so `★` has no caret.
    var configurable = true

    var id: String { value.rawValue }
}

extension TileValue {
    /// Everything a tile can show, in the order the panel lists it. The
    /// per-category tag entries come from the library's vocabulary, so a
    /// view can show just Band, or Band + Year.
    static func registry(categories: [TagCategory]) -> [TileValueOption] {
        var options: [TileValueOption] = [
            .init(value: .duration, label: "Duration", hint: "0:48:12"),
            .init(value: .format, label: "Resolution / sample rate", hint: "4K · 96kHz"),
            .init(value: .fileSize, label: "File size", hint: "4.2 GB"),
            .init(value: .fileName, label: "File name", hint: "…_4k.mp4"),
            .init(value: .path, label: "Path", hint: "shows/1995"),
            .init(value: .source, label: "Source", hint: "Concerts SSD"),
            .init(value: .mediaType, label: "Media type", hint: "video"),
            .init(value: .aspect, label: "Aspect — only when not landscape", hint: "⇕ 9:16"),
            .init(value: .importDate, label: "Import date", hint: "12 Mar 2026"),
            .init(value: .viewCount, label: "View count", hint: "▶ 3"),
            .init(value: .favorite, label: "Favourite", hint: "★", configurable: false),
            .init(value: .offline, label: "Offline source", hint: "◍"),
            .init(value: .needsReview, label: "Needs review", hint: "⟳"),
            .init(value: .playbackIssue, label: "Playback issue", hint: "⚠"),
            .init(value: .markedForDeletion, label: "Marked for deletion", hint: "⌫"),
            .init(value: .clip, label: "Clip", hint: "✂"),
            .init(value: .duplicate, label: "Pending duplicate", hint: "⧉"),
            .init(value: .missingTags, label: "Missing category tags", hint: "Missing: Venue"),
            .init(value: .tags, label: "Tags — all categories", hint: "every tag"),
        ]
        options += categories.map { category in
            .init(
                value: .tagsIn(category.id), label: "Tags — \(category.name)",
                hint: category.name.lowercased())
        }
        return options
    }
}

/// The toolbar popover: saved views, the eleven slots, and the values in
/// whichever slot is open.
///
/// Deliberately **not** a basic/advanced split. Splitting by presumed
/// expertise hides things people need; scoping the settings to what you
/// have already ticked does not, and nothing here is labelled "advanced".
struct GridViewOptions: View {
    /// Fired only for tags / missing-categories / duplicate changes —
    /// the values whose data comes from batch queries.
    let onJoinFieldsChange: () -> Void
    @Environment(BrowseModel.self) private var model

    @State private var activeSlot: TileSlot = .below
    @State private var expanded: TileValue?

    private var display: GridDisplaySettings { GridDisplaySettings.shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                savedViews
                Text("Overlay layout")
                    .modifier(Theme.sectionLabel())
                    .padding(.bottom, 7)
                layoutGrid
                Text("The outer ring sits beside the thumbnail; the inner seven overlay it.")
                    .font(Theme.ui(11))
                    .foregroundStyle(Theme.Text.disabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 9)
                valueList
                sizeControls
            }
            .padding(14)
        }
        .frame(width: 372, height: 620)
        .background(Theme.Surface.dialog)
    }

    // MARK: - Saved views

    private var savedViews: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Saved views").modifier(Theme.sectionLabel())
                Spacer()
                Text("press V to cycle")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.Text.disabled)
            }
            FlowRow(spacing: 5) {
                ForEach(display.grid.views) { view in
                    let active = view.id == display.grid.activeView.id
                    Button {
                        display.grid.activeViewID = view.id
                        persist()
                    } label: {
                        Text(view.name)
                            .font(Theme.ui(11.5, active ? .semibold : .regular))
                            .foregroundStyle(active ? Theme.Text.onAmber : Theme.Text.tertiary)
                            .padding(.vertical, 4)
                            .padding(.horizontal, 10)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.Radius.control)
                                    .fill(active ? Theme.Accent.amber : Color.clear)
                                    .stroke(
                                        active ? Theme.Accent.amber : Theme.Border.subtleButton,
                                        lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 6) {
                TextField("View name", text: viewName)
                    .textFieldStyle(.plain)
                    .font(Theme.ui(12))
                    .padding(.vertical, 6)
                    .padding(.horizontal, 9)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.control)
                            .fill(Theme.Surface.well)
                            .stroke(Theme.Border.subtleButton, lineWidth: 1))
                Button("Duplicate") {
                    let copy = display.grid.activeView
                        .duplicated(named: display.grid.activeView.name + " copy")
                    display.grid.views.append(copy)
                    display.grid.activeViewID = copy.id
                    persist()
                }
                .buttonStyle(SecondaryButtonStyle(compact: true))
                Button("Delete") {
                    let id = display.grid.activeView.id
                    display.grid.views.removeAll { $0.id == id }
                    display.grid.activeViewID = display.grid.views.first?.id
                    persist()
                }
                .buttonStyle(SecondaryButtonStyle(compact: true))
                // The last view cannot go: a grid with no view has
                // nothing to draw.
                .disabled(display.grid.views.count < 2)
            }
        }
        .padding(.bottom, 14)
    }

    private var viewName: Binding<String> {
        Binding(
            get: { display.grid.activeView.name },
            set: { name in
                guard let index = display.grid.views.firstIndex(
                    where: { $0.id == display.grid.activeView.id }) else { return }
                display.grid.views[index].name = name
                persist()
            })
    }

    // MARK: - The eleven slots

    private var layoutGrid: some View {
        VStack(spacing: 3) {
            HStack(spacing: 3) {
                Color.clear.frame(width: 38, height: 26)
                slotCell(.above, "↑ above", height: 26)
                Color.clear.frame(width: 38, height: 26)
            }
            HStack(spacing: 3) {
                slotCell(.leading, "←", width: 38, height: 120)
                VStack(spacing: 3) {
                    HStack(spacing: 3) {
                        slotCell(.topLeft, "↖")
                        slotCell(.topCenter, "↑")
                        slotCell(.topRight, "↗")
                    }
                    HStack(spacing: 3) {
                        Color.clear.frame(maxWidth: .infinity)
                        slotCell(.middleCenter, "●")
                        Color.clear.frame(maxWidth: .infinity)
                    }
                    HStack(spacing: 3) {
                        slotCell(.bottomLeft, "↙")
                        slotCell(.bottomCenter, "↓")
                        slotCell(.bottomRight, "↘")
                    }
                }
                slotCell(.trailing, "→", width: 38, height: 120)
            }
            HStack(spacing: 3) {
                Color.clear.frame(width: 38, height: 26)
                slotCell(.below, "↓ below", height: 26)
                Color.clear.frame(width: 38, height: 26)
            }
        }
        .padding(5)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.button)
                .fill(Theme.Surface.well)
                .stroke(Theme.Border.standard, lineWidth: 1))
    }

    private func slotCell(
        _ slot: TileSlot, _ label: String, width: CGFloat? = nil, height: CGFloat = 38
    ) -> some View {
        let entries = display.grid.activeView.entries(in: slot)
        let active = activeSlot == slot
        return Button {
            activeSlot = slot
            expanded = nil
        } label: {
            VStack(spacing: 1) {
                Text(label)
                    .font(Theme.ui(slot.isOverlay ? 12 : 9.5))
                    .foregroundStyle(
                        active ? Theme.Accent.amber
                            : entries.isEmpty ? Theme.Border.subtleButtonHover
                            : Theme.Text.secondary)
                if !entries.isEmpty {
                    Text(summary(entries))
                        .font(Theme.mono(9))
                        .foregroundStyle(Theme.Accent.amber)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 3)
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(cellFill(active: active, filled: !entries.isEmpty, slot: slot))
                    .stroke(
                        active ? Theme.Accent.amber
                            : entries.isEmpty ? Theme.Border.standard : Theme.Border.subtleButtonHover,
                        style: StrokeStyle(
                            lineWidth: 1, dash: slot.isOverlay ? [] : [3, 2])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(slot.displayName)
    }

    private func cellFill(active: Bool, filled: Bool, slot: TileSlot) -> Color {
        if active { return Theme.Surface.iconTileSelected }
        if filled { return Theme.Surface.iconTile }
        return slot.isOverlay ? Theme.Surface.raised : .clear
    }

    private func summary(_ entries: [TileEntry]) -> String {
        guard entries.count == 1 else { return "\(entries.count) values" }
        let categories = model.vocabulary.map(\.category)
        return TileValue.registry(categories: categories)
            .first { $0.value == entries[0].value }?.hint ?? "1 value"
    }

    // MARK: - Values in the open slot

    private var valueList: some View {
        VStack(alignment: .leading, spacing: 7) {
            (Text("Showing in ")
                .foregroundStyle(Theme.Text.quaternary)
             + Text(activeSlot.displayName.lowercased())
                .foregroundStyle(Theme.Accent.amber)
             + Text(" — pick any number of values.")
                .foregroundStyle(Theme.Text.quaternary))
                .font(Theme.ui(11.5))
            VStack(spacing: 1) {
                ForEach(TileValue.registry(categories: model.vocabulary.map(\.category))) { option in
                    valueRow(option)
                }
            }
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.button)
                    .stroke(Theme.Border.standard, lineWidth: 1))
        }
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private func valueRow(_ option: TileValueOption) -> some View {
        let view = display.grid.activeView
        let on = view.entries(in: activeSlot).contains { $0.value == option.value }
        let elsewhere = !on ? view.slot(of: option.value) : nil
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    toggle(option.value)
                } label: {
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: Theme.Radius.chip)
                            .fill(on ? Theme.Accent.amber : .clear)
                            .stroke(
                                on ? Theme.Accent.amber : Theme.Border.subtleButtonHover,
                                lineWidth: 1)
                            .frame(width: 14, height: 14)
                            .overlay {
                                if on {
                                    Image(systemName: "checkmark")
                                        .font(Theme.ui(9, .bold))
                                        .foregroundStyle(Theme.Text.onAmber)
                                }
                            }
                        Text(option.label)
                            .font(Theme.ui(12))
                            .foregroundStyle(on ? Theme.Text.primary : Theme.Text.tertiary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // A value lives in one slot; saying where saves a hunt
                // through eleven of them.
                if let elsewhere {
                    Text(elsewhere.displayName.lowercased())
                        .font(Theme.mono(9))
                        .foregroundStyle(Theme.Text.disabled)
                } else {
                    Text(option.hint)
                        .font(Theme.mono(9.5))
                        .foregroundStyle(Theme.Text.disabled)
                }
                // The settings appear only on a value you have already
                // ticked, and only where they apply.
                if on, option.configurable {
                    Button {
                        expanded = expanded == option.value ? nil : option.value
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(Theme.ui(9))
                            .foregroundStyle(
                                expanded == option.value
                                    ? Theme.Accent.amber : Theme.Text.disabled)
                            .rotationEffect(.degrees(expanded == option.value ? 90 : 0))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            if on, option.configurable, expanded == option.value {
                entryControls(option.value)
                    .padding(.leading, 30)
                    .padding(.bottom, 8)
            }
        }
    }

    @ViewBuilder
    private func entryControls(_ value: TileValue) -> some View {
        let entry = display.grid.activeView.entries(in: activeSlot)
            .first { $0.value == value } ?? TileEntry(value)
        VStack(alignment: .leading, spacing: 6) {
            control("Overflow") {
                miniSegment(
                    options: [("Truncate", false), ("Wrap", true)],
                    selected: entry.wraps(in: activeSlot),
                    pick: { wraps in update(value) { $0.wraps = wraps } })
            }
            control("Align") {
                miniSegment(
                    options: TileAlignment.allCases.map { ($0.displayName, $0) },
                    selected: entry.alignment(in: activeSlot),
                    pick: { alignment in update(value) { $0.alignment = alignment } })
            }
            control("Width") {
                HStack(spacing: 7) {
                    miniSegment(
                        options: [("Auto", 0), ("Fill", 1), ("Fixed", 2)],
                        selected: widthKind(entry.width(in: activeSlot)),
                        pick: { kind in
                            update(value) {
                                $0.width = kind == 0 ? .auto : kind == 1 ? .fill : .fixed(96)
                            }
                        })
                    if case .fixed(let points) = entry.width(in: activeSlot) {
                        TextField(
                            "px",
                            value: Binding(
                                get: { points },
                                set: { points in
                                    update(value) { $0.width = .fixed(max(24, points)) }
                                }),
                            format: .number)
                            .textFieldStyle(.plain)
                            .font(Theme.mono(11))
                            .frame(width: 52)
                    }
                }
            }
        }
    }

    private func widthKind(_ width: TileWidth) -> Int {
        switch width {
        case .auto: 0
        case .fill: 1
        case .fixed: 2
        }
    }

    private func control<Content: View>(
        _ label: String, @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 7) {
            Text(label)
                .font(Theme.ui(10.5))
                .foregroundStyle(Theme.Text.disabled)
                .frame(width: 50, alignment: .leading)
            content()
        }
    }

    private func miniSegment<Value: Equatable>(
        options: [(String, Value)], selected: Value, pick: @escaping (Value) -> Void
    ) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let active = option.1 == selected
                Button {
                    pick(option.1)
                } label: {
                    Text(option.0)
                        .font(Theme.ui(10.5, active ? .semibold : .regular))
                        .foregroundStyle(active ? Theme.Text.primary : Theme.Text.tertiary)
                        .padding(.vertical, 3)
                        .padding(.horizontal, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(active ? Theme.Surface.segmentSelected : .clear))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control)
                .fill(Theme.Surface.well)
                .stroke(Theme.Border.standard, lineWidth: 1))
    }

    // MARK: - Size

    private var sizeControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tiles").modifier(Theme.sectionLabel())
            Slider(value: Binding(
                get: { display.grid.thumbnailSize },
                set: { display.grid.thumbnailSize = $0 }), in: 120...400
            ) {
                Text("Size")
            } minimumValueLabel: {
                Image(systemName: "square.grid.3x3")
            } maximumValueLabel: {
                Image(systemName: "square")
            } onEditingChanged: { editing in
                // Live while dragging; settings.json only on settle.
                if !editing { display.persist() }
            }
            Toggle(isOn: Binding(
                get: { display.grid.fitToAspect },
                set: { display.grid.fitToAspect = $0; display.persist() })
            ) {
                Text("Fit tiles to media aspect")
                    .font(Theme.ui(12))
                    .foregroundStyle(Theme.Text.secondary)
            }
            .toggleStyle(.checkbox)
            Text("Off, every kind keeps one frame and anything narrower pillarboxes inside it — which is what keeps the grid readable at ten thousand items.")
                .font(Theme.ui(10.5))
                .foregroundStyle(Theme.Text.disabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Edits

    private func toggle(_ value: TileValue) {
        let before = display.grid.needsTagData || display.grid.needsDuplicateData
        mutateActiveView { $0.toggle(value, in: activeSlot) }
        if before != (display.grid.needsTagData || display.grid.needsDuplicateData) {
            onJoinFieldsChange()
        }
    }

    private func update(_ value: TileValue, _ mutate: @escaping (inout TileEntry) -> Void) {
        mutateActiveView { $0.update(value, mutate) }
    }

    private func mutateActiveView(_ mutate: (inout TileView) -> Void) {
        guard let index = display.grid.views.firstIndex(
            where: { $0.id == display.grid.activeView.id }) else { return }
        mutate(&display.grid.views[index])
        persist()
    }

    private func persist() {
        display.persist()
    }
}
