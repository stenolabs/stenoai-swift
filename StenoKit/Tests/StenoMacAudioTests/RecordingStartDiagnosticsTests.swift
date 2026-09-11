import CoreAudio
import Foundation
import StenoAudioCore
import Testing
@testable import StenoMacAudio

@Suite("Recording start diagnostics")
struct RecordingStartDiagnosticsTests {
    private func device(_ id: AudioDeviceID) -> CoreAudioInputDevice {
        CoreAudioInputDevice(id: id, uid: "camera-uid", name: "Camera")
    }

    @Test("records device transitions with their offsets, not every observation")
    func recordsOnlyTransitions() {
        let start = ContinuousClock.now
        var trace = InputStabilityTrace(start: start)
        trace.observe(nil, at: start)
        trace.observe(nil, at: start.advanced(by: .milliseconds(100)))
        trace.observe(device(100), at: start.advanced(by: .milliseconds(200)))
        trace.observe(device(100), at: start.advanced(by: .milliseconds(300)))
        trace.observe(device(55), at: start.advanced(by: .milliseconds(400)))

        #expect(trace.summary == "0 ms absent, 200 ms id=100, 400 ms id=55")
    }

    @Test("a flapping device cannot grow the trace without bound")
    func boundsAFlappingDevice() {
        let start = ContinuousClock.now
        var trace = InputStabilityTrace(start: start, transitionLimit: 4)
        for step in 0..<40 {
            trace.observe(
                step.isMultiple(of: 2) ? device(100) : nil,
                at: start.advanced(by: .milliseconds(step * 10))
            )
        }

        #expect(trace.transitionCount == 4)
        #expect(trace.omittedTransitionCount == 36)
        #expect(trace.summary.hasSuffix("(36 more transitions omitted)"))
    }

    @Test("reports what it saw when the pinned microphone never settles")
    func reportsTraceWhenDeviceFlaps() async {
        let devices = FlappingDeviceList(sequence: [
            [],
            [CoreAudioInputDevice(id: 100, uid: "camera-uid", name: "Camera")],
            [],
            [CoreAudioInputDevice(id: 137, uid: "camera-uid", name: "Camera")],
        ])

        let outcome = await MicrophoneStability.awaitStableInput(
            uid: "camera-uid",
            window: .milliseconds(200),
            deadline: .milliseconds(400),
            pollInterval: .milliseconds(20),
            listDevices: devices.next,
            timeline: VirtualTimeline()
        )

        guard case let .unstable(trace, observed) = outcome else {
            Issue.record("expected the flapping device to stay unstable")
            return
        }
        #expect(trace.transitionCount >= 3)
        #expect(trace.summary.contains("absent"))
        #expect(trace.summary.contains("id=100"))
        #expect(observed.contains { $0.contains("camera-uid") })
    }

    @Test("accepts the microphone once it holds one device ID")
    func acceptsSettledDevice() async {
        let devices = FlappingDeviceList(sequence: [
            [CoreAudioInputDevice(id: 100, uid: "camera-uid", name: "Camera")],
        ])

        let outcome = await MicrophoneStability.awaitStableInput(
            uid: "camera-uid",
            window: .milliseconds(100),
            deadline: .seconds(2),
            pollInterval: .milliseconds(20),
            listDevices: devices.next,
            timeline: VirtualTimeline()
        )

        guard case let .stable(device, waited) = outcome else {
            Issue.record("expected a device that never changes to settle")
            return
        }
        #expect(device.id == 100)
        #expect(waited >= .milliseconds(100))
    }
    @Test("a microphone that never settles is written to the diagnostics log")
    func writesDiagnosticWhenPreparationFails() async {
        let devices = FlappingDeviceList(sequence: [
            [],
            [CoreAudioInputDevice(id: 100, uid: "camera-uid", name: "Camera")],
        ])
        let diagnostics = CollectingDiagnostics()
        let recorder = MicRecorder(
            resolveDeviceUID: { "camera-uid" },
            stabilityPolicy: MicrophoneStabilityPolicy(
                window: .milliseconds(200),
                deadline: .milliseconds(400),
                pollInterval: .milliseconds(20)
            ),
            listDevices: devices.next,
            diagnostics: diagnostics,
            timeline: VirtualTimeline()
        )

        await #expect(throws: AudioRecordingError.self) {
            _ = try await recorder.prepare()
        }

        let recorded = diagnostics.events
        let failure = recorded.first { $0.name == "microphone-not-stable" }
        let event = try? #require(failure)
        #expect(event?.details["uid"] == "camera-uid")
        #expect(event?.details["trace"]?.contains("id=100") == true)
        #expect(event?.details["devicesSeen"]?.contains("camera-uid") == true)
    }

    @Test("the stability wait gives up as soon as it is cancelled")
    func stabilityWaitHonoursCancellation() async {
        let devices = FlappingDeviceList(sequence: [[]])
        let timeline = VirtualTimeline()

        let task = Task {
            await MicrophoneStability.awaitStableInput(
                uid: "camera-uid",
                window: .seconds(1),
                // A long deadline on purpose: without honouring cancellation
                // the loop spins all the way through it while a stop is
                // already waiting for this very task.
                deadline: .seconds(600),
                pollInterval: .milliseconds(10),
                listDevices: devices.next,
                timeline: timeline
            )
        }
        task.cancel()
        let outcome = await task.value

        guard case .unstable = outcome else {
            Issue.record("expected the cancelled wait to report no device")
            return
        }
        #expect(timeline.elapsed() < .seconds(5))
    }

}

private final class CollectingDiagnostics:
    RecordingDiagnosticsRecording, @unchecked Sendable {
    private var recorded: [RecordingDiagnosticEvent] = []
    private let lock = NSLock()

    var events: [RecordingDiagnosticEvent] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func record(_ event: RecordingDiagnosticEvent) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(event)
    }

    func flush() {}

    @Test("the device is resolved again on every bind, not once at the start")
    func resolvesTheDeviceOnEveryAttempt() async {
        // Nothing is using a microphone yet - the situation when a recording is
        // started before joining the call.
        let resolver = ChangingDeviceResolver(uids: [nil, "camera-uid"])
        let devices = FlappingDeviceList(sequence: [
            [CoreAudioInputDevice(id: 100, uid: "camera-uid", name: "Camera")],
        ])
        let recorder = MicRecorder(
            resolveDeviceUID: resolver.next,
            stabilityPolicy: MicrophoneStabilityPolicy(
                window: .milliseconds(50),
                deadline: .milliseconds(200),
                pollInterval: .milliseconds(10)
            ),
            listDevices: devices.next,
            diagnostics: CollectingDiagnostics(),
            timeline: VirtualTimeline()
        )

        // First attempt: nothing is using a microphone, so there is nothing to
        // bind and it fails.
        await #expect(throws: AudioRecordingError.self) {
            _ = try await recorder.prepare()
        }
        #expect(await resolver.callCount == 1)

        // The retry asks again rather than reusing the first answer. A recorder
        // that had pinned "nothing" at construction time could never recover,
        // which is exactly what happened when a recording was started before
        // joining the call.
        _ = try? await recorder.prepare()
        #expect(await resolver.callCount == 2)
    }
}

/// Answers a different device on each call, like a real resolver watching for
/// a meeting app to claim a microphone.
private final class ChangingDeviceResolver: @unchecked Sendable {
    private let uids: [String?]
    private var index = 0
    private let lock = NSLock()

    init(uids: [String?]) {
        self.uids = uids
    }

    var callCount: Int {
        lock.withLock { index }
    }

    func next() async -> String? {
        lock.withLock {
            let value = uids[min(index, uids.count - 1)]
            index += 1
            return value
        }
    }
}

/// A timeline that moves only when the wait asks it to, so the test result
/// never depends on how busy the machine is.
private final class VirtualTimeline: StabilityTimeline, @unchecked Sendable {
    private var current = ContinuousClock.now
    private let lock = NSLock()

    private let start = ContinuousClock.now

    func now() -> ContinuousClock.Instant {
        lock.withLock { current }
    }

    func elapsed() -> Duration {
        lock.withLock { start.duration(to: current) }
    }

    func sleep(for duration: Duration) async {
        lock.withLock { current = current.advanced(by: duration) }
        await Task.yield()
    }
}

/// Hands out one device list per poll and starts over at the end, so a
/// flapping device keeps flapping for as long as the caller polls.
private final class FlappingDeviceList: @unchecked Sendable {
    private let sequence: [[CoreAudioInputDevice]]
    private var index = 0
    private let lock = NSLock()

    init(sequence: [[CoreAudioInputDevice]]) {
        self.sequence = sequence
    }

    func next() -> [CoreAudioInputDevice] {
        lock.lock()
        defer { lock.unlock() }
        let value = sequence[index % sequence.count]
        index += 1
        return value
    }
}
