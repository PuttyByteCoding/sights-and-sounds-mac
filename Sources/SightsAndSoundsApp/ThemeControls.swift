import SwiftUI

/// The controls the comps draw over and over: three button weights, a
/// badge, a segmented control, a path and a progress bar. They live here rather than in each
/// screen because "one name, one place" (layout rule 5) applies to a
/// shape as much as to a string — five views drawing their own amber
/// button is five places to change the radius.
///
/// macOS keeps its window chrome and its standard controls; these are for
/// the content area, where the app owns its appearance.

// MARK: - Buttons

/// The primary action — amber fill, dark text. One per surface.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.ui(Theme.TypeScale.body, .semibold))
            .foregroundStyle(isEnabled ? Theme.Text.onAmber : Theme.Text.disabled)
            .padding(.vertical, 7)
            .padding(.horizontal, 17)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.button)
                    .fill(isEnabled ? Theme.Accent.amber : Theme.Surface.buttonDisabled))
            .opacity(configuration.isPressed ? 0.82 : 1)
            .contentShape(Rectangle())
    }
}

/// An outlined button — cancel, and anything beside it.
struct SecondaryButtonStyle: ButtonStyle {
    /// The smaller weight used for the row of jump-offs along the bottom
    /// of a dialog, where three buttons share the space with a cancel and
    /// a primary.
    var compact = false

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.ui(compact ? Theme.TypeScale.secondary : Theme.TypeScale.body))
            .foregroundStyle(
                !isEnabled ? Theme.Text.disabled
                    : hovering ? Theme.Text.primary : Theme.Text.tertiary)
            .lineLimit(1)
            .padding(.vertical, compact ? 6 : 7)
            .padding(.horizontal, compact ? 11 : 15)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.button)
                    .stroke(
                        hovering && isEnabled
                            ? Theme.Border.subtleButtonHover
                            : (compact ? Theme.Border.subtleButton : Theme.Border.raised),
                        lineWidth: 1))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

// MARK: - Badge

/// The 10px uppercase plate that sits beside a name — `OPEN`, an offline
/// count, a status word. Deliberately tiny and deliberately not grey: at
/// this size only a tinted plate reads.
struct ThemeBadge: View {
    let text: String
    var fill: Color = Theme.Status.goodBadgeFill
    var foreground: Color = Theme.Status.greenBright

    var body: some View {
        Text(text)
            .font(Theme.ui(10, .bold))
            .foregroundStyle(foreground)
            .padding(.vertical, 1.5)
            .padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.chip).fill(fill))
            .fixedSize()
    }
}

// MARK: - Icon button

/// An icon-only button with a hit target and a name.
///
/// A bare glyph in a `.plain` button is exactly as big as its strokes —
/// an 8pt × is a 6pt target — and says nothing to VoiceOver. This gives
/// every such button the same 22pt minimum square, a rectangular content
/// shape so the whole square takes the click, and a required label that
/// doubles as the tooltip unless a longer `help` is given.
///
/// The symbol initialiser draws the glyph in `Theme.Text.meta`: a glyph
/// that does something is an action, not a disabled control, so it is
/// never drawn in `disabled`. The closure form takes any glyph — a
/// `Text("★")`, a symbol whose colour follows state.
struct IconButton<Glyph: View>: View {
    private let label: String
    private let help: String
    private let action: () -> Void
    private let glyph: Glyph

    /// Minimum side of the clickable square.
    static var minimumTarget: CGFloat { 22 }

    init(
        _ label: String, help: String? = nil,
        action: @escaping () -> Void, @ViewBuilder glyph: () -> Glyph
    ) {
        self.label = label
        self.help = help ?? label
        self.action = action
        self.glyph = glyph()
    }

    var body: some View {
        Button(action: action) {
            glyph
                .frame(minWidth: Self.minimumTarget, minHeight: Self.minimumTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(help)
    }
}

extension IconButton where Glyph == IconGlyph {
    /// An SF Symbol glyph. `size` is the symbol's point size, never below
    /// the type scale's 10 unless the caller has a reason (a pill's × sits
    /// beside 11pt text and is sized to it).
    init(
        _ label: String, systemImage: String,
        size: CGFloat = Theme.TypeScale.sectionLabel, weight: Font.Weight = .regular,
        color: Color = Theme.Text.meta, help: String? = nil,
        action: @escaping () -> Void
    ) {
        self.init(label, help: help, action: action) {
            IconGlyph(systemImage: systemImage, size: size, weight: weight, color: color)
        }
    }
}

/// The glyph `IconButton` draws for its symbol initialiser.
struct IconGlyph: View {
    let systemImage: String
    let size: CGFloat
    let weight: Font.Weight
    let color: Color

    var body: some View {
        Image(systemName: systemImage)
            .font(Theme.ui(size, weight))
            .foregroundStyle(color)
    }
}

// MARK: - Segmented control

/// A two-or-more-way choice rendered as the comps draw it: a bordered
/// track with the active option filled.
///
/// `emphasis` decides how the active option reads. `.accent` is amber and
/// is for a choice that changes what a button will do; `.neutral` is a
/// raised grey and is for a view switch, where amber would compete with
/// the real primary action on the same surface.
struct ThemeSegmentedControl<Value: Hashable>: View {
    enum Emphasis { case accent, neutral }

    @Binding var selection: Value
    let options: [(value: Value, label: String)]
    var emphasis: Emphasis = .accent

    var body: some View {
        HStack(spacing: Theme.Spacing.segmentPadding) {
            ForEach(options, id: \.value) { option in
                let active = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(option.label)
                        .font(Theme.ui(12, active ? .semibold : .regular))
                        .foregroundStyle(foreground(active: active))
                        .padding(.vertical, 6)
                        .padding(.horizontal, 16)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.control)
                                .fill(active ? activeFill : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Theme.Spacing.segmentPadding)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.Surface.segmentTrack)
                .stroke(Theme.Border.raised, lineWidth: 1))
    }

    private var activeFill: Color {
        switch emphasis {
        case .accent: Theme.Accent.amber
        case .neutral: Theme.Surface.segmentSelected
        }
    }

    private func foreground(active: Bool) -> Color {
        guard active else { return Theme.Text.tertiary }
        switch emphasis {
        case .accent: return Theme.Text.onAmber
        case .neutral: return Theme.Text.primary
        }
    }
}

// MARK: - Path text

/// A path, truncated in the middle.
///
/// Never `direction: rtl` and never a leading ellipsis produced by
/// reversing the string — the leading `/` is a bidi neutral and reorders
/// to the end, which is layout rule 3 and cost real time to diagnose.
/// `.truncationMode(.middle)` keeps the volume and the filename, which
/// are the two halves anyone actually reads.
struct PathText: View {
    let path: String
    var size: CGFloat = 10
    var color: Color = Theme.Text.quaternary

    var body: some View {
        Text(abbreviated)
            .font(Theme.mono(size))
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(path)
    }

    /// `~` for the home directory, matching how the comps and the Finder
    /// both write it. Only when home is a real prefix — a path merely
    /// starting with the same characters is not inside it.
    private var abbreviated: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}

// MARK: - Text field

/// The app's text field: plain, on the well surface, with the standard
/// stroke — the field every app dialog draws (New Library, Library
/// Properties). A system `.roundedBorder` field on a charcoal dialog is
/// the one control that reads as belonging to another window.
struct ThemeFieldStyle: ViewModifier {
    var font: Font = Theme.ui(Theme.TypeScale.row)

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(font)
            .padding(.vertical, 6)
            .padding(.horizontal, 9)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .fill(Theme.Surface.well)
                    .stroke(Theme.Border.standard, lineWidth: 1))
    }
}

extension View {
    /// See `ThemeFieldStyle`.
    func themeField(font: Font = Theme.ui(Theme.TypeScale.row)) -> some View {
        modifier(ThemeFieldStyle(font: font))
    }
}

// MARK: - Menu label

/// The label of a `Menu` drawn as the compact secondary button beside
/// it — Archivo, the subtle stroke, the same height — so a row of
/// buttons and menus reads as one row. Pair with `themedMenu()`, which
/// hides the system indicator this label replaces.
struct ThemeMenuLabel: View {
    let title: String
    @State private var hovering = false

    init(_ title: String) { self.title = title }

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
                .font(Theme.ui(Theme.TypeScale.secondary))
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(hovering ? Theme.Text.primary : Theme.Text.tertiary)
        .lineLimit(1)
        .padding(.vertical, 6)
        .padding(.horizontal, 11)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.button)
                .stroke(
                    hovering ? Theme.Border.subtleButtonHover : Theme.Border.subtleButton,
                    lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

extension Menu {
    /// A menu whose label is a `ThemeMenuLabel`: the system button chrome
    /// and indicator off, the label's own size kept.
    func themedMenu() -> some View {
        menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
    }
}

// MARK: - Progress bar

/// The 5pt bar the comps draw for anything with a fraction: a well
/// track, an amber fill, and diagonal stripes flowing along the fill
/// while the work is live.
///
/// Never the stock `ProgressView` for a bar. It paints the system accent
/// on charcoal and tracks the user's accent colour, so it was the one
/// control in the app that did not belong to it. The small circular
/// spinner is fine — it is a standard control, which macOS keeps.
struct ThemeProgressBar: View {
    enum Mode: Equatable {
        /// 0…1, clamped: a job past its estimate fills the track rather
        /// than overflowing it.
        case determinate(Double)
        /// Known to be working, with no total to count against. The
        /// whole track takes a dimmer fill so it reads as "busy", not
        /// "done".
        case indeterminate
    }

    let mode: Mode
    /// Whether the stripes move. On for work happening now; off for a
    /// bar that is paused or finished, where the fill stands still.
    var running = false

    static let height: CGFloat = 5

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func determinate(_ fraction: Double, running: Bool = false) -> ThemeProgressBar {
        ThemeProgressBar(mode: .determinate(fraction), running: running)
    }

    /// `current` of `total`, as the job rows count. A total of zero is
    /// indeterminate — there is nothing to be a fraction of.
    static func determinate(_ current: Int, of total: Int, running: Bool = false) -> ThemeProgressBar {
        guard total > 0 else { return .indeterminate(running: running) }
        return determinate(Double(current) / Double(total), running: running)
    }

    static func indeterminate(running: Bool = true) -> ThemeProgressBar {
        ThemeProgressBar(mode: .indeterminate, running: running)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: Theme.Radius.chip)
                    .fill(Theme.Surface.well)
                RoundedRectangle(cornerRadius: Theme.Radius.chip)
                    .fill(Theme.Accent.amber.opacity(fillOpacity))
                    .frame(width: fillWidth(in: geometry.size.width))
                    .overlay {
                        if running {
                            Stripes(moving: !reduceMotion)
                                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip))
                        }
                    }
            }
        }
        .frame(height: Self.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Progress")
        .accessibilityValue(accessibilityValue)
    }

    private var fraction: Double? {
        switch mode {
        case .determinate(let value): min(max(value, 0), 1)
        case .indeterminate: nil
        }
    }

    private var fillOpacity: Double { fraction == nil ? 0.45 : 1 }

    private func fillWidth(in width: CGFloat) -> CGFloat {
        guard let fraction else { return width }
        // A started job shows a sliver even at 0 of N, so "running" and
        // "empty track" never look the same.
        return max(width * fraction, fraction > 0 || running ? Self.height : 0)
    }

    private var accessibilityValue: String {
        guard let fraction else { return "working" }
        return "\(Int((fraction * 100).rounded())) percent"
    }

    /// Diagonal bands of the on-amber ink at low opacity, slid along
    /// the fill once a second or so. The comp animates its stripes;
    /// Reduce Motion keeps them but holds them still.
    private struct Stripes: View {
        let moving: Bool
        private let band: CGFloat = 4
        private let period: CGFloat = 9

        var body: some View {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !moving)) { context in
                let phase = moving
                    ? CGFloat(context.date.timeIntervalSinceReferenceDate * 18)
                        .truncatingRemainder(dividingBy: period)
                    : 0
                Canvas { graphics, size in
                    var path = Path()
                    var x = -size.height - period + phase
                    while x < size.width + size.height {
                        path.move(to: CGPoint(x: x, y: size.height))
                        path.addLine(to: CGPoint(x: x + size.height, y: 0))
                        path.addLine(to: CGPoint(x: x + size.height + band, y: 0))
                        path.addLine(to: CGPoint(x: x + band, y: size.height))
                        path.closeSubpath()
                        x += period
                    }
                    graphics.fill(path, with: .color(Theme.Text.onAmber.opacity(0.22)))
                }
            }
        }
    }
}
