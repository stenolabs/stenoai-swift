import Foundation
import Testing
@testable import StenoiOSAudio

@Suite("Audio session ownership")
struct AudioSessionOwnershipTests {
    @Test("playback cannot claim a recording or metering session")
    func playbackCannotInterruptCapture() {
        var recording = AudioSessionOwnership()
        _ = recording.beginRecording(UUID())
        let playbackDuringRecording = recording.beginPlayback(UUID())
        #expect(!playbackDuringRecording)
        #expect(recording.isRecording)

        var metering = AudioSessionOwnership()
        let beganMetering = metering.beginMetering(UUID())
        let playbackDuringMetering = metering.beginPlayback(UUID())
        #expect(beganMetering)
        #expect(!playbackDuringMetering)
    }

    @Test("recording preempts playback and stale cleanup preserves capture")
    func recordingPreemptsPlayback() {
        var ownership = AudioSessionOwnership()
        let playback = UUID()
        let recording = UUID()
        let beganPlayback = ownership.beginPlayback(playback)
        #expect(beganPlayback)
        #expect(!ownership.allowsReadinessConfiguration)
        _ = ownership.beginRecording(recording)
        #expect(ownership.playbackID == nil)
        let staleCleanupMayDeactivate = ownership.endPlayback(playback)
        #expect(!staleCleanupMayDeactivate)
        #expect(ownership.ownsRecording(recording))
        #expect(!ownership.allowsReadinessConfiguration)
    }

    @Test("metering preempts playback without allowing stale deactivation")
    func meteringPreemptsPlayback() {
        var ownership = AudioSessionOwnership()
        let playback = UUID()
        let metering = UUID()
        let beganPlayback = ownership.beginPlayback(playback)
        let beganMetering = ownership.beginMetering(metering)
        let staleCleanupMayDeactivate = ownership.endPlayback(playback)
        #expect(beganPlayback)
        #expect(beganMetering)
        #expect(!staleCleanupMayDeactivate)
        #expect(ownership.ownsMetering(metering))
        _ = ownership.beginRecording(UUID())
        #expect(!ownership.ownsMetering(metering))
    }

    @Test("old playback cleanup cannot release a newer playback lease")
    func playbackCleanupIsLeaseSpecific() {
        var ownership = AudioSessionOwnership()
        let first = UUID()
        let second = UUID()
        let beganFirst = ownership.beginPlayback(first)
        let simultaneousSecond = ownership.beginPlayback(second)
        let releasedFirst = ownership.endPlayback(first)
        let beganSecond = ownership.beginPlayback(second)
        let staleCleanupMayDeactivate = ownership.endPlayback(first)
        #expect(beganFirst)
        #expect(!simultaneousSecond)
        #expect(releasedFirst)
        #expect(beganSecond)
        #expect(!staleCleanupMayDeactivate)
        #expect(ownership.playbackID == second)
        let releasedSecond = ownership.endPlayback(second)
        #expect(releasedSecond)
        #expect(ownership.allowsReadinessConfiguration)
    }

    @Test("recording takes the metering lease and blocks readiness configuration")
    func recordingTakesMeteringLease() {
        var ownership = AudioSessionOwnership()
        let meter = UUID()
        let recording = UUID()

        let beganMetering = ownership.beginMetering(meter)
        let displacedMetering = ownership.beginRecording(recording)

        #expect(beganMetering)
        #expect(displacedMetering == meter)
        #expect(!ownership.allowsReadinessConfiguration)
    }

    @Test("stale metering cleanup cannot deactivate a recording")
    func staleMeteringCleanupPreservesRecording() {
        var ownership = AudioSessionOwnership()
        let meter = UUID()
        let recording = UUID()
        let beganMetering = ownership.beginMetering(meter)
        _ = ownership.beginRecording(recording)
        let mayDeactivate = ownership.endMetering(meter)

        #expect(beganMetering)
        #expect(!mayDeactivate)
        #expect(ownership.isRecording)
    }

    @Test("ordinary metering cleanup may deactivate an otherwise idle session")
    func idleMeteringCleanupMayDeactivate() {
        var ownership = AudioSessionOwnership()
        let meter = UUID()
        let beganMetering = ownership.beginMetering(meter)
        let mayDeactivate = ownership.endMetering(meter)

        #expect(beganMetering)
        #expect(mayDeactivate)
        #expect(ownership.allowsReadinessConfiguration)
    }
}
