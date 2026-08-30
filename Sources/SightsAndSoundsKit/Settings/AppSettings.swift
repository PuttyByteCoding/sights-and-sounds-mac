import Foundation

/// App-level settings — the contents of `settings.json`. Every field has
/// a default; a hand-edited file with missing or extra keys loads
/// cleanly (decode is per-key tolerant). Per-LIBRARY data (tag key
/// bindings, category configuration) deliberately does NOT live here —
/// libraries stay portable.
public struct AppSettings: Codable, Sendable, Equatable {
    /// nil = the built-in default under Application Support.
    public var backupDirectory: String?
    /// When set, the debug log also appends to a daily file here.
    public var logDirectory: String?
    /// nil = the built-in Caches location.
    public var thumbnailDirectory: String?

    public var videoExtensions: [String]
    public var audioExtensions: [String]

    public var skip: SkipSettings

    /// Videos begin playback muted (audio items never do).
    public var startVideosMuted: Bool

    /// Playback restarts from the beginning at the end of the item.
    public var loopVideos: Bool

    /// Which elements the player's info bar shows.
    public var infoBar: InfoBarSettings

    /// The browse grid's display: thumbnail size, and which fields show
    /// under each thumbnail.
    public var grid: GridSettings

    /// The player's panel layout — sizes survive item switches and
    /// launches; the video is the flexible center and shrinks to fit.
    public var playerLayout: PlayerLayoutSettings

    /// Where the fitted video sits inside the player area.
    public var videoAnchor: VideoAnchor

    public var ocrSampleIntervalSeconds: Double
    public var ocrBudgetSecondsPerRun: Double

    public static let defaultVideoExtensions = [
        "mp4", "m4v", "mov", "mpg", "mpeg", "avi", "mkv", "wmv", "flv", "webm", "ts",
    ]
    public static let defaultAudioExtensions = [
        "flac", "mp3", "m4a", "aac", "wav", "aiff", "aif", "ogg", "opus", "shn", "wma",
    ]

    public init(
        backupDirectory: String? = nil,
        logDirectory: String? = nil,
        thumbnailDirectory: String? = nil,
        videoExtensions: [String] = AppSettings.defaultVideoExtensions,
        audioExtensions: [String] = AppSettings.defaultAudioExtensions,
        skip: SkipSettings = SkipSettings(),
        startVideosMuted: Bool = true,
        loopVideos: Bool = true,
        infoBar: InfoBarSettings = InfoBarSettings(),
        grid: GridSettings = GridSettings(),
        playerLayout: PlayerLayoutSettings = PlayerLayoutSettings(),
        videoAnchor: VideoAnchor = .topLeft,
        ocrSampleIntervalSeconds: Double = 5,
        ocrBudgetSecondsPerRun: Double = 600
    ) {
        self.backupDirectory = backupDirectory
        self.logDirectory = logDirectory
        self.thumbnailDirectory = thumbnailDirectory
        self.videoExtensions = videoExtensions
        self.audioExtensions = audioExtensions
        self.skip = skip
        self.startVideosMuted = startVideosMuted
        self.loopVideos = loopVideos
        self.infoBar = infoBar
        self.grid = grid
        self.playerLayout = playerLayout
        self.videoAnchor = videoAnchor
        self.ocrSampleIntervalSeconds = ocrSampleIntervalSeconds
        self.ocrBudgetSecondsPerRun = ocrBudgetSecondsPerRun
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        backupDirectory = try container.decodeIfPresent(String.self, forKey: .backupDirectory)
        logDirectory = try container.decodeIfPresent(String.self, forKey: .logDirectory)
        thumbnailDirectory = try container.decodeIfPresent(String.self, forKey: .thumbnailDirectory)
        videoExtensions = try container.decodeIfPresent([String].self, forKey: .videoExtensions)
            ?? defaults.videoExtensions
        audioExtensions = try container.decodeIfPresent([String].self, forKey: .audioExtensions)
            ?? defaults.audioExtensions
        skip = try container.decodeIfPresent(SkipSettings.self, forKey: .skip) ?? defaults.skip
        startVideosMuted = try container.decodeIfPresent(Bool.self, forKey: .startVideosMuted)
            ?? defaults.startVideosMuted
        loopVideos = try container.decodeIfPresent(Bool.self, forKey: .loopVideos)
            ?? defaults.loopVideos
        infoBar = try container.decodeIfPresent(InfoBarSettings.self, forKey: .infoBar)
            ?? defaults.infoBar
        grid = try container.decodeIfPresent(GridSettings.self, forKey: .grid)
            ?? defaults.grid
        playerLayout = try container.decodeIfPresent(
            PlayerLayoutSettings.self, forKey: .playerLayout) ?? defaults.playerLayout
        videoAnchor = try container.decodeIfPresent(VideoAnchor.self, forKey: .videoAnchor)
            ?? defaults.videoAnchor
        ocrSampleIntervalSeconds = try container.decodeIfPresent(
            Double.self, forKey: .ocrSampleIntervalSeconds) ?? defaults.ocrSampleIntervalSeconds
        ocrBudgetSecondsPerRun = try container.decodeIfPresent(
            Double.self, forKey: .ocrBudgetSecondsPerRun) ?? defaults.ocrBudgetSecondsPerRun
    }
}

/// Which elements the player shows in the info bar under the video.
/// All on by default; the bar hides entirely when every element is off.
public struct InfoBarSettings: Codable, Equatable, Sendable {
    /// "x of y" — position in the filtered listing playback opened from.
    public var showsPosition: Bool
    public var showsTags: Bool
    public var showsFavorite: Bool
    public var showsDownload: Bool

    public init(
        showsPosition: Bool = true,
        showsTags: Bool = true,
        showsFavorite: Bool = true,
        showsDownload: Bool = true
    ) {
        self.showsPosition = showsPosition
        self.showsTags = showsTags
        self.showsFavorite = showsFavorite
        self.showsDownload = showsDownload
    }

    public var showsAnything: Bool {
        showsPosition || showsTags || showsFavorite || showsDownload
    }
}

/// Where one thumbnail-metadata field rendered before saved tile views
/// (#99): not at all, under the thumbnail, or overlaid in a corner.
///
/// Kept only to read a settings.json written by an earlier build — the
/// decoder folds those placements into a view named `Custom` so nobody's
/// configuration resets. Nothing writes it any more.
public enum FieldPlacement: String, Codable, Sendable, CaseIterable {
    case hidden, under, topLeft, topRight, bottomLeft, bottomRight

    /// Where the same field sits in the eleven-slot layout.
    var tileSlot: TileSlot? {
        switch self {
        case .hidden: nil
        case .under: .below
        case .topLeft: .topLeft
        case .topRight: .topRight
        case .bottomLeft: .bottomLeft
        case .bottomRight: .bottomRight
        }
    }
}

/// The browse grid's display configuration: how big the tiles are, what
/// they say, and whether they keep a uniform frame.
///
/// What they say is a list of named **views** rather than one set of
/// switches, because the answer changes with the task — triaging,
/// tagging, or just looking — and `V` cycles them. Decode carries
/// forward both older shapes: the per-field booleans of the first grid,
/// and the placements that replaced them.
public struct GridSettings: Codable, Equatable, Sendable {
    /// Adaptive column minimum, in points (the maximum tracks at 1.4x).
    public var thumbnailSize: Double
    /// Tiles keep one frame per media kind; anything narrower pillarboxes
    /// inside it. Turn this on when you are actually reviewing phone
    /// footage and the ragged grid is the point.
    public var fitToAspect: Bool
    public var views: [TileView]
    /// nil = the first view.
    public var activeViewID: UUID?

    public init(
        thumbnailSize: Double = 200,
        fitToAspect: Bool = false,
        views: [TileView] = TileView.shipped,
        activeViewID: UUID? = nil
    ) {
        self.thumbnailSize = thumbnailSize
        self.fitToAspect = fitToAspect
        self.views = views.isEmpty ? TileView.shipped : views
        self.activeViewID = activeViewID
    }

    /// Never nil: a settings file naming a view that has since been
    /// deleted falls back to the first rather than to an empty tile.
    public var activeView: TileView {
        views.first { $0.id == activeViewID } ?? views[0]
    }

    public var activeIndex: Int {
        views.firstIndex { $0.id == activeViewID } ?? 0
    }

    /// True when the active view shows a field needing the per-item tag
    /// join — the grid's batch queries run only then.
    public var needsTagData: Bool {
        let view = activeView
        return view.contains(.tags) || view.contains(.missingTags)
            || view.placements.contains { placement in
                placement.entries.contains {
                    if case .tagsIn = $0.value { return true }
                    return false
                }
            }
    }

    public var needsDuplicateData: Bool { activeView.contains(.duplicate) }

    private enum CodingKeys: String, CodingKey {
        case thumbnailSize, fitToAspect, views, activeViewID
    }

    /// Both older shapes of this section, read but never written.
    private enum LegacyKeys: String, CodingKey {
        case showsFileName, showsPath, showsTags, showsMissingCategories
        case showsImportDate, showsViewCount, showsDeleted, showsDuplicate
        case showsClip, showsDuration, showsFileSize, showsFavorite
        case showsDimensions, showsReviewed
        case fileName, path, tags, missingCategories, importDate, viewCount
        case deleted, duplicate, clip, duration, fileSize, favorite
        case dimensions, reviewed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = GridSettings()
        thumbnailSize = try container.decodeIfPresent(Double.self, forKey: .thumbnailSize)
            ?? defaults.thumbnailSize
        fitToAspect = try container.decodeIfPresent(Bool.self, forKey: .fitToAspect)
            ?? defaults.fitToAspect
        let stored = try container.decodeIfPresent([TileView].self, forKey: .views)
        if let stored, !stored.isEmpty {
            views = stored
            activeViewID = try container.decodeIfPresent(UUID.self, forKey: .activeViewID)
            return
        }
        // No views yet: fold whatever the older file said into one named
        // view, so a grid someone configured keeps saying what it said.
        let legacy = try? decoder.container(keyedBy: LegacyKeys.self)
        let carried = legacy.flatMap { Self.carriedForward(from: $0) }
        views = TileView.shipped + (carried.map { [$0] } ?? [])
        activeViewID = carried?.id
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(thumbnailSize, forKey: .thumbnailSize)
        try container.encode(fitToAspect, forKey: .fitToAspect)
        try container.encode(views, forKey: .views)
        try container.encodeIfPresent(activeViewID, forKey: .activeViewID)
    }

    /// The fourteen fields of the previous two shapes, in the order they
    /// were listed, as one view.
    private static func carriedForward(
        from legacy: KeyedDecodingContainer<LegacyKeys>
    ) -> TileView? {
        let fields: [(LegacyKeys, LegacyKeys, TileValue)] = [
            (.fileName, .showsFileName, .fileName),
            (.path, .showsPath, .path),
            (.tags, .showsTags, .tags),
            (.missingCategories, .showsMissingCategories, .missingTags),
            (.importDate, .showsImportDate, .importDate),
            (.viewCount, .showsViewCount, .viewCount),
            (.deleted, .showsDeleted, .markedForDeletion),
            (.duplicate, .showsDuplicate, .duplicate),
            (.clip, .showsClip, .clip),
            (.duration, .showsDuration, .duration),
            (.fileSize, .showsFileSize, .fileSize),
            (.favorite, .showsFavorite, .favorite),
            (.dimensions, .showsDimensions, .format),
            (.reviewed, .showsReviewed, .needsReview),
        ]
        var slots: [TileSlot: [TileValue]] = [:]
        var sawAnything = false
        for (key, booleanKey, value) in fields {
            var placement: FieldPlacement?
            if let stored = (try? legacy.decodeIfPresent(FieldPlacement.self, forKey: key)) ?? nil {
                placement = stored
            } else if let old = (try? legacy.decodeIfPresent(Bool.self, forKey: booleanKey)) ?? nil {
                placement = old ? .under : .hidden
            }
            guard let placement else { continue }
            sawAnything = true
            if let slot = placement.tileSlot { slots[slot, default: []].append(value) }
        }
        guard sawAnything else { return nil }
        return TileView(
            name: "Custom",
            placements: TileSlot.allCases.compactMap { slot in
                guard let values = slots[slot] else { return nil }
                return TileView.placement(slot, values)
            })
    }
}

/// The player's resizable-panel layout. Clamps live at the drag sites;
/// these are the remembered sizes.
public struct PlayerLayoutSettings: Codable, Equatable, Sendable {
    /// Tag panel width, points.
    public var tagPanelWidth: Double
    /// On-Screen Text panel width, points.
    public var textPanelWidth: Double
    /// Play-queue strip height, points — also the thumbnail scale.
    public var queueHeight: Double
    public var showsQueue: Bool

    public init(
        tagPanelWidth: Double = 300,
        textPanelWidth: Double = 300,
        queueHeight: Double = 120,
        showsQueue: Bool = true
    ) {
        self.tagPanelWidth = tagPanelWidth
        self.textPanelWidth = textPanelWidth
        self.queueHeight = queueHeight
        self.showsQueue = showsQueue
    }

    /// Per-key tolerant, like AppSettings itself — a stored layout from
    /// before a field existed must not throw the whole file back to
    /// defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = PlayerLayoutSettings()
        tagPanelWidth = try container.decodeIfPresent(Double.self, forKey: .tagPanelWidth)
            ?? defaults.tagPanelWidth
        textPanelWidth = try container.decodeIfPresent(Double.self, forKey: .textPanelWidth)
            ?? defaults.textPanelWidth
        queueHeight = try container.decodeIfPresent(Double.self, forKey: .queueHeight)
            ?? defaults.queueHeight
        showsQueue = try container.decodeIfPresent(Bool.self, forKey: .showsQueue)
            ?? defaults.showsQueue
    }
}

/// The seven anchor positions for the fitted video (#92). Raw strings —
/// settings.json stays hand-editable.
public enum VideoAnchor: String, Codable, Sendable, CaseIterable {
    case topLeft, topCenter, topRight
    case bottomLeft, bottomCenter, bottomRight
    case center

    public var displayName: String {
        switch self {
        case .topLeft: "Top Left"
        case .topCenter: "Top Center"
        case .topRight: "Top Right"
        case .bottomLeft: "Bottom Left"
        case .bottomCenter: "Bottom Center"
        case .bottomRight: "Bottom Right"
        case .center: "Centered"
        }
    }
}

/// The store: loads `settings.json` once, hands out the current value,
/// saves on update. Consumers read `AppSettingsStore.shared.current` at
/// use time, so changes apply to the next operation without relaunch.
public final class AppSettingsStore: @unchecked Sendable {
    public static let shared = AppSettingsStore()

    private let lock = NSLock()
    private var settings: AppSettings
    private let fileURL: URL

    public var current: AppSettings {
        lock.lock()
        defer { lock.unlock() }
        return settings
    }

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        settings = Self.load(from: self.fileURL) ?? AppSettings()
    }

    public static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("SightsAndSounds/settings.json")
    }

    static func load(from url: URL) -> AppSettings? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(AppSettings.self, from: data)
        } catch {
            AppLog.shared.error("settings", "settings.json is invalid — using defaults: \(error)")
            return nil
        }
    }

    /// Mutate-and-save. The JSON is written pretty-printed and stable so
    /// hand edits diff cleanly.
    public func update(_ mutate: (inout AppSettings) -> Void) {
        lock.lock()
        var updated = settings
        mutate(&updated)
        settings = updated
        lock.unlock()

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(updated)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            AppLog.shared.error("settings", "could not save settings.json: \(error)")
        }
    }

    /// One-time migration of the pre-settings seek-distance preference.
    public func migrateLegacySkip(from appDatabase: AppDatabase) {
        migrateLegacySkipForTesting(from: appDatabase)
    }

    func migrateLegacySkipForTesting(from appDatabase: AppDatabase) {
        guard !FileManager.default.fileExists(atPath: fileURL.path),
              let raw = try? appDatabase.preference("playbackSkips"),
              let legacy = try? JSONDecoder().decode(SkipSettings.self, from: Data(raw.utf8))
        else { return }
        update { $0.skip = legacy }
        AppLog.shared.info("settings", "migrated seek distances into settings.json")
    }
}
