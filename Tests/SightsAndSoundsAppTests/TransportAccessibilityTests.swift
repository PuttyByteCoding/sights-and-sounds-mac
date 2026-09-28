import Testing

@testable import SightsAndSoundsApp

/// VoiceOver hears the transport's controls. Its buttons are icons with
/// only a tooltip, and the scrubber was a drawing with no element at
/// all. The spoken words come from these: a tooltip without its key
/// hint, and the playhead as "where of how long".
@Suite struct TransportAccessibilityTests {
    @Test func aButtonsSpokenLabelDropsTheKeyHint() {
        #expect(TransportAccessibility.label(fromHelp: "Unmute (M)") == "Unmute")
        #expect(TransportAccessibility.label(fromHelp: "Looping — click to play once (L)") == "Looping — click to play once")
        #expect(TransportAccessibility.label(fromHelp: "Playback speed") == "Playback speed")
    }

    @Test func theScrubbersValueIsWhereOfHowLong() {
        #expect(TransportAccessibility.position(current: 83, duration: 296) == "1:23 of 4:56")
        #expect(TransportAccessibility.position(current: 0, duration: 0) == "0:00")
    }
}
