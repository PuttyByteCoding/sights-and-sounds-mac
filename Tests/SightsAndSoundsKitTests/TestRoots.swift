import Foundation

/// Where a test's source "lives" when the test is about rows, not files.
///
/// Fixtures used to name fixed places — `/Volumes/Media/Concerts`,
/// `/tmp/dupes` — and several tests then ran live file operations
/// (staging, reverting, purging) against them. They passed because
/// nothing exists there, which is a property of the machine, not of the
/// test: on a Mac that does have such a folder, a test would move real
/// files. A root under the temp directory with a fresh UUID in it cannot
/// exist, on any machine, and is never created.
enum TestRoots {
    static func unreachable(_ name: String) -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-tests-unreachable-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true).path
    }
}
