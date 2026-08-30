import Foundation

/// One of the eleven places a value can sit on a tile: seven overlaying
/// the thumbnail, and an outer ring of four that sits beside it.
///
/// The ring is what makes this more than a corner-badge scheme — a
/// filename below the image and a year in the left gutter cost the
/// picture nothing, which matters at 10,000 tiles.
public enum TileSlot: String, Codable, Sendable, CaseIterable {
    case topLeft, topCenter, topRight
    case middleCenter
    case bottomLeft, bottomCenter, bottomRight
    case above, leading, trailing, below

    /// Overlay slots sit on the image and take a scrim; the outer ring
    /// sits on the tile background and reads as plain text.
    public var isOverlay: Bool {
        switch self {
        case .above, .leading, .trailing, .below: false
        default: true
        }
    }

    public var displayName: String {
        switch self {
        case .topLeft: "Top left"
        case .topCenter: "Top centre"
        case .topRight: "Top right"
        case .middleCenter: "Middle"
        case .bottomLeft: "Bottom left"
        case .bottomCenter: "Bottom centre"
        case .bottomRight: "Bottom right"
        case .above: "Above the thumbnail"
        case .leading: "Left of the thumbnail"
        case .trailing: "Right of the thumbnail"
        case .below: "Below the thumbnail"
        }
    }

    /// Defaults come from the SLOT, so an untouched value already reads
    /// correctly for where it sits and nobody has to open the controls.
    public var defaultAlignment: TileAlignment {
        switch self {
        case .topLeft, .bottomLeft, .above, .below: .leading
        case .topCenter, .bottomCenter, .middleCenter: .center
        case .topRight, .bottomRight: .trailing
        case .leading: .trailing
        case .trailing: .leading
        }
    }

    /// The wide strips can afford to wrap; a corner badge never should.
    public var defaultWraps: Bool { self == .above || self == .below }
}

public enum TileAlignment: String, Codable, Sendable, CaseIterable {
    case leading, center, trailing

    public var displayName: String {
        switch self {
        case .leading: "Left"
        case .center: "Centre"
        case .trailing: "Right"
        }
    }
}

/// How wide a value renders in its slot.
public enum TileWidth: Codable, Hashable, Sendable {
    case auto
    case fill
    case fixed(Double)
}

/// Everything a tile can display.
///
/// A value that does not apply renders **nothing** — no placeholder, no
/// reserved space — so a favourite star and an offline badge cost
/// nothing on the items that are neither.
public enum TileValue: Hashable, Sendable {
    case duration
    /// Resolution for video, sample rate and channels for audio.
    case format
    case fileSize
    case fileName
    case path
    case source
    case mediaType
    /// Only when the media is not landscape — `⇕ 9:16` beside a
    /// pillarboxed frame.
    case aspect
    case importDate
    case viewCount
    case favorite
    case offline
    case needsReview
    case playbackIssue
    case markedForDeletion
    case clip
    case duplicate
    /// Categories this item has no tag in yet.
    case missingTags
    /// Every tag, in category order.
    case tags
    /// One category's tags, so a view can show just Band, or Band + Year.
    case tagsIn(UUID)

    /// Tags render as pills wherever they appear; everything else is a
    /// badge or plain text.
    public var isPill: Bool {
        switch self {
        case .tags, .tagsIn: true
        default: false
        }
    }
}

extension TileValue: RawRepresentable {
    public var rawValue: String {
        switch self {
        case .duration: "duration"
        case .format: "format"
        case .fileSize: "fileSize"
        case .fileName: "fileName"
        case .path: "path"
        case .source: "source"
        case .mediaType: "mediaType"
        case .aspect: "aspect"
        case .importDate: "importDate"
        case .viewCount: "viewCount"
        case .favorite: "favorite"
        case .offline: "offline"
        case .needsReview: "needsReview"
        case .playbackIssue: "playbackIssue"
        case .markedForDeletion: "markedForDeletion"
        case .clip: "clip"
        case .duplicate: "duplicate"
        case .missingTags: "missingTags"
        case .tags: "tags"
        case .tagsIn(let id): "tags:\(id.uuidString)"
        }
    }

    public init?(rawValue: String) {
        if rawValue.hasPrefix("tags:") {
            guard let id = UUID(uuidString: String(rawValue.dropFirst(5))) else { return nil }
            self = .tagsIn(id)
            return
        }
        let simple: [String: TileValue] = [
            "duration": .duration, "format": .format, "fileSize": .fileSize,
            "fileName": .fileName, "path": .path, "source": .source,
            "mediaType": .mediaType, "aspect": .aspect, "importDate": .importDate,
            "viewCount": .viewCount, "favorite": .favorite, "offline": .offline,
            "needsReview": .needsReview, "playbackIssue": .playbackIssue,
            "markedForDeletion": .markedForDeletion, "clip": .clip,
            "duplicate": .duplicate, "missingTags": .missingTags, "tags": .tags,
        ]
        guard let value = simple[rawValue] else { return nil }
        self = value
    }
}

extension TileValue: Codable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let value = TileValue(rawValue: raw) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "unknown tile value \(raw)"))
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// One value in one slot, with the settings that only appear once you
/// have chosen it. `nil` means "whatever the slot says", so a view file
/// records a decision only where one was made.
public struct TileEntry: Codable, Hashable, Sendable {
    public var value: TileValue
    public var wraps: Bool?
    public var alignment: TileAlignment?
    public var width: TileWidth?

    public init(
        _ value: TileValue, wraps: Bool? = nil,
        alignment: TileAlignment? = nil, width: TileWidth? = nil
    ) {
        self.value = value
        self.wraps = wraps
        self.alignment = alignment
        self.width = width
    }

    public func wraps(in slot: TileSlot) -> Bool { wraps ?? slot.defaultWraps }
    public func alignment(in slot: TileSlot) -> TileAlignment {
        alignment ?? slot.defaultAlignment
    }
    public func width(in slot: TileSlot) -> TileWidth { width ?? .auto }
}

/// A named arrangement of values over a tile. Views are duplicated,
/// renamed, deleted and cycled with `V`; the point is that "what a tile
/// says" changes with what you are doing — triaging, tagging, or just
/// looking — and none of those wants the same eleven answers.
public struct TileView: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    /// Stored as a list rather than a dictionary so the JSON is stable
    /// and hand-editable, which is the rule the rest of settings.json
    /// already follows.
    public var placements: [Placement]

    public struct Placement: Codable, Hashable, Sendable {
        public var slot: TileSlot
        public var entries: [TileEntry]

        public init(slot: TileSlot, entries: [TileEntry]) {
            self.slot = slot
            self.entries = entries
        }
    }

    public init(id: UUID = UUID(), name: String, placements: [Placement] = []) {
        self.id = id
        self.name = name
        self.placements = placements
    }

    public func entries(in slot: TileSlot) -> [TileEntry] {
        placements.first { $0.slot == slot }?.entries ?? []
    }

    public func contains(_ value: TileValue) -> Bool {
        placements.contains { $0.entries.contains { $0.value == value } }
    }

    public func slot(of value: TileValue) -> TileSlot? {
        placements.first { $0.entries.contains { $0.value == value } }?.slot
    }

    /// Add or remove a value in a slot. A value lives in one slot at a
    /// time — the same rule the filter slots follow, for the same reason.
    public mutating func toggle(_ value: TileValue, in slot: TileSlot) {
        if entries(in: slot).contains(where: { $0.value == value }) {
            remove(value)
        } else {
            remove(value)
            if let index = placements.firstIndex(where: { $0.slot == slot }) {
                placements[index].entries.append(TileEntry(value))
            } else {
                placements.append(Placement(slot: slot, entries: [TileEntry(value)]))
            }
        }
    }

    public mutating func remove(_ value: TileValue) {
        for index in placements.indices {
            placements[index].entries.removeAll { $0.value == value }
        }
        placements.removeAll { $0.entries.isEmpty }
    }

    public mutating func update(_ value: TileValue, _ mutate: (inout TileEntry) -> Void) {
        for index in placements.indices {
            for entryIndex in placements[index].entries.indices
            where placements[index].entries[entryIndex].value == value {
                mutate(&placements[index].entries[entryIndex])
            }
        }
    }

    /// A copy under a new identity — Duplicate, which is how anyone
    /// sane starts a new view.
    public func duplicated(named name: String) -> TileView {
        TileView(id: UUID(), name: name, placements: placements)
    }

    // MARK: - The shipped views

    static func placement(_ slot: TileSlot, _ values: [TileValue]) -> Placement {
        Placement(slot: slot, entries: values.map { TileEntry($0) })
    }

    /// Fixed ids, so the view a settings file names is the same view the
    /// defaults describe — a freshly generated id per launch would make
    /// `activeViewID` meaningless the moment the file was written.
    private static func shippedID(_ index: Int) -> UUID {
        UUID(uuidString: "5A5C0000-0000-4000-8000-00000000000\(index)")!
    }

    /// Five views covering what people actually do with a grid this size.
    /// They are seeds, not fixtures: every one can be renamed, edited or
    /// deleted.
    public static var shipped: [TileView] {
        [
            TileView(
                id: shippedID(1),
                name: "Default",
                placements: [
                    placement(.topLeft, [.offline, .aspect]),
                    placement(.topRight, [.favorite]),
                    placement(.bottomLeft, [.format]),
                    placement(.bottomRight, [.duration]),
                    placement(.below, [.fileName]),
                ]),
            TileView(
                id: shippedID(2),
                name: "Triage",
                placements: [
                    placement(.topLeft, [.needsReview, .playbackIssue, .markedForDeletion]),
                    placement(.topRight, [.favorite]),
                    placement(.bottomRight, [.duration]),
                    placement(.below, [.fileName, .tags]),
                ]),
            TileView(
                id: shippedID(3),
                name: "Tagging",
                placements: [
                    placement(.topRight, [.favorite]),
                    placement(.bottomRight, [.duration]),
                    placement(.below, [.fileName, .tags, .missingTags]),
                ]),
            TileView(
                id: shippedID(4),
                name: "Contact sheet",
                placements: [
                    placement(.above, [.source]),
                    placement(.bottomRight, [.duration]),
                ]),
            TileView(
                id: shippedID(5), name: "Clean",
                placements: [placement(.bottomRight, [.duration])]),
        ]
    }
}
