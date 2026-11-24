import Testing

@testable import SightsAndSoundsKit

/// What the encode presets write is what makes a file quick to start and
/// quick to seek over a network share.
@Suite struct EncodePresetTests {
    @Test func everyPresetWritesTheIndexFirstAndAKeyframeEveryTwoSeconds() {
        for preset in EncodeJob.Preset.allCases {
            let arguments = preset.ffmpegArguments
            #expect(arguments.contains("+faststart"), "\(preset)")
            let forced = arguments.firstIndex(of: "-force_key_frames")
            #expect(forced.map { arguments[$0 + 1] } == "expr:gte(t,n_forced*2)", "\(preset)")
        }
        #expect(EncodeJob.Preset.hevc.ffmpegArguments.contains("hvc1"), "AVFoundation plays hvc1, not hev1")
    }
}
