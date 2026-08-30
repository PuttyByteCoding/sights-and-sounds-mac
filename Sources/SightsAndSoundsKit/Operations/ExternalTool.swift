import Foundation
import GRDB

/// One external binary a repair recipe can call.
///
/// Declared once, separately, and referenced by name — so a recipe whose
/// tool is missing is flagged *in place* ("untrunc not found" on the
/// card) rather than silently never matching, and so the same binary is
/// not re-discovered by three recipes with three different paths.
public struct ExternalTool: Codable, Equatable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "externalTool"

    /// The name recipes use — `ffmpeg`, `untrunc`.
    public var name: String
    /// Where it was found or pointed at. Nil means it is not installed
    /// here, which is a fact worth storing rather than re-deriving.
    public var path: String?
    public var version: String?
    public var lastVerifiedAt: Date?

    public var id: String { name }
    public var isAvailable: Bool { path != nil }

    public init(
        name: String, path: String? = nil, version: String? = nil, lastVerifiedAt: Date? = nil
    ) {
        self.name = name
        self.path = path
        self.version = version
        self.lastVerifiedAt = lastVerifiedAt
    }
}

extension AppDatabase {
    public func externalTools() throws -> [ExternalTool] {
        try writer.read { db in try ExternalTool.order(sql: "name").fetchAll(db) }
    }

    public func saveExternalTool(_ tool: ExternalTool) throws {
        try writer.write { try tool.upsert($0) }
    }

    /// Find a tool on PATH and record what it is. Run at launch and from
    /// the Repair pane's Test button; a tool that has moved is caught
    /// here rather than by a job failing halfway through.
    @discardableResult
    public func detectTool(named name: String) throws -> ExternalTool {
        var tool = try externalTools().first { $0.name == name } ?? ExternalTool(name: name)
        tool.path = TagWriters.toolPath(name)
        tool.version = tool.path.flatMap { ExternalTool.detectedVersion(ofToolAt: $0) }
        tool.lastVerifiedAt = Date()
        try saveExternalTool(tool)
        return tool
    }

    /// The tools every shipped recipe needs, detected once.
    public func detectShippedTools() throws {
        for name in Set(RepairRecipe.shipped.map(\.tool) + ["ffmpeg", "ffprobe"]) {
            _ = try? detectTool(named: name)
        }
    }
}

extension ExternalTool {
    /// The first line of `<tool> -version`, which is what every one of
    /// these prints and what a person would check by hand.
    public static func detectedVersion(ofToolAt path: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-version"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)?
            .split(separator: "\n").first
            .map(String.init)
    }
}
