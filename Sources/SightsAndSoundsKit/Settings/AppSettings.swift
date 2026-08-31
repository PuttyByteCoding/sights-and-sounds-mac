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

    /// Which keyboard map the player answers to. One setting, chosen
    /// once: the two maps differ on four rows, and every hint in the
    /// player reads its labels from this.
    public var keyMap: KeyMapStyle

    /// The browse grid's display: thumbnail size, and which fields show
    /// under each thumbnail.
    public var grid: GridSettings

    /// How many tag suggestions the tagging field offers at once.
    /// Enough to scan, few enough to arrow through — and a matter of
    /// screen height, which is why it is a setting rather than a number
    /// baked into the view.
    public var tagSuggestionLimit: Int

    /// The order a library window opens with. `.random` deals a fresh
    /// shuffle each time a window opens, which is what makes it useful
    /// for surfacing things you have not seen.
    public var defaultOrdering: DefaultOrdering

    /// The player's panel layout — sizes survive item switches and
    /// launches; the video is the flexible center and shrinks to fit.
    public var playerLayout: PlayerLayoutSettings

    /// Where the fitted video sits inside the player area.
    public var videoAnchor: VideoAnchor

    public var ocrSampleIntervalSeconds: Double
    public var ocrBudgetSecondsPerRun: Double

    /// The rest of what Vision is told. Five of these were hard-coded in
    /// the job; the Operations window is the one place OCR is *produced*
    /// rather than read, so it is the one place they belong.
    public var ocr: OcrSettings
    /// App-wide UI zoom, driven by ⌘= / ⌘− / ⌘0. Clamped on the way in
    /// so a hand-edited file cannot render the app unusable.
    public var uiScale: Double

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
        keyMap: KeyMapStyle = .mac,
        grid: GridSettings = GridSettings(),
        defaultOrdering: DefaultOrdering = .path,
        tagSuggestionLimit: Int = 15,
        playerLayout: PlayerLayoutSettings = PlayerLayoutSettings(),
        videoAnchor: VideoAnchor = .topLeft,
        ocrSampleIntervalSeconds: Double = 5,
        ocrBudgetSecondsPerRun: Double = 600,
        ocr: OcrSettings = OcrSettings(),
        uiScale: Double = 1.0
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
        self.keyMap = keyMap
        self.grid = grid
        self.defaultOrdering = defaultOrdering
        self.tagSuggestionLimit = tagSuggestionLimit
        self.playerLayout = playerLayout
        self.videoAnchor = videoAnchor
        self.ocrSampleIntervalSeconds = ocrSampleIntervalSeconds
        self.ocrBudgetSecondsPerRun = ocrBudgetSecondsPerRun
        self.ocr = ocr
        self.uiScale = uiScale
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
        keyMap = try container.decodeIfPresent(KeyMapStyle.self, forKey: .keyMap)
            ?? defaults.keyMap
        grid = try container.decodeIfPresent(GridSettings.self, forKey: .grid)
            ?? defaults.grid
        // decodeIfPresent like every field here: a settings.json written
        // before this setting existed still has to load.
        defaultOrdering = try container.decodeIfPresent(
            DefaultOrdering.self, forKey: .defaultOrdering) ?? defaults.defaultOrdering
        // Clamped on the way in: a hand-edited settings.json saying 0 or
        // 5000 should not make the field useless or unscrollable.
        tagSuggestionLimit = min(50, max(3, try container.decodeIfPresent(
            Int.self, forKey: .tagSuggestionLimit) ?? defaults.tagSuggestionLimit))
        playerLayout = try container.decodeIfPresent(
            PlayerLayoutSettings.self, forKey: .playerLayout) ?? defaults.playerLayout
        videoAnchor = try container.decodeIfPresent(VideoAnchor.self, forKey: .videoAnchor)
            ?? defaults.videoAnchor
        ocrSampleIntervalSeconds = try container.decodeIfPresent(
            Double.self, forKey: .ocrSampleIntervalSeconds) ?? defaults.ocrSampleIntervalSeconds
        ocrBudgetSecondsPerRun = try container.decodeIfPresent(
            Double.self, forKey: .ocrBudgetSecondsPerRun) ?? defaults.ocrBudgetSecondsPerRun
        ocr = try container.decodeIfPresent(OcrSettings.self, forKey: .ocr) ?? defaults.ocr
        uiScale = min(1.8, max(0.7, try container.decodeIfPresent(
            Double.self, forKey: .uiScale) ?? defaults.uiScale))
    }
}

/// The two facts the player still lets you turn off.
///
/// It was four. Tag pills and the favourite star are gone from here
/// because both now have a permanent home — the tag panel shows the same
/// taggings with their category hue, and the flags are toolbar toggles —
/// and a setting for whether a fact appears in one of its two places is
/// a setting nobody can answer. Older files decode without them.
public struct InfoBarSettings: Codable, Equatable, Sendable {
    /// "x of y" — position in the filtered listing playback opened from.
    /// Now in the footer, beside the focus zone.
    public var showsPosition: Bool
    public var showsDownload: Bool

    public init(showsPosition: Bool = true, showsDownload: Bool = true) {
        self.showsPosition = showsPosition
        self.showsDownload = showsDownload
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = InfoBarSettings()
        showsPosition = try container.decodeIfPresent(Bool.self, forKey: .showsPosition)
            ?? defaults.showsPosition
        showsDownload = try container.decodeIfPresent(Bool.self, forKey: .showsDownload)
            ?? defaults.showsDownload
    }
}

/// What Vision is told when it reads a frame.
///
/// The job hard-coded `.accurate` and `usesLanguageCorrection = false`;
/// everything else was not expressible at all. Each of these maps to a
/// `VNRecognizeTextRequest` property or to the sampling loop, and each
/// one changes what a scan costs — which is why the window shows the
/// frame count beside them.
public struct OcrSettings: Codable, Equatable, Sendable {
    public enum RecognitionLevel: String, Codable, Sendable, CaseIterable {
        /// Slower, better with awkward type.
        case accurate
        /// Roughly an order of magnitude faster, and enough for large
        /// burned-in captions.
        case fast

        public var displayName: String {
            switch self {
            case .accurate: "Accurate"
            case .fast: "Fast"
            }
        }
    }

    /// Where in the frame to look, as fractions of the frame. Full frame
    /// by default; a stage banner lives up top and a caption at the
    /// bottom, and narrowing the region is the cheapest accuracy win
    /// there is.
    public struct Region: Codable, Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double = 0, y: Double = 0, width: Double = 1, height: Double = 1) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        public static let full = Region()
        public var isFull: Bool { self == .full }
    }

    public var recognitionLevel: RecognitionLevel
    /// As a share of frame height. Lower catches captions and credits;
    /// it also catches noise.
    public var minimumTextHeight: Double
    public var region: Region
    /// Vision guesses at plausible misreads. Off is literal — better
    /// when the text is a band name it will not know.
    public var usesLanguageCorrection: Bool
    /// The same banner across 200 frames is 200 identical lines unless
    /// they are collapsed.
    public var collapseRepeats: Bool

    public init(
        recognitionLevel: RecognitionLevel = .accurate,
        minimumTextHeight: Double = 0.03,
        region: Region = .full,
        usesLanguageCorrection: Bool = false,
        collapseRepeats: Bool = true
    ) {
        self.recognitionLevel = recognitionLevel
        self.minimumTextHeight = minimumTextHeight
        self.region = region
        self.usesLanguageCorrection = usesLanguageCorrection
        self.collapseRepeats = collapseRepeats
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = OcrSettings()
        recognitionLevel = try container.decodeIfPresent(
            RecognitionLevel.self, forKey: .recognitionLevel) ?? defaults.recognitionLevel
        minimumTextHeight = try container.decodeIfPresent(
            Double.self, forKey: .minimumTextHeight) ?? defaults.minimumTextHeight
        region = try container.decodeIfPresent(Region.self, forKey: .region) ?? defaults.region
        usesLanguageCorrection = try container.decodeIfPresent(
            Bool.self, forKey: .usesLanguageCorrection) ?? defaults.usesLanguageCorrection
        collapseRepeats = try container.decodeIfPresent(
            Bool.self, forKey: .collapseRepeats) ?? defaults.collapseRepeats
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

/// Which of the player's four panels are on screen. Each collapses from
/// the toolbar and is remembered, because whether you want the segments
/// rail up is a fact about how you work, not about this item.
public struct PlayerPanels: Codable, Equatable, Sendable {
    public var tags: Bool
    public var segments: Bool
    public var queue: Bool
    /// On-screen text starts collapsed: most items have none.
    public var text: Bool

    public init(
        tags: Bool = true, segments: Bool = true, queue: Bool = true, text: Bool = false
    ) {
        self.tags = tags
        self.segments = segments
        self.queue = queue
        self.text = text
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = PlayerPanels()
        tags = try container.decodeIfPresent(Bool.self, forKey: .tags) ?? defaults.tags
        segments = try container.decodeIfPresent(Bool.self, forKey: .segments) ?? defaults.segments
        queue = try container.decodeIfPresent(Bool.self, forKey: .queue) ?? defaults.queue
        text = try container.decodeIfPresent(Bool.self, forKey: .text) ?? defaults.text
    }
}

/// The player's resizable-panel layout. Clamps live at the drag sites;
/// these are the remembered sizes.
///
/// The right side is now ONE rail holding tags over segments, and
/// on-screen text is a drawer under the transport rather than a second
/// side panel — so the two right-hand widths that used to scale jointly
/// against the video floor became one width and one height. A file
/// written before that carries its tag-panel width forward into the
/// rail, which is the same edge in the same place.
public struct PlayerLayoutSettings: Codable, Equatable, Sendable {
    /// The right rail's width, points.
    public var railWidth: Double
    /// The on-screen-text drawer's height, points.
    public var textDrawerHeight: Double
    /// Play-queue strip height, points — also the thumbnail scale.
    public var queueHeight: Double
    public var panels: PlayerPanels

    public init(
        railWidth: Double = 352,
        textDrawerHeight: Double = 112,
        queueHeight: Double = 146,
        panels: PlayerPanels = PlayerPanels()
    ) {
        self.railWidth = railWidth
        self.textDrawerHeight = textDrawerHeight
        self.queueHeight = queueHeight
        self.panels = panels
    }

    private enum LegacyKeys: String, CodingKey {
        case tagPanelWidth, textPanelWidth, showsQueue
    }

    /// Per-key tolerant, like AppSettings itself — a stored layout from
    /// before a field existed must not throw the whole file back to
    /// defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try? decoder.container(keyedBy: LegacyKeys.self)
        let defaults = PlayerLayoutSettings()
        railWidth = try container.decodeIfPresent(Double.self, forKey: .railWidth)
            ?? (legacy.flatMap { (try? $0.decodeIfPresent(Double.self, forKey: .tagPanelWidth)) ?? nil })
            ?? defaults.railWidth
        textDrawerHeight = try container.decodeIfPresent(Double.self, forKey: .textDrawerHeight)
            ?? defaults.textDrawerHeight
        queueHeight = try container.decodeIfPresent(Double.self, forKey: .queueHeight)
            ?? defaults.queueHeight
        if let panels = try container.decodeIfPresent(PlayerPanels.self, forKey: .panels) {
            self.panels = panels
        } else {
            var panels = defaults.panels
            if let showsQueue = legacy.flatMap({
                (try? $0.decodeIfPresent(Bool.self, forKey: .showsQueue)) ?? nil
            }) {
                panels.queue = showsQueue
            }
            self.panels = panels
        }
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
