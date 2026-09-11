import Foundation
import StenoAudioCore
import StenoMacAudio
import Testing
@testable import steno_macos

/// A partial recording start must never teach the app a permission the system
/// never granted.
@Suite("System audio permission after a partial start")
struct SystemAudioPermissionAfterPartialStartTests {
    @Test("a bound system track confirms the permission")
    func boundTrackConfirmsPermission() {
        let status = AppModel.systemAudioPermission(
            afterStartFailures: [:],
            current: .notDetermined
        )

        #expect(status == .authorized)
    }

    @Test("a denied system track is remembered as denied, not authorized")
    func deniedTrackIsNotStoredAsAuthorized() {
        let status = AppModel.systemAudioPermission(
            afterStartFailures: [.system: .systemAudioPermissionDenied],
            current: .authorized
        )

        #expect(status == .denied)
    }

    @Test("a system track failing for another reason teaches nothing")
    func unrelatedFailureLeavesThePermissionAlone() {
        let status = AppModel.systemAudioPermission(
            afterStartFailures: [
                .system: .audioSourceUnavailable("the tap could not be created"),
            ],
            current: .authorized
        )

        #expect(status == .authorized)
    }

    @Test("a failed microphone says nothing about system audio")
    func microphoneFailureDoesNotAffectSystemAudio() {
        let status = AppModel.systemAudioPermission(
            afterStartFailures: [
                .microphone: .audioSourceUnavailable("not stable"),
            ],
            current: .notDetermined
        )

        #expect(status == .authorized)
    }
}
