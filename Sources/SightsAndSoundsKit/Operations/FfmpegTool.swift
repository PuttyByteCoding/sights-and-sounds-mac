import Foundation

/// The ffmpeg boundary: locate the system binary (decision 04 — direct
/// distribution, system tools allowed), run it, surface stderr on
/// failure. Jobs that need it and don't find it succeed with install
/// guidance — the fpcalc pattern, not red dashboard noise.
public enum FfmpegTool {
    public static let installHint = "ffmpeg not found — brew install ffmpeg to enable"

    public static func path() -> String? {
        let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        let env = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let pathCandidates = env.split(separator: ":").map { String($0) + "/ffmpeg" }
        return (pathCandidates + candidates).first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public struct FfmpegError: Error, CustomStringConvertible {
        public let exitCode: Int32
        public let stderrTail: String
        public var description: String { "ffmpeg exited \(exitCode): \(stderrTail)" }
    }

    /// Run ffmpeg with the given arguments (`-y -hide_banner` prepended).
    public static func run(_ arguments: [String], tool: String) throws {
        // ffmpeg's stdout is never wanted here; its stderr is the error.
        let output = try ProcessRunner.run(
            tool, ["-y", "-hide_banner", "-loglevel", "error"] + arguments, captureStdout: false)
        guard output.status == 0 else {
            throw FfmpegError(exitCode: output.status, stderrTail: String(output.stderrText.suffix(400)))
        }
    }

    /// Run ffmpeg from a job: the same call, but cancellable. Throws
    /// `CancellationError` when the job was cancelled mid-run.
    public static func run(
        _ arguments: [String], tool: String,
        isCancelled: @escaping @Sendable () async -> Bool
    ) async throws {
        let output = try await ProcessRunner.run(
            tool, ["-y", "-hide_banner", "-loglevel", "error"] + arguments,
            captureStdout: false, isCancelled: isCancelled)
        guard output.status == 0 else {
            throw FfmpegError(exitCode: output.status, stderrTail: String(output.stderrText.suffix(400)))
        }
    }

    /// Have ffmpeg make a new file at `output` — whole, or not at all.
    ///
    /// ffmpeg writes as it goes, so a run that fails, is cancelled, or
    /// dies with the app leaves however much it had written. Written
    /// straight to its place in the library, that half file is what the
    /// next scan imports. So ffmpeg writes to a working file outside
    /// anything the library lists, on the same volume, and only a finished
    /// file is moved into place. `arguments` are everything except the
    /// output path, which goes last.
    public static func produce(
        _ output: URL, arguments: [String], tool: String,
        fileAccess: any FileAccess,
        isCancelled: @escaping @Sendable () async -> Bool
    ) async throws {
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let working = try LibraryDatabase.workingURL(
            toReplace: output.deletingLastPathComponent(),
            fileExtension: output.pathExtension.isEmpty ? "mp4" : output.pathExtension)
        defer { try? FileManager.default.removeItem(at: working.deletingLastPathComponent()) }
        try await run(arguments + [working.path], tool: tool, isCancelled: isCancelled)
        try fileAccess.moveFile(at: working, to: output)
    }
}
