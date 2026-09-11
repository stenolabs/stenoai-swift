import CoreAudio
import Foundation

/// How long the pinned microphone must hold still, and how long that is worth
/// waiting for. The defaults are the values the recording path has always
/// used; tests shorten them so they do not have to wait out a real deadline.
public struct MicrophoneStabilityPolicy: Equatable, Sendable {
    public var window: Duration
    public var deadline: Duration
    public var pollInterval: Duration

    public init(
        window: Duration = .seconds(1),
        deadline: Duration = .seconds(5),
        pollInterval: Duration = .milliseconds(100)
    ) {
        self.window = window
        self.deadline = deadline
        self.pollInterval = pollInterval
    }

    public static let standard = MicrophoneStabilityPolicy()
}

/// The clock the stability wait runs on.
///
/// Production waits on the real one. Tests supply a timeline that advances
/// only when the wait asks it to, so a loaded machine cannot turn "the device
/// flapped for five seconds" into "one poll happened and then time was up".
protocol StabilityTimeline: Sendable {
    func now() -> ContinuousClock.Instant
    func sleep(for duration: Duration) async
}

struct RealStabilityTimeline: StabilityTimeline {
    func now() -> ContinuousClock.Instant { ContinuousClock.now }

    func sleep(for duration: Duration) async {
        try? await Task.sleep(for: duration)
    }
}

enum InputStabilityOutcome: Sendable {
    case stable(CoreAudioInputDevice, waited: Duration)
    case unstable(InputStabilityTrace, observedDevices: [String])
}

/// Waits for the pinned microphone to hold still before a recording binds it.
///
/// Starting the system-audio process tap rebuilds Core Audio's device graph,
/// so the selected input can briefly disappear or return under a new device
/// ID. Binding it during that window would capture the wrong route. Kept
/// separate from ``MicRecorder`` so the wait can be exercised without real
/// hardware - and so a failure can say what it saw instead of only that it
/// gave up.
enum MicrophoneStability {
    static func awaitStableInput(
        uid: String,
        window: Duration,
        deadline: Duration,
        pollInterval: Duration,
        listDevices: @Sendable () -> [CoreAudioInputDevice],
        timeline: some StabilityTimeline = RealStabilityTimeline()
    ) async -> InputStabilityOutcome {
        let start = timeline.now()
        let end = start.advanced(by: deadline)
        var stability = PreferredInputStabilityState()
        var trace = InputStabilityTrace(start: start)
        // Every device seen while waiting, not just the last poll: when the
        // pinned device is missing at the moment the deadline expires, the
        // final snapshot alone would hide that it was ever there.
        var everSeen: Set<String> = []

        // Cancellation ends the wait immediately. A stop cancels this task and
        // then waits for it: spinning on to the deadline would hold the stop
        // open while the surviving track keeps recording.
        while timeline.now() < end, !Task.isCancelled {
            let devices = listDevices()
            for device in devices {
                everSeen.insert("\(device.name) [\(device.uid)] id=\(device.id)")
            }
            let matching = devices.first(where: { $0.uid == uid })
            let now = timeline.now()
            stability.observe(matching, at: now)
            trace.observe(matching, at: now)
            if let stable = stability.stableDevice(at: now, for: window) {
                return .stable(stable, waited: start.duration(to: now))
            }
            await timeline.sleep(for: pollInterval)
        }

        return .unstable(trace, observedDevices: everSeen.sorted())
    }
}

extension Duration {
    var wholeMilliseconds: Int {
        Int(
            components.seconds * 1_000
                + components.attoseconds / 1_000_000_000_000_000
        )
    }
}
