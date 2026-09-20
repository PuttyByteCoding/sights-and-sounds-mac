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
}
