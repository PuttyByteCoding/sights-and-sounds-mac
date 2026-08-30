import Foundation

/// The media kinds one listing includes.
///
/// The old app's standing rule — every listing surface hard-filters by
/// media kind — is kept; what changes is that a listing may name *several*
/// kinds instead of exactly one. The guard moves into the query rather
/// than going away, and this type is where it lives: every listing path
/// passes a `MediaKinds`, and a `MediaKinds` can never be empty. "No kind
/// selected" — which means everything or nothing depending on who wrote
/// the SQL, and leaked rows in the web app — is unrepresentable.
///
/// The sidebar's checkboxes are the reason for `toggle`: it refuses to
/// clear the last kind, so the UI rule ("the last one is not
/// unselectable") is the type's rule and not a check some view remembers
/// to make.
public struct MediaKinds: Hashable, Sendable {
    /// Never empty.
    public private(set) var kinds: Set<MediaKind>

    /// An empty set falls back to video rather than trapping: a decoded
    /// settings file or a hand-edited JSON must not be able to crash the
    /// app, and a listing showing videos is a recoverable wrong answer
    /// where a listing showing everything is not.
    public init(_ kinds: some Sequence<MediaKind>) {
        let set = Set(kinds)
        self.kinds = set.isEmpty ? [.video] : set
    }

    public static let video = MediaKinds([.video])
    public static let audio = MediaKinds([.audio])
    public static let all = MediaKinds(MediaKind.allCases)

    public func contains(_ kind: MediaKind) -> Bool { kinds.contains(kind) }

    public var isSingle: Bool { kinds.count == 1 }

    /// Declaration order (video, then audio) — the order the sidebar lists
    /// them in, so a summary line reads the same everywhere.
    public var ordered: [MediaKind] { MediaKind.allCases.filter(kinds.contains) }

    /// Turn one kind on or off. Returns false when the change was refused
    /// because it would have emptied the selection — the caller says so
    /// rather than silently doing nothing.
    @discardableResult
    public mutating func toggle(_ kind: MediaKind) -> Bool {
        if kinds.contains(kind) {
            guard kinds.count > 1 else { return false }
            kinds.remove(kind)
        } else {
            kinds.insert(kind)
        }
        return true
    }
}

extension MediaKind: CustomStringConvertible {
    /// The one place a media kind is named for a person. Five surfaces
    /// were about to spell these out themselves.
    public var displayName: String {
        switch self {
        case .video: "Video"
        case .audio: "Audio"
        }
    }

    public var description: String { displayName }
}
