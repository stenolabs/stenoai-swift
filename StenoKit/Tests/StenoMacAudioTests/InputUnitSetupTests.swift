import AVFAudio
import CoreAudio
import Testing
@testable import StenoMacAudio

/// The order in which a HAL input unit is brought up is the whole fix.
///
/// `AVAudioEngine` reached its input node before the device was chosen, which
/// opened the system default input first. On a Bluetooth microphone another app
/// was holding, that single step took 3012 ms of a 5000 ms budget. Setting the
/// device before initializing never touches the default device: measured 34 ms
/// against the same busy AirPods.
@Suite("Input unit setup")
struct InputUnitSetupTests {
    @Test("the device is chosen before the unit is initialized")
    func deviceIsChosenBeforeInitialize() {
        let steps = HALInputUnit.setupSteps(deviceID: 110)

        let deviceIndex = try? #require(
            steps.firstIndex(of: .setDevice(110))
        )
        let initializeIndex = try? #require(
            steps.firstIndex(of: .initialize)
        )
        #expect(deviceIndex != nil)
        #expect(initializeIndex != nil)
        if let deviceIndex, let initializeIndex {
            #expect(deviceIndex < initializeIndex)
        }
    }

    @Test("the format is only read once the device is set")
    func formatComesAfterTheDevice() {
        let steps = HALInputUnit.setupSteps(deviceID: 110)

        guard let deviceIndex = steps.firstIndex(of: .setDevice(110)),
              let formatIndex = steps.firstIndex(of: .readHardwareFormat) else {
            Issue.record("expected both steps to be present")
            return
        }
        // Reading the format is what blocked for three seconds when it hit the
        // default device, so it must come after the device is pinned.
        #expect(deviceIndex < formatIndex)
    }

    @Test("input is enabled and output disabled before anything else")
    func ioIsConfiguredFirst() {
        let steps = HALInputUnit.setupSteps(deviceID: 110)

        #expect(steps.first == .enableInputDisableOutput)
        #expect(steps.last == .start)
    }
}
