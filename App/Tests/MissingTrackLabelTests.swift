import Foundation
import StenoDomain
import Testing
@testable import steno_macos

/// A recording that is missing a side of the conversation must look different
/// from a complete one wherever it is shown.
@Suite("Missing track label")
struct MissingTrackLabelTests {
    @Test("a complete recording gets no label")
    func completeRecordingHasNoLabel() {
        #expect(MeetingCompleteness.missingTracksWord([]) == nil)
    }

    @Test("a missing microphone names the microphone")
    func missingMicrophoneIsNamed() {
        let word = MeetingCompleteness.missingTracksWord([.micTrack])

        #expect(word?.contains("Microphone") == true)
        #expect(word?.contains("system") != true)
    }

    @Test("a missing system track names system audio")
    func missingSystemTrackIsNamed() {
        let word = MeetingCompleteness.missingTracksWord([.systemTrack])

        #expect(word?.lowercased().contains("system audio") == true)
    }

    @Test("both missing are named together rather than dropped")
    func bothMissingAreNamed() {
        let word = MeetingCompleteness.missingTracksWord([.micTrack, .systemTrack])

        #expect(word?.contains("Microphone") == true)
        #expect(word?.lowercased().contains("system audio") == true)
    }

    @Test("minutes from an incomplete recording carry a caveat")
    func minutesCarryACaveat() {
        let caveat = MeetingCompleteness.reportCaveat([.micTrack])

        #expect(caveat != nil)
        // It has to say what is missing AND what that means for the minutes.
        #expect(caveat?.contains("Microphone") == true)
        #expect(caveat?.lowercased().contains("minutes") == true)
    }

    @Test("a complete recording gets no caveat")
    func completeRecordingHasNoCaveat() {
        #expect(MeetingCompleteness.reportCaveat([]) == nil)
    }

    @Test("copied minutes carry the warning, complete ones stay untouched")
    func copiedMinutesCarryTheWarning() {
        let markdown = "## Decisions\n- ship it"

        let incomplete = MeetingCompleteness.minutesForCopying(
            markdown,
            unrecordedTracks: [.micTrack]
        )
        let complete = MeetingCompleteness.minutesForCopying(
            markdown,
            unrecordedTracks: []
        )

        #expect(incomplete.contains("Incomplete recording"))
        #expect(incomplete.contains("ship it"))
        #expect(complete == markdown)
    }

}
