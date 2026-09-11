import CoreAudio
import Foundation

/// What the stability check for the pinned microphone actually observed.
///
/// When a recording fails to start because the selected input never settled,
/// the only useful question is what Core Audio reported in those seconds: was
/// the device missing entirely, or did it keep coming back under a new device
/// ID? The trace records exactly the transitions between those states, never
/// one entry per poll, so a flapping device cannot flood the diagnostics.
struct InputStabilityTrace: Sendable {
    struct Transition: Equatable, Sendable {
        let offsetMilliseconds: Int
        let deviceID: AudioDeviceID?
    }

    private let start: ContinuousClock.Instant
    private let transitionLimit: Int
    private var recorded: [Transition] = []
    private var observedDeviceID: AudioDeviceID?
    private var hasObserved = false

    private(set) var omittedTransitionCount = 0

    init(start: ContinuousClock.Instant, transitionLimit: Int = 24) {
        self.start = start
        self.transitionLimit = transitionLimit
    }

    var transitions: [Transition] { recorded }
    var transitionCount: Int { recorded.count }

    mutating func observe(
        _ device: CoreAudioInputDevice?,
        at instant: ContinuousClock.Instant
    ) {
        let deviceID = device?.id
        guard !hasObserved || deviceID != observedDeviceID else { return }
        hasObserved = true
        observedDeviceID = deviceID
        guard recorded.count < transitionLimit else {
            omittedTransitionCount += 1
            return
        }
        recorded.append(Transition(
            offsetMilliseconds: Self.milliseconds(from: start, to: instant),
            deviceID: deviceID
        ))
    }

    var summary: String {
        let parts = recorded.map { transition in
            let state = transition.deviceID.map { "id=\($0)" } ?? "absent"
            return "\(transition.offsetMilliseconds) ms \(state)"
        }
        let joined = parts.joined(separator: ", ")
        guard omittedTransitionCount > 0 else { return joined }
        return "\(joined) (\(omittedTransitionCount) more transitions omitted)"
    }

    private static func milliseconds(
        from start: ContinuousClock.Instant,
        to instant: ContinuousClock.Instant
    ) -> Int {
        let components = start.duration(to: instant).components
        return Int(
            components.seconds * 1_000
                + components.attoseconds / 1_000_000_000_000_000
        )
    }
}
