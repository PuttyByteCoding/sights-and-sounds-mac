import Foundation
import Testing

/// What a merge waits for, and what it does not. See the same file in the
/// other test targets: every test runs on a developer's Mac
/// (`swift test`), and CI, with `SAS_MERGE_GATE` set, leaves out the
/// tests marked here.
enum MergeGate {
    static let isOn = ProcessInfo.processInfo.environment["SAS_MERGE_GATE"] != nil
}

extension Trait where Self == ConditionTrait {
    /// The test writes a real video with the system encoder, which CI's
    /// machine does slowly and one at a time.
    static var writesVideo: Self {
        .enabled(
            if: !MergeGate.isOn,
            "left out of the merge gate: it writes a real video; run `swift test` without SAS_MERGE_GATE")
    }

    /// The test builds a library of tens of thousands of items to time
    /// something. It is a measurement to read, more than a check to pass,
    /// and on CI's machine it would mostly measure that machine.
    static var measuresALargeLibrary: Self {
        .enabled(
            if: !MergeGate.isOn,
            "left out of the merge gate: it times a very large library; run `swift test` without SAS_MERGE_GATE")
    }
}
