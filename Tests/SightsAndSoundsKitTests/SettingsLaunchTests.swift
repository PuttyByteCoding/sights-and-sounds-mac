import Foundation
import Testing

@testable import SightsAndSoundsKit

/// The app's settings store is created once per process, on first use.
/// A file that did not decode used to crash that first use: the load
/// logged the problem, and the log read the store still being created.
/// Only a fresh process shows it, so each case runs this test binary
/// again as a child and checks that the child survives.
@Suite struct SettingsLaunchTests {
    static let childKey = "SAS_SETTINGS_LAUNCH_CHILD"

    @Test(arguments: [
        "{}",                                          // control: a good file
        "{ not json",                                  // the whole file is unreadable
        "{ \"logDirectory\": 42 }",                    // one value is unreadable
    ])
    func aBadSettingsFileDoesNotStopTheAppStarting(_ contents: String) async throws {
        let arguments = ProcessInfo.processInfo.arguments
        guard let bundleFlag = arguments.firstIndex(of: "--test-bundle-path"),
              arguments.indices.contains(bundleFlag + 1)
        else {
            // Not under swiftpm's testing helper (Xcode, or a toolchain that
            // runs swift-testing inside xctest): nothing to relaunch. Said as
            // a known issue, so a run that never tested this shows it rather
            // than passing silently.
            withKnownIssue("not relaunchable under this test runner; the launch check did not run") {
                Issue.record("no --test-bundle-path in \(arguments.first ?? "?")")
            }
            return
        }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: arguments[0])
        child.arguments = [
            "--test-bundle-path", arguments[bundleFlag + 1],
            "--filter", "SettingsLaunchChild",
            "--testing-library", "swift-testing",
            arguments[bundleFlag + 1],
        ]
        var environment = ProcessInfo.processInfo.environment
        environment[Self.childKey] = contents
        child.environment = environment
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        // A child that hangs rather than crashes must not hang the run.
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(120))
            if !Task.isCancelled, child.isRunning { child.terminate() }
        }
        defer { watchdog.cancel() }
        // Waited for by handler, not `waitUntilExit`: never block a
        // shared pool thread on another process. A child that cannot start
        // is a failure of this test, not of the whole run: reading a
        // never-launched process's status raises and takes the run down.
        var launchError: (any Error)?
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            child.terminationHandler = { _ in done.resume() }
            do { try child.run() } catch {
                launchError = error
                done.resume()
            }
        }
        if let launchError {
            Issue.record("the child could not be started: \(launchError)")
            return
        }

        #expect(child.terminationReason == .exit, "the child crashed (signal \(child.terminationStatus))")
        #expect(child.terminationStatus == 0)
    }
}

/// Runs only as the child above: writes the bad file where this process's
/// store will look, then makes the first use of the store.
@Suite struct SettingsLaunchChild {
    @Test(.enabled(if: ProcessInfo.processInfo.environment[SettingsLaunchTests.childKey] != nil))
    func firstUseOfTheStoreWithABadFile() throws {
        let contents = try #require(ProcessInfo.processInfo.environment[SettingsLaunchTests.childKey])
        let file = AppSettingsStore.testScratch.appendingPathComponent("settings.json")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: file)

        #expect(AppSettingsStore.shared.current.logDirectory == nil)
    }
}
