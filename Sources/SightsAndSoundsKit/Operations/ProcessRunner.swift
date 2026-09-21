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
    static func run(
        _ tool: String, _ arguments: [String], captureStdout: Bool = true,
        canceller: Canceller? = nil
    ) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice

        let errPipe = Pipe()
        process.standardError = errPipe
        let outPipe = captureStdout ? Pipe() : nil
        process.standardOutput = outPipe ?? FileHandle.nullDevice

        // Exit is signalled by the termination handler rather than
        // `waitUntilExit`, which spins the calling thread's run loop, and
        // each stream is drained on a thread of its own rather than on a
        // dispatch queue. Callers are often themselves blocked on a pool
        // thread; on a machine with few cores the shared pools can have
        // nothing left to run a queued reader on, and then the reader,
        // the tool and the caller all wait for each other.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        try process.run()
        canceller?.attach(process)

        let collected = OSAllocatedUnfairLock(initialState: (out: Data(), err: Data()))
        let drained = DispatchSemaphore(value: 0)
        var readers = 0
        if let outPipe {
            let handle = outPipe.fileHandleForReading
            readers += 1
            Thread.detachNewThread {
                let data = handle.readDataToEndOfFile()
                collected.withLock { $0.out = data }
                drained.signal()
            }
        }
        let errHandle = errPipe.fileHandleForReading
        readers += 1
        Thread.detachNewThread {
            let data = errHandle.readDataToEndOfFile()
            collected.withLock { $0.err = data }
            drained.signal()
        }

        exited.wait()
        for _ in 0..<readers { drained.wait() }
        let (out, err) = collected.withLock { ($0.out, $0.err) }
        return Output(status: process.terminationStatus, stdout: out, stderr: err)
    }

    /// The way to stop a tool that is already running. `Process` is not
    /// Sendable, so the one reference lives behind a lock and only
    /// `terminate()` — which is safe from any thread — is ever called on
    /// it from outside.
    final class Canceller: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false

        var wasCancelled: Bool { lock.withLock { cancelled } }

        fileprivate func attach(_ process: Process) {
            let alreadyCancelled = lock.withLock { () -> Bool in
                self.process = process
                return cancelled
            }
            if alreadyCancelled { process.terminate() }
        }

        func cancel() {
            let running = lock.withLock { () -> Process? in
                cancelled = true
                return process
            }
            running?.terminate()
        }
    }

    /// Run `tool`, asking `isCancelled` four times a second and
    /// terminating the tool when it says yes; that throws
    /// `CancellationError`. The blocking wait happens on a thread of its
    /// own, so an hour-long encode does not hold one of the few threads
    /// every other task in the app shares.
    static func run(
        _ tool: String, _ arguments: [String], captureStdout: Bool = true,
        isCancelled: @escaping @Sendable () async -> Bool
    ) async throws -> Output {
        let canceller = Canceller()
        let watcher = Task {
            while !Task.isCancelled {
                if await isCancelled() {
                    canceller.cancel()
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { watcher.cancel() }

        let output: Output = try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(with: Result {
                    try run(tool, arguments, captureStdout: captureStdout, canceller: canceller)
                })
            }
        }
        if canceller.wasCancelled { throw CancellationError() }
        return output
    }
}
