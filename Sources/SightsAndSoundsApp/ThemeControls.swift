import SwiftUI

/// The controls the comps draw over and over: three button weights, a
/// badge, and a segmented control. They live here rather than in each
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

/// The 9px uppercase plate that sits beside a name — `OPEN`, an offline
/// count, a status word. Deliberately tiny and deliberately not grey: at
/// this size only a tinted plate reads.
struct ThemeBadge: View {
    let text: String
    var fill: Color = Theme.Status.goodBadgeFill
    var foreground: Color = Theme.Status.greenBright

    var body: some View {
        Text(text)
            .font(Theme.ui(9, .bold))
            .foregroundStyle(foreground)
            .padding(.vertical, 1.5)
            .padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.chip).fill(fill))
            .fixedSize()
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
