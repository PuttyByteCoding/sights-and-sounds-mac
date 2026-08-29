import SwiftUI
import AppKit
import SightsAndSoundsKit

/// The app's own appearance — warm charcoal surfaces with an amber accent,
/// not system materials. macOS keeps its window chrome and its standard
/// controls; everything inside the content area is painted from here.
///
/// Every value is `docs/design/design-tokens.md`, verbatim. Do not
/// substitute `.background` / `.secondary` semantic colours for these:
/// the decision (Aug 2026) was that the app owns its appearance, and a
/// semantic colour would track the system theme instead.
///
/// One name, one place — layout rule 5. A hex that appears in two views
/// belongs here, not in both.
enum Theme {

    // MARK: - Surfaces

    enum Surface {
        /// Behind everything.
        static let page = Color(hex: 0x0B0A08)
        /// Main content area.
        static let content = Color(hex: 0x131009)
        /// Left rails. Differs from content so the split needs no rule.
        static let sidebar = Color(hex: 0x17130E)
        /// Cards, list rows, panels.
        static let raised = Color(hex: 0x151209)
        /// A selected row. Pair with `Theme.Border.selectionInset`.
        static let selectedRow = Color(hex: 0x2A2118)
        /// Toolbars and footers.
        static let toolbar = Color(hex: 0x1A1610)
        /// Window title bar.
        static let titleBar = Color(hex: 0x1C1814)
        /// Text fields and progress tracks.
        static let well = Color(hex: 0x0F0C07)

        /// A modal panel floating over its context — lighter than
        /// `content` so it reads as being in front of it.
        static let dialog = Color(hex: 0x1B1712)
        /// A band inside a dialog that must not read as a divider row.
        static let band = Color(hex: 0x231E17)
        /// The unselected half of a segmented control.
        static let segmentTrack = Color(hex: 0x100D08)
        /// A selected segment that is not the primary action.
        static let segmentSelected = Color(hex: 0x2E2820)
        /// A square icon tile, unselected / selected.
        static let iconTile = Color(hex: 0x221D16)
        static let iconTileSelected = Color(hex: 0x3A2E16)
        /// A disabled primary button.
        static let buttonDisabled = Color(hex: 0x2A241C)
        /// Neutral-but-irreversible confirm — removing a library from the
        /// registry. Deliberately NOT red: nothing is destroyed.
        static let neutralDestructive = Color(hex: 0x2A241C)
    }

    // MARK: - Borders

    enum Border {
        /// Standard.
        static let standard = Color(hex: 0x2A251E)
        /// Dialogs and popovers.
        static let raised = Color(hex: 0x3A3328)
        /// A selected card.
        static let activeCard = Color(hex: 0x4A3C24)
        /// A focused control.
        static let activeControl = Color(hex: 0x7A6428)
        /// A secondary (outline) button, at rest and hovered.
        static let subtleButton = Color(hex: 0x332D24)
        static let subtleButtonHover = Color(hex: 0x5A5142)

        /// The 2pt amber rule down the leading edge of a selected row.
        static let selectionInset = Accent.amber
        static let selectionInsetWidth: CGFloat = 2
    }

    // MARK: - Text

    /// Contrast ratios are measured on `Surface.content` (`#131009`).
    ///
    /// The rule learned the hard way: `#7C7466` and `#5E5749` fail AA
    /// below 12px, and shipped on load-bearing data three separate times
    /// — a file path, a predicted encode size, and the prior embedded
    /// value a write-back was about to overwrite. **Anything a decision
    /// depends on is `quaternary` or lighter.**
    enum Text {
        /// 15.2:1 — body, values.
        static let primary = Color(hex: 0xF2EDE4)
        /// 10.4:1 — row text.
        static let secondary = Color(hex: 0xCFC6B8)
        /// 6.9:1 — descriptions.
        static let tertiary = Color(hex: 0xA79E90)
        /// 5.0:1 — the floor for text at 10–12px.
        static let quaternary = Color(hex: 0x8C8478)
        /// 3.4:1 — non-informational only. Never a value someone reads.
        static let disabled = Color(hex: 0x6E6659)
        /// Text on an amber fill.
        static let onAmber = Color(hex: 0x1A1409)
    }

    // MARK: - Accent and status

    enum Accent {
        /// Primary action, selection, focus, running.
        static let amber = Color(hex: 0xE9A23B)
        static let amberHover = Color(hex: 0xF5BD6A)
    }

    enum Status {
        /// Required, succeeded, online, kept.
        static let green = Color(hex: 0x6FB86F)
        static let greenBright = Color(hex: 0x8FCF8F)
        /// Optional, informational.
        static let blue = Color(hex: 0x6B96D6)
        static let blueBright = Color(hex: 0x8FA6D6)
        /// Excluded, failed, destructive.
        static let red = Color(hex: 0xD07A6A)
        static let redBright = Color(hex: 0xD9A090)
        /// Offline, warning, skipped.
        static let orange = Color(hex: 0xD9924A)
        static let orangeMuted = Color(hex: 0xC9884A)
        /// Duplicates.
        static let mauve = Color(hex: 0xC58BB8)

        /// A destructive confirm button — the only place red fills.
        static let destructiveFill = Color(hex: 0x8A3428)
        static let destructiveText = Color(hex: 0xFFEDE8)

        /// Badge fills: a tinted plate behind 9px uppercase text.
        static let goodBadgeFill = Color(hex: 0x1F3320)
        static let warnBadgeFill = Color(hex: 0x3A2C18)
        /// The warning tone in body copy, where `orange` would shout.
        static let warnText = Color(hex: 0xE8CFA8)
    }

    // MARK: - Tag category hues

    /// Fixed per category, used for pills, swatches and filter chips
    /// everywhere. `TagCategory.colorIndex` indexes into this — a
    /// category's colour is stored once, never invented per surface.
    ///
    /// The names are the tokens' worked example (the Concerts template),
    /// not a constraint: index 0 is simply the first hue.
    static let categoryHues: [Color] = [
        Color(hex: 0x8B93E8),  // Band
        Color(hex: 0xC58BB8),  // Recording Type
        Color(hex: 0x6FBFB0),  // Venue
        Color(hex: 0xE9A23B),  // Year
        Color(hex: 0x9DBF7F),  // Taper
    ]

    /// The hue for a category, wrapping so an index past the palette is
    /// still stable rather than a crash or a default grey.
    static func categoryHue(_ index: Int) -> Color {
        categoryHues[((index % categoryHues.count) + categoryHues.count) % categoryHues.count]
    }

    // MARK: - Type

    /// Archivo. Falls back to the system UI face when the bundled font is
    /// unavailable, so a missing resource degrades instead of crashing.
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        Fonts.uiFamily.map { Font.custom($0, fixedSize: size).weight(weight) }
            ?? .system(size: size, weight: weight)
    }

    /// JetBrains Mono — **every** filename, path, count, duration, size,
    /// timestamp, job kind, command and fingerprint. Never set one of
    /// those in the UI face: mono is what makes a column of numbers
    /// scannable and a path identifiable.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        Fonts.monoFamily.map { Font.custom($0, fixedSize: size).weight(weight) }
            ?? .system(size: size, weight: weight, design: .monospaced)
    }

    /// The named steps from the tokens. Sizes off this scale are fine
    /// where a comp measures one; these are the ones that repeat.
    enum TypeScale {
        static let windowHeading: CGFloat = 17
        static let dialogTitle: CGFloat = 15
        static let row: CGFloat = 13
        static let body: CGFloat = 12.5
        static let secondary: CGFloat = 11.5
        static let sectionLabel: CGFloat = 10
    }

    /// 10px, 700, 0.13em tracking, uppercase — the section label. Applied
    /// as a modifier because the tracking is as load-bearing as the size.
    static func sectionLabel(_ color: Color = Text.quaternary) -> some ViewModifier {
        SectionLabelStyle(color: color)
    }

    // MARK: - Geometry

    enum Radius {
        static let chip: CGFloat = 4
        static let control: CGFloat = 6
        static let button: CGFloat = 7
        static let card: CGFloat = 9
        static let window: CGFloat = 11
        /// A pill is fully rounded — clamp against the height at the call
        /// site rather than using a literal 999.
        static let pill: CGFloat = 999
    }

    enum Spacing {
        static let rowVertical: CGFloat = 10
        static let rowHorizontal: CGFloat = 14
        static let section: CGFloat = 16
        static let card: CGFloat = 9
        /// A segmented control: 2–3px around 5–6px children.
        static let segmentPadding: CGFloat = 3
    }
}

// MARK: - Section label

private struct SectionLabelStyle: ViewModifier {
    let color: Color

    func body(content: Content) -> some View {
        content
            .font(Theme.ui(Theme.TypeScale.sectionLabel, .bold))
            .tracking(Theme.TypeScale.sectionLabel * 0.13)
            .textCase(.uppercase)
            .foregroundStyle(color)
    }
}

// MARK: - Hex

extension Color {
    /// `Color(hex: 0xE9A23B)` — the tokens are written as hex, so they
    /// are read as hex. sRGB, because the token contrast ratios were
    /// measured in sRGB.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity)
    }
}

// MARK: - Fonts

/// Registers the bundled faces once, and reports the family name each
/// one actually registered under.
///
/// Both are **variable** fonts. CoreText registers a variable font under
/// its family name and synthesises the instances, so `Font.custom(family)
/// .weight(_)` selects a real weight rather than a faux-bold — but only
/// once registration has succeeded. `nil` means it did not, and every
/// call site falls back to the system face.
enum Fonts {
    static let uiFamily: String? = register("Archivo", family: "Archivo")
    static let monoFamily: String? = register("JetBrainsMono", family: "JetBrains Mono")

    /// Called at launch so registration happens before the first view
    /// draws, rather than lazily inside a body evaluation.
    static func registerAll() {
        _ = uiFamily
        _ = monoFamily
    }

    /// SPM's generated `Bundle.module` calls `fatalError` when the
    /// resource bundle is absent — which is the wrong failure mode
    /// entirely for a font, where the fallback is perfectly legible. This
    /// finds the same bundle and returns nil instead.
    ///
    /// Three locations, because the app runs three ways: inside a .app
    /// (`Contents/Resources`), as a bare `swift run` executable (beside
    /// the binary), and under the test runner (beside the xctest bundle).
    private static let resourceBundle: Bundle? = {
        let name = "SightsAndSounds_SightsAndSoundsApp.bundle"
        let candidates = [
            Bundle.main.resourceURL,
            Bundle.main.bundleURL,
            Bundle(for: BundleToken.self).resourceURL,
            Bundle(for: BundleToken.self).bundleURL.deletingLastPathComponent(),
        ]
        for base in candidates.compactMap({ $0 }) {
            if let bundle = Bundle(url: base.appendingPathComponent(name)) { return bundle }
        }
        return nil
    }()

    private static func register(_ resource: String, family: String) -> String? {
        // `.copy` in the manifest preserves the Fonts/ directory, so the
        // subdirectory is part of the lookup.
        guard let url = resourceBundle?.url(
            forResource: resource, withExtension: "ttf", subdirectory: "Fonts") else {
            AppLogNote.fontMissing(resource)
            return nil
        }
        var error: Unmanaged<CFError>?
        // .process, not .persistent: the face belongs to this process for
        // its lifetime and must not leak into the user's font book.
        let ok = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        if !ok {
            // Already registered is success — a second app instance in the
            // same process (tests, previews) hits this path.
            let code = error?.takeUnretainedValue().domainCode
            guard code == CTFontManagerError.alreadyRegistered.rawValue else {
                AppLogNote.fontFailed(resource, error?.takeUnretainedValue())
                return nil
            }
        }
        // Confirm the family is actually resolvable before handing it out:
        // a registered file with an unexpected family name would otherwise
        // silently render as the system fallback everywhere.
        guard NSFont(name: family, size: 12) != nil else {
            AppLogNote.fontFailed(resource, nil)
            return nil
        }
        return family
    }
}

private extension CFError {
    var domainCode: CFIndex { CFErrorGetCode(self) }
}

/// Only exists to give `Bundle(for:)` a class in this module to locate.
private final class BundleToken {}

/// Font problems are worth a log line and nothing more — the fallback is
/// legible, so this is never fatal.
private enum AppLogNote {
    static func fontMissing(_ name: String) {
        AppLog.shared.warning("app", "Font resource \(name) is not bundled — using the system face")
    }

    static func fontFailed(_ name: String, _ error: CFError?) {
        let detail = error.map { CFErrorCopyDescription($0) as String } ?? "family name did not resolve"
        AppLog.shared.warning("app", "Could not register \(name): \(detail)")
    }
}
