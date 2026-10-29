import Foundation
import Testing
@testable import StenoMacAudio

@Suite("Microphone capture episode decisions")
struct MicrophoneActivityMonitorTests {
    private let ownPID: pid_t = 4242

    @Test("an unselected app cannot start or prolong a selected app's capture episode")
    func appFilterSeparatesCaptureEpisodes() {
        let unrelated = MicrophoneActivityMonitor.CapturingProcess(pid: 100, bundleIdentifier: "com.example.editor")
        let meeting = MicrophoneActivityMonitor.CapturingProcess(pid: 200, bundleIdentifier: "com.example.meet")
        let unknown = MicrophoneActivityMonitor.CapturingProcess(pid: 300, bundleIdentifier: nil)
        let allowed: (String?) -> Bool = { $0 == "com.example.meet" }
        func pids(_ processes: [MicrophoneActivityMonitor.CapturingProcess]) -> Set<pid_t> {
            MicrophoneActivityMonitor.eligibleCapturePIDs(processes, allowing: allowed)
        }
        var decision = CaptureEpisodeDecider(debounceInterval: 2)
        #expect(decision.update(rawCapturingPIDs: pids([unrelated, unknown]), excluding: nil, at: 0) == .noChange)
        #expect(decision.update(rawCapturingPIDs: pids([unrelated, unknown]), excluding: nil, at: 3) == .noChange)
        #expect(decision.update(rawCapturingPIDs: pids([unrelated, meeting]), excluding: nil, at: 4) == .noChange)
        #expect(decision.update(rawCapturingPIDs: pids([unrelated, meeting]), excluding: nil, at: 6) == .episodeStarted)
        #expect(decision.update(rawCapturingPIDs: pids([unrelated]), excluding: nil, at: 7) == .noChange)
        #expect(decision.update(rawCapturingPIDs: pids([unrelated]), excluding: nil, at: 9) == .episodeEnded)
        #expect(decision.update(rawCapturingPIDs: pids([unrelated, meeting]), excluding: nil, at: 10) == .noChange)
        #expect(decision.update(rawCapturingPIDs: pids([unrelated, meeting]), excluding: nil, at: 12) == .episodeStarted)
    }

    private func decider(debounce: TimeInterval = 2.0) -> CaptureEpisodeDecider {
        CaptureEpisodeDecider(debounceInterval: debounce)
    }

    @Test("Start fires once after the debounce interval")
    mutating func startAfterDebounce() {
        var decision = decider()
        #expect(decision.update(rawCapturingPIDs: [100], excluding: ownPID, at: 0) == .noChange)
        #expect(
            decision.update(rawCapturingPIDs: [100], excluding: ownPID, at: 1.9) == .noChange
        )
        #expect(
            decision.update(rawCapturingPIDs: [100], excluding: ownPID, at: 2.0)
                == .episodeStarted
        )
        // Steady state keeps reporting nothing.
        #expect(
            decision.update(rawCapturingPIDs: [100], excluding: ownPID, at: 5.0) == .noChange
        )
    }

    @Test("End fires after the capturing set empties for the debounce interval")
    mutating func endAfterDebounce() {
        var decision = decider()
        decision.update(rawCapturingPIDs: [100], excluding: ownPID, at: 0)
        decision.update(rawCapturingPIDs: [100], excluding: ownPID, at: 2) // started

        #expect(decision.update(rawCapturingPIDs: [], excluding: ownPID, at: 3) == .noChange)
        #expect(decision.update(rawCapturingPIDs: [], excluding: ownPID, at: 4.9) == .noChange)
        #expect(
            decision.update(rawCapturingPIDs: [], excluding: ownPID, at: 5) == .episodeEnded
        )
    }

    @Test("Re-arms after an episode ends")
    mutating func reArmsAfterEnd() {
        var decision = decider()
        decision.update(rawCapturingPIDs: [100], excluding: ownPID, at: 0)
        decision.update(rawCapturingPIDs: [100], excluding: ownPID, at: 2) // started
        decision.update(rawCapturingPIDs: [], excluding: ownPID, at: 3)
        decision.update(rawCapturingPIDs: [], excluding: ownPID, at: 5) // ended

        #expect(decision.phase == .idle)
        #expect(decision.update(rawCapturingPIDs: [200], excluding: ownPID, at: 6) == .noChange)
        #expect(
            decision.update(rawCapturingPIDs: [200], excluding: ownPID, at: 8)
                == .episodeStarted
        )
    }

    @Test("A blip shorter than the debounce interval never opens an episode")
    mutating func shortBlipIsIgnored() {
        var decision = decider()
        for t in stride(from: 0.0, through: 1.5, by: 0.5) {
            let pids: Set<pid_t> = t.truncatingRemainder(dividingBy: 1.0) == 0 ? [300] : []
            #expect(decision.update(rawCapturingPIDs: pids, excluding: ownPID, at: t) == .noChange)
        }
        #expect(decision.phase == .idle)
    }

    @Test("A gap shorter than the debounce interval does not close an episode")
    mutating func shortGapKeepsEpisodeOpen() {
        var decision = decider()
        decision.update(rawCapturingPIDs: [100], excluding: ownPID, at: 0)
        decision.update(rawCapturingPIDs: [100], excluding: ownPID, at: 2) // started

        decision.update(rawCapturingPIDs: [], excluding: ownPID, at: 2.5)
        #expect(decision.phase == .active)
        #expect(
            decision.update(rawCapturingPIDs: [100], excluding: ownPID, at: 3.5) == .noChange
        )
        // Still active well past the original end candidate.
        #expect(
            decision.update(rawCapturingPIDs: [100], excluding: ownPID, at: 10) == .noChange
        )
        #expect(decision.phase == .active)
    }

    @Test("Steno's own pid alone never triggers a notification episode")
    mutating func ownPIDExcluded() {
        var decision = decider()
        for t in [0.0, 1.0, 2.0, 10.0] {
            #expect(
                decision.update(
                    rawCapturingPIDs: [ownPID], excluding: ownPID, at: t
                ) == .noChange
            )
        }
        #expect(decision.phase == .idle)
    }

    @Test("Steno's own pid is filtered out of mixed observations")
    mutating func ownPIDFilteredFromMixedSet() {
        var decision = decider()
        // Only Steno is capturing: no episode.
        decision.update(rawCapturingPIDs: [ownPID], excluding: ownPID, at: 0)
        decision.update(rawCapturingPIDs: [ownPID], excluding: ownPID, at: 2)
        #expect(decision.phase == .idle)

        // A foreign app joins: episode starts even though Steno also appears.
        decision.update(rawCapturingPIDs: [ownPID, 500], excluding: ownPID, at: 4)
        #expect(
            decision.update(rawCapturingPIDs: [ownPID, 500], excluding: ownPID, at: 6)
                == .episodeStarted
        )
    }
}
