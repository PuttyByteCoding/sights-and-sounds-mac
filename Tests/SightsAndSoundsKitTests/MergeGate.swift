import Foundation
import Testing

/// What a merge waits for, and what it does not.
///
/// Every test runs on a developer's Mac: `swift test`. CI runs with
/// `SAS_MERGE_GATE` set and leaves out the tests marked below, so that a
/// pull request is held up by the tests that are quick and sure on the CI
/// machine and not by the ones that are neither there.
///
/// To run what CI runs:  `SAS_MERGE_GATE=1 swift test`
enum MergeGate {
    static let isOn = ProcessInfo.processInfo.environment["SAS_MERGE_GATE"] != nil
}

extension Trait where Self == ConditionTrait {
    /// The test writes a real video (`DemoMediaFactory.writeVideo`, or a
    /// demo or sample library that does).
    ///
    /// Videos are encoded one at a time, and the CI machine has no
    /// hardware encoder: it does each in software, over a second apiece.
    /// With a hundred tests waiting their turn the whole run stretched to
    /// the length of that queue, and a test with a time limit failed for
    /// having stood in it. On a Mac the same tests take a moment.
    static var writesVideo: Self {
        .enabled(
            if: !MergeGate.isOn,
            "left out of the merge gate: it writes a real video; run `swift test` without SAS_MERGE_GATE")
    }
}
