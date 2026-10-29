@preconcurrency import AVFAudio
import Foundation
import StenoAudioCore
import Testing
@testable import StenoiOSAudio

@Suite("Audio session events")
struct AudioSessionEventTests {

    @Test("The event stream observes notifications before it is returned")
    func eventStreamIsRegisteredSynchronously() async {
        let center = NotificationCenter()
        let controller = AudioSessionController(notificationCenter: center)
        let stream = await controller.events()

        center.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [
                AVAudioSessionInterruptionTypeKey:
                    AVAudioSession.InterruptionType.began.rawValue
            ]
        )

        #expect(await firstEvent(from: stream) == .interruptionBegan(.other))
    }

    // MARK: - Interruption decoding

    @Test("A begun interruption without a reason still decodes")
    func interruptionBeganWithoutReason() {
        let notification = Notification(
            name: AVAudioSession.interruptionNotification,
            userInfo: [
                AVAudioSessionInterruptionTypeKey:
                    AVAudioSession.InterruptionType.began.rawValue
            ]
        )

        #expect(
            AudioSessionController.interruptionEvent(from: notification)
                == .interruptionBegan(.other)
        )
    }

    @Test("A muted built-in microphone is reported as its own reason")
    func interruptionBeganMutedMic() {
        let notification = Notification(
            name: AVAudioSession.interruptionNotification,
            userInfo: [
                AVAudioSessionInterruptionTypeKey:
                    AVAudioSession.InterruptionType.began.rawValue,
                AVAudioSessionInterruptionReasonKey:
                    AVAudioSession.InterruptionReason.builtInMicMuted.rawValue,
            ]
        )

        #expect(
            AudioSessionController.interruptionEvent(from: notification)
                == .interruptionBegan(.builtInMicMuted)
        )
    }

    @Test("An ended interruption carries the resume hint")
    func interruptionEndedWithResume() {
        let notification = Notification(
            name: AVAudioSession.interruptionNotification,
            userInfo: [
                AVAudioSessionInterruptionTypeKey:
                    AVAudioSession.InterruptionType.ended.rawValue,
                AVAudioSessionInterruptionOptionKey:
                    AVAudioSession.InterruptionOptions.shouldResume.rawValue,
            ]
        )

        #expect(
            AudioSessionController.interruptionEvent(from: notification)
                == .interruptionEnded(shouldResume: true)
        )
    }

    @Test("An ended interruption without options must not claim resumability")
    func interruptionEndedWithoutOptions() {
        let notification = Notification(
            name: AVAudioSession.interruptionNotification,
            userInfo: [
                AVAudioSessionInterruptionTypeKey:
                    AVAudioSession.InterruptionType.ended.rawValue
            ]
        )

        #expect(
            AudioSessionController.interruptionEvent(from: notification)
                == .interruptionEnded(shouldResume: false)
        )
    }

    @Test("A notification without a type is ignored rather than guessed")
    func interruptionWithoutTypeIsIgnored() {
        let notification = Notification(
            name: AVAudioSession.interruptionNotification,
            userInfo: [:]
        )

        #expect(AudioSessionController.interruptionEvent(from: notification) == nil)
    }

    // MARK: - Route change decoding

    @Test("The recording category change notification lets capture continue")
    func categoryChangeNotificationContinuesCapture() async throws {
        let center = NotificationCenter()
        let controller = AudioSessionController(notificationCenter: center)
        let stream = await controller.events()

        center.post(
            name: AVAudioSession.routeChangeNotification,
            object: nil,
            userInfo: [
                AVAudioSessionRouteChangeReasonKey:
                    AVAudioSession.RouteChangeReason.categoryChange.rawValue
            ]
        )

        let event = try #require(await firstEvent(from: stream))
        #expect(event == .routeChanged(.categoryChange))
        guard case .routeChanged(let reason) = event else { return }
        #expect(!reason.endsCurrentCapture)
    }

    @Test("A route change reports the system reason")
    func routeChangeReason() {
        let notification = Notification(
            name: AVAudioSession.routeChangeNotification,
            userInfo: [
                AVAudioSessionRouteChangeReasonKey:
                    AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
            ]
        )

        #expect(
            AudioSessionController.routeChangeReason(from: notification)
                == .oldDeviceUnavailable
        )
    }

    @Test("A route change without a reason falls back to unknown")
    func routeChangeWithoutReason() {
        let notification = Notification(
            name: AVAudioSession.routeChangeNotification,
            userInfo: [:]
        )

        #expect(
            AudioSessionController.routeChangeReason(from: notification) == .unknown
        )
    }

    // MARK: - Capture consequences

    @Test(
        "Losing the input device ends the capture",
        arguments: [
            AudioRouteChangeReason.oldDeviceUnavailable,
            .noSuitableRouteForCategory,
        ]
    )
    func reasonsThatEndCapture(reason: AudioRouteChangeReason) {
        #expect(reason.endsCurrentCapture)
    }

    @Test(
        "Additive or cosmetic route changes let the capture continue",
        arguments: [
            AudioRouteChangeReason.newDeviceAvailable,
            // beginRecording's own setCategory posts this one.
            .categoryChange,
            .override,
            .wakeFromSleep,
            .routeConfigurationChange,
            .unknown,
        ]
    )
    func reasonsThatContinueCapture(reason: AudioRouteChangeReason) {
        #expect(!reason.endsCurrentCapture)
    }

    // MARK: - Permission mapping

    @Test("Permission states map one to one")
    func permissionMapping() {
        #expect(RecordPermission.status(from: .undetermined) == .notDetermined)
        #expect(RecordPermission.status(from: .denied) == .denied)
        #expect(RecordPermission.status(from: .granted) == .authorized)
    }
}

@Suite("Microphone capture recovery")
struct MicrophoneCaptureRecoveryTests {
    @Test("A second start reads the current hardware format")
    func secondStartReadsCurrentFormat() async throws {
        let backend = MicrophoneCaptureBackendStub(
            formats: [
                try audioFormat(sampleRate: 48_000),
                try audioFormat(sampleRate: 44_100),
            ]
        )
        let capture = MicrophoneCapture(backend: backend)

        try await capture.start { _ in }
        await capture.stop()
        try await capture.start { _ in }

        #expect(backend.inputSampleRates == [48_000, 44_100])
    }

    @Test("A configuration change reports the gap around a successful restart")
    func configurationChangeRestartsCapture() async throws {
        let backend = MicrophoneCaptureBackendStub(
            formats: [
                try audioFormat(sampleRate: 48_000),
                try audioFormat(sampleRate: 48_000),
            ]
        )
        let events = AudioSourceEventLog()
        let capture = MicrophoneCapture(backend: backend)
        try await capture.start(
            bufferHandler: { _ in },
            eventHandler: { events.append($0) }
        )

        let result = await capture.handleConfigurationChange()

        #expect(result == .restarted)
        #expect(await capture.running)
        #expect(backend.startCount == 2)
        #expect(
            events.values == [
                .unavailable(deviceName: nil),
                .available(deviceName: nil),
            ]
        )
    }

    @Test("An AudioSource existential forwards configuration change events")
    func audioSourceExistentialForwardsConfigurationEvents() async throws {
        let backend = MicrophoneCaptureBackendStub(
            formats: [
                try audioFormat(sampleRate: 48_000),
                try audioFormat(sampleRate: 48_000),
            ]
        )
        let events = AudioSourceEventLog()
        let capture = MicrophoneCapture(backend: backend)
        let source: any AudioSource = capture
        try await source.start(
            bufferHandler: { _ in },
            eventHandler: { events.append($0) }
        )

        let result = await capture.handleConfigurationChange()

        #expect(result == .restarted)
        #expect(
            events.values == [
                .unavailable(deviceName: nil),
                .available(deviceName: nil),
            ]
        )
        await source.stop()
    }

    @Test("A failed configuration restart leaves capture unavailable")
    func failedConfigurationRestartStopsCapture() async throws {
        let backend = MicrophoneCaptureBackendStub(
            formats: [
                try audioFormat(sampleRate: 48_000),
                try audioFormat(sampleRate: 48_000),
            ],
            failingStartAttempt: 2
        )
        let events = AudioSourceEventLog()
        let capture = MicrophoneCapture(backend: backend)
        try await capture.start(
            bufferHandler: { _ in },
            eventHandler: { events.append($0) }
        )

        let result = await capture.handleConfigurationChange()

        #expect(result == .failed)
        #expect(!(await capture.running))
        #expect(events.values == [.unavailable(deviceName: nil)])
    }

    @Test("A changed hardware format stops instead of corrupting the track")
    func changedFormatStopsCapture() async throws {
        let backend = MicrophoneCaptureBackendStub(
            formats: [
                try audioFormat(sampleRate: 48_000),
                try audioFormat(sampleRate: 44_100),
            ]
        )
        let events = AudioSourceEventLog()
        let capture = MicrophoneCapture(backend: backend)
        try await capture.start(
            bufferHandler: { _ in },
            eventHandler: { events.append($0) }
        )

        let result = await capture.handleConfigurationChange()

        #expect(result == .failed)
        #expect(!(await capture.running))
        #expect(backend.inputSampleRates == [48_000, 44_100])
        #expect(events.values == [.unavailable(deviceName: nil)])
    }
}

private enum MicrophoneCaptureBackendStubError: Error {
    case startFailed
}

private final class MicrophoneCaptureBackendStub: MicrophoneCaptureBackend,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var formats: [AVAudioFormat]
    private var inputRates: [Double] = []
    private var starts = 0
    private let failingStartAttempt: Int?

    init(formats: [AVAudioFormat], failingStartAttempt: Int? = nil) {
        self.formats = formats
        self.failingStartAttempt = failingStartAttempt
    }

    func inputFormat() -> AVAudioFormat {
        lock.withLock {
            let format = formats.removeFirst()
            inputRates.append(format.sampleRate)
            return format
        }
    }

    func installTap(
        bufferHandler: @escaping @Sendable (AVAudioPCMBuffer) -> Void
    ) {}

    func removeTap() {}
    func prepare() {}
    func start() throws {
        let shouldFail = lock.withLock {
            starts += 1
            return starts == failingStartAttempt
        }
        if shouldFail {
            throw MicrophoneCaptureBackendStubError.startFailed
        }
    }
    func stop() {}

    var inputSampleRates: [Double] {
        lock.withLock { inputRates }
    }

    var startCount: Int {
        lock.withLock { starts }
    }
}

private final class AudioSourceEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AudioSourceEvent] = []

    func append(_ event: AudioSourceEvent) {
        lock.withLock { events.append(event) }
    }

    var values: [AudioSourceEvent] {
        lock.withLock { events }
    }
}

private func audioFormat(sampleRate: Double) throws -> AVAudioFormat {
    try #require(
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )
    )
}

private func firstEvent(
    from stream: AsyncStream<AudioSessionEvent>
) async -> AudioSessionEvent? {
    await withTaskGroup(of: AudioSessionEvent?.self) { group in
        group.addTask {
            for await event in stream {
                return event
            }
            return nil
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(1))
            return nil
        }
        let event = await group.next() ?? nil
        group.cancelAll()
        return event
    }
}
