import Foundation
import os

/// Runs an external tool and collects what it printed.
///
/// A pipe holds about 64 KB. A child that writes more than that blocks
/// until someone reads, so "wait for exit, then read" deadlocks the
/// moment a tool is talkative: the child waits on the pipe, the app
/// waits on the child, and the job lane behind them never moves again.
/// Both streams are therefore drained on their own threads *while* the
/// tool runs, and a stream nobody wants goes to the null device instead
/// of into a pipe nobody reads.
enum ProcessRunner {
    struct Output: Sendable {
        let status: Int32
        let stdout: Data
        let stderr: Data

        var stdoutText: String { String(data: stdout, encoding: .utf8) ?? "" }
        var stderrText: String { String(data: stderr, encoding: .utf8) ?? "" }
    }

    /// Run `tool` to completion. Throws only when it cannot be launched;
    /// a non-zero exit is the caller's to interpret.
    static func run(_ tool: String, _ arguments: [String], captureStdout: Bool = true) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice

        let errPipe = Pipe()
        process.standardError = errPipe
        let outPipe = captureStdout ? Pipe() : nil
        process.standardOutput = outPipe ?? FileHandle.nullDevice

        try process.run()

        let collected = OSAllocatedUnfairLock(initialState: (out: Data(), err: Data()))
        let readers = DispatchGroup()
        if let outPipe {
            let handle = outPipe.fileHandleForReading
            DispatchQueue.global().async(group: readers) {
                let data = handle.readDataToEndOfFile()
                collected.withLock { $0.out = data }
            }
        }
        let errHandle = errPipe.fileHandleForReading
        DispatchQueue.global().async(group: readers) {
            let data = errHandle.readDataToEndOfFile()
            collected.withLock { $0.err = data }
        }

        process.waitUntilExit()
        readers.wait()
        let (out, err) = collected.withLock { ($0.out, $0.err) }
        return Output(status: process.terminationStatus, stdout: out, stderr: err)
    }
}
