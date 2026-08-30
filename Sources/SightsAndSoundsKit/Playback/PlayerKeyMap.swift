import Foundation

/// User-adjustable seek distances for the three seek-key pairs. Field names
/// mirror the old app's playback settings (1/3 short, 4/6 medium, 7/9 long)
/// so a hand migration of saved settings is a straight copy.
public struct SkipSettings: Codable, Equatable, Sendable {
    public var key1Seconds: Double
    public var key3Seconds: Double
    public var key4Seconds: Double
    public var key6Seconds: Double
    public var key7Seconds: Double
    public var key9Seconds: Double

    public init(
        key1Seconds: Double = 2, key3Seconds: Double = 2,
        key4Seconds: Double = 30, key6Seconds: Double = 30,
        key7Seconds: Double = 240, key9Seconds: Double = 240
    ) {
        self.key1Seconds = key1Seconds
        self.key3Seconds = key3Seconds
        self.key4Seconds = key4Seconds
        self.key6Seconds = key6Seconds
        self.key7Seconds = key7Seconds
        self.key9Seconds = key9Seconds
    }
}

/// What a player keystroke does. The view layer dispatches these; the map
/// below is the ported decision table from the web app's `playerKeyboard.ts`.
public enum PlayerAction: Equatable, Sendable {
    case seek(seconds: Double)  // signed; negative = backward
    case playPause
    case seekToStart
    case seekToNearEnd
    case toggleFavorite
    case toggleNeedsReview
    case toggleMarkedForDeletion
    case togglePlaybackIssue
}

/// Which of the two keyboard maps is in force.
///
/// They agree on everything but four rows. Supporting both *live* would
/// mean two behaviours to maintain forever, so this is one app setting —
/// chosen once, consulted in exactly those four places. It is muscle
/// memory, so it is deliberately not per-library and not per-window.
public enum KeyMapStyle: String, Codable, Sendable, CaseIterable {
    /// What ships today on the Mac.
    case mac
    /// What the web app's players have in their fingers.
    case web

    public var displayName: String {
        switch self {
        case .mac: "Mac map"
        case .web: "Web map"
        }
    }
}

/// The labels for the four rows that differ — read by the transport
/// tooltips, the focus footer, the empty segment state and the `?` sheet.
/// A second copy of "the mark key is `[`" is how these drift.
public struct KeyMapLabels: Sendable, Equatable {
    public let previousNext: String
    public let segmentOpen: String
    public let segmentClose: String
    public let triage: String
}

extension KeyMapStyle {
    public var labels: KeyMapLabels {
        switch self {
        case .mac:
            KeyMapLabels(
                previousNext: "← →", segmentOpen: "⌃{", segmentClose: "⌃}",
                triage: "bound letters + advance")
        case .web:
            KeyMapLabels(
                previousNext: "⇧← ⇧→", segmentOpen: "[", segmentClose: "]",
                triage: "R W D")
        }
    }
}

/// One row of the `?` sheet: what a thing is called, and what each map
/// binds it to. The sheet is both the chooser and the permanent cheat
/// sheet, so this table is the only description of either map.
public struct KeyMapRow: Sendable, Identifiable, Equatable {
    public let label: String
    public let web: String
    public let mac: String
    public var id: String { label }
    /// Only four rows differ; the sheet highlights exactly these.
    public var differs: Bool { web != mac }

    public func keys(for style: KeyMapStyle) -> String {
        switch style {
        case .mac: mac
        case .web: web
        }
    }
}

extension KeyMapStyle {
    public static let comparison: [KeyMapRow] = [
        KeyMapRow(label: "Play / pause", web: "space · numpad 5", mac: "space · numpad 5"),
        KeyMapRow(
            label: "Seek ∓4m / ∓30s / ∓2s",
            web: "numpad 7 9 · 4 6 · 1 3", mac: "numpad 7 9 · 4 6 · 1 3"),
        KeyMapRow(label: "Previous / next item", web: "⇧← ⇧→", mac: "← →"),
        KeyMapRow(label: "Open / close a segment", web: "[  ]", mac: "⌃{  ⌃}"),
        KeyMapRow(label: "Close as a clip", web: "C", mac: "C"),
        KeyMapRow(label: "Open / close a hide block", web: "{  }", mac: "{  }"),
        KeyMapRow(
            label: "Triage keep / issue / delete",
            web: "R  W  D", mac: "bound letters + advance"),
        KeyMapRow(label: "Toggle tag panel", web: "T", mac: "T"),
        KeyMapRow(label: "Move focus zone", web: "Tab · ⇧Tab", mac: "Tab · ⇧Tab"),
        KeyMapRow(label: "Release to video", web: "Esc", mac: "Esc"),
    ]
}

/// The playback keyboard map, Phase 3 scope. Editing keys (tags, bookmarks,
/// blocks, clips, zoom) arrive with their features in Phases 4/7.
///
///   1/4/7 seek back · 3/6/9 seek forward (short/medium/long, per settings)
///   5 or Space: play/pause · 0: start · 8 or numpad −: near end
///   F favorite · R needs-review · D marked-for-deletion · W playback-issue
///
/// The same digit table answers for the numpad, Shift+digit (shifted glyphs
/// included, for layouts where Shift+4 types "$"), and plain digits — the
/// caller applies its own typing-target guard before consulting the map.
public enum PlayerKeyMap {

    // MARK: - The four rows the maps disagree on

    public enum Arrow: Sendable { case left, right }

    /// Walking the playlist: bare arrows on the Mac map, shifted arrows
    /// on the web map (where bare arrows belong to the text cursor).
    /// Returns the step, or nil when this press does not walk.
    public static func playlistStep(
        arrow: Arrow, shift: Bool, style: KeyMapStyle
    ) -> Int? {
        switch style {
        case .mac: guard !shift else { return nil }
        case .web: guard shift else { return nil }
        }
        return arrow == .left ? -1 : 1
    }

    public enum SegmentMark: Sendable { case open, close, closeAsClip }

    /// Marking a segment: `[` `]` on the web map, ⌃{ ⌃} on the Mac map.
    /// `C` closes as a clip rather than a song in both — the kind is
    /// decided at the close, when you know what you just marked.
    ///
    /// Bare `{` `}` are hide blocks in both maps and are handled
    /// separately: a hide block is not a segment record.
    ///
    /// The caller consults this only while a mark is open — with nothing
    /// marked, `C` belongs to whatever tag binding claims it.
    public static func segmentMark(
        character: Character, control: Bool, style: KeyMapStyle
    ) -> SegmentMark? {
        if character == "c" || character == "C", !control { return .closeAsClip }
        switch style {
        case .mac:
            guard control else { return nil }
            if character == "{" || character == "[" { return .open }
            if character == "}" || character == "]" { return .close }
        case .web:
            guard !control else { return nil }
            if character == "[" { return .open }
            if character == "]" { return .close }
        }
        return nil
    }

    /// The triage keys, which mark and advance while triage mode is on.
    /// The Mac map leaves triage to the user's own bound letters, so it
    /// claims none of these.
    public static func triageAction(
        character: Character, style: KeyMapStyle
    ) -> PlayerAction? {
        guard style == .web else { return nil }
        switch Character(character.lowercased()) {
        case "r": return .toggleNeedsReview
        case "w": return .togglePlaybackIssue
        case "d": return .toggleMarkedForDeletion
        default: return nil
        }
    }

    // MARK: - Everything both maps agree on

    public static func action(
        character: Character, shift: Bool, numpad: Bool,
        settings: SkipSettings = SkipSettings()
    ) -> PlayerAction? {
        let ch = Character(character.lowercased())

        if numpad, ch == "-" { return .seekToNearEnd }

        // Shift+top-row glyphs map back to their digits.
        let digit: Character? = switch ch {
        case "!": "1"
        case "#": "3"
        case "$": "4"
        case "^": "6"
        case "&": "7"
        case "(": "9"
        default: ch.isNumber ? ch : nil
        }

        if let digit {
            switch digit {
            case "1": return .seek(seconds: -settings.key1Seconds)
            case "3": return .seek(seconds: settings.key3Seconds)
            case "4": return .seek(seconds: -settings.key4Seconds)
            case "6": return .seek(seconds: settings.key6Seconds)
            case "7": return .seek(seconds: -settings.key7Seconds)
            case "9": return .seek(seconds: settings.key9Seconds)
            case "5": return .playPause
            case "0": return .seekToStart
            case "8": return .seekToNearEnd
            default: return nil
            }
        }

        guard !shift else { return nil }
        switch ch {
        case " ": return .playPause
        case "f": return .toggleFavorite
        case "r": return .toggleNeedsReview
        case "d": return .toggleMarkedForDeletion
        case "w": return .togglePlaybackIssue
        default: return nil
        }
    }
}
