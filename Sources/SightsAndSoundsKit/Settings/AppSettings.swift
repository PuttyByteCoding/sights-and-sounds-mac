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
        ocrSampleIntervalSeconds = try container.decodeIfPresent(
            Double.self, forKey: .ocrSampleIntervalSeconds) ?? defaults.ocrSampleIntervalSeconds
        ocrBudgetSecondsPerRun = try container.decodeIfPresent(
            Double.self, forKey: .ocrBudgetSecondsPerRun) ?? defaults.ocrBudgetSecondsPerRun
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
