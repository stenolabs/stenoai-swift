import Foundation
import StenoAudioCore
import Testing
@testable import steno_macos

@Suite("Partial recording message")
struct PartialRecordingMessageTests {
    @Test("names the missing track and says recording continues")
    func namesTheMissingTrack() {
        let message = AppModel.partialRecordingMessage(
            [
                .microphone: .audioSourceUnavailable(
                    "the microphone selected before audio setup is not stable"
                ),
            ])

        #expect(message.contains("microphone"))
        #expect(message.contains("not stable"))
        #expect(message.lowercased().contains("recorded"))
        // The user must not be told the system track failed when it did not.
        #expect(!message.contains("system audio"))
    }

    @Test("names both tracks when both are missing")
    func namesBothTracks() {
        let message = AppModel.partialRecordingMessage(
            [
                .microphone: .audioSourceUnavailable("mic gone"),
                .system: .audioSourceUnavailable("tap gone"),
            ])

        #expect(message.contains("microphone"))
        #expect(message.contains("system audio"))
    }

    @Test("names the track that joined late")
    func namesTheReboundTrack() {
        let message = AppModel.trackReboundMessage(.microphone)

        #expect(message.contains("microphone"))
        #expect(message.lowercased().contains("recording"))
    }

    @Test("a rebound track is announced only for what actually came back")
    func announcesOnlyWhatCameBack() {
        #expect(
            AppModel.trackReboundMessage(.system).contains("system audio")
        )
        #expect(
            !AppModel.trackReboundMessage(.system).contains("microphone")
        )
    }
}
