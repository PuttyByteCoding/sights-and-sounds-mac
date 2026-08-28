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

/// The browse grid's display configuration. Defaults reproduce the
/// pre-configurable grid exactly: filename, duration, file size,
/// favorite star, needs-review glyph, 200 pt cells.
public struct GridSettings: Codable, Equatable, Sendable {
    /// Adaptive column minimum, in points (the maximum tracks at 1.4x).
    public var thumbnailSize: Double
    public var showsFileName: Bool
    public var showsPath: Bool
    public var showsTags: Bool
    public var showsMissingCategories: Bool
    public var showsImportDate: Bool
    public var showsViewCount: Bool
    public var showsDeleted: Bool
    public var showsDuplicate: Bool
    public var showsClip: Bool
    public var showsDuration: Bool
    public var showsFileSize: Bool
    public var showsFavorite: Bool
    public var showsDimensions: Bool
    public var showsReviewed: Bool

    public init(
        thumbnailSize: Double = 200,
        showsFileName: Bool = true,
        showsPath: Bool = false,
        showsTags: Bool = false,
        showsMissingCategories: Bool = false,
        showsImportDate: Bool = false,
        showsViewCount: Bool = false,
        showsDeleted: Bool = false,
        showsDuplicate: Bool = false,
        showsClip: Bool = false,
        showsDuration: Bool = true,
        showsFileSize: Bool = true,
        showsFavorite: Bool = true,
        showsDimensions: Bool = false,
        showsReviewed: Bool = true
    ) {
        self.thumbnailSize = thumbnailSize
        self.showsFileName = showsFileName
        self.showsPath = showsPath
        self.showsTags = showsTags
        self.showsMissingCategories = showsMissingCategories
        self.showsImportDate = showsImportDate
        self.showsViewCount = showsViewCount
        self.showsDeleted = showsDeleted
        self.showsDuplicate = showsDuplicate
        self.showsClip = showsClip
        self.showsDuration = showsDuration
        self.showsFileSize = showsFileSize
        self.showsFavorite = showsFavorite
        self.showsDimensions = showsDimensions
        self.showsReviewed = showsReviewed
    }

    /// True when a field needing the per-item tag join is enabled — the
    /// grid's batch queries run only then.
    public var needsTagData: Bool { showsTags || showsMissingCategories }
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
