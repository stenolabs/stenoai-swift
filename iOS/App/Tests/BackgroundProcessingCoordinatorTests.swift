import Foundation
import StenoDomain
import StenoPipeline
import Testing
@testable import Steno

@MainActor
private final class ControlCounters {
    var stopCalls = 0
    var resumeCalls = 0
    var kindReads = 0
    var deferralFlags: [Bool] = []
}

@MainActor
private final class BackgroundStopGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered = true
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
/// Mutable fixture state so a test can flip unfinished kinds mid-scenario.
private final class JobKindBox: @unchecked Sendable {
    var value: Set<Job.Kind> = []
}

private final class MockActivityProvider: BackgroundActivityProviding {
    private(set) var beginCount = 0
    private(set) var endedTokenValues: Set<Int> = []
    /// When false, `begin` models a system refusal and returns nil.
    var grantOnBegin = true
    private var liveTokens: Set<Int> = []
    private var nextRawValue = 1

    func begin(
        expirationHandler: @escaping @MainActor @Sendable () async -> Void
    ) -> BackgroundActivityToken? {
        guard grantOnBegin else { return nil }
        let token = BackgroundActivityToken(rawValue: nextRawValue)
        nextRawValue += 1
        liveTokens.insert(token.rawValue)
        beginCount += 1
        return token
    }

    func end(_ token: BackgroundActivityToken) {
        liveTokens.remove(token.rawValue)
        endedTokenValues.insert(token.rawValue)
    }

    var hasLiveToken: Bool { !liveTokens.isEmpty }
}

@Suite("Background processing coordinator")
@MainActor
struct BackgroundProcessingCoordinatorTests {
    @Test("foreground waits for an in-flight stop before resuming", arguments: [true, false])
    func foregroundDuringStop(grantedBackgroundTime: Bool) async {
        let provider = MockActivityProvider()
        provider.grantOnBegin = grantedBackgroundTime
        let gate = BackgroundStopGate()
        let counters = ControlCounters()
        var stopFinished = false
        let coordinator = BackgroundProcessingCoordinator(
            activityProvider: provider,
            observesLifecycleNotifications: false,
            controls: .init(
                unfinishedKinds: { [.finalASR] },
                stop: {
                    counters.stopCalls += 1
                    await gate.wait()
                    stopFinished = true
                },
                resume: {
                    #expect(stopFinished, "Resuming before stop finishes leaves the queue stopped")
                    counters.resumeCalls += 1
                }
            ),
            onDeferralChange: { counters.deferralFlags.append($0) }
        )
        let background = Task {
            await coordinator.handleDidEnterBackground()
            if grantedBackgroundTime { await coordinator.handleExpiration() }
        }
        while !gate.entered { await Task.yield() }
        let foreground = Task { await coordinator.handleWillEnterForeground() }
        // Let the foreground handler run while the stop is still suspended.
        for _ in 0..<20 { await Task.yield() }
        #expect(counters.resumeCalls == 0)
        #expect(coordinator.deferredJobKinds == [.finalASR])
        gate.release()
        await background.value
        await foreground.value
        #expect(counters.stopCalls == 1)
        #expect(counters.resumeCalls == 1)
        #expect(coordinator.deferredJobKinds.isEmpty)
        #expect(counters.deferralFlags == [true, false])
    }

    private func makeCoordinator(
        provider: MockActivityProvider,
        counters: ControlCounters,
        kinds: Set<Job.Kind>
    ) -> BackgroundProcessingCoordinator {
        BackgroundProcessingCoordinator(
            activityProvider: provider,
            observesLifecycleNotifications: false,
            controls: .init(
                unfinishedKinds: {
                    counters.kindReads += 1
                    return kinds
                },
                stop: { counters.stopCalls += 1 },
                resume: { counters.resumeCalls += 1 }
            ),
            onDeferralChange: { counters.deferralFlags.append($0) }
        )
    }

    @Test("idle background entry requests no background time")
    func idleBackgroundEntry() async {
        let provider = MockActivityProvider()
        let counters = ControlCounters()
        let coordinator = makeCoordinator(provider: provider, counters: counters, kinds: [])
        await coordinator.handleDidEnterBackground()
        #expect(provider.beginCount == 0)
        #expect(counters.stopCalls == 0)
        #expect(coordinator.deferredJobKinds.isEmpty)
    }

    @Test("background entry with queued work takes background time and stops nothing")
    func activeBackgroundEntry() async {
        let provider = MockActivityProvider()
        let counters = ControlCounters()
        let coordinator = makeCoordinator(
            provider: provider,
            counters: counters,
            kinds: [.finalASR]
        )
        await coordinator.handleDidEnterBackground()
        #expect(provider.beginCount == 1)
        #expect(counters.stopCalls == 0)
        #expect(coordinator.deferredJobKinds.isEmpty)

        // A second background entry while time is held must not double-begin.
        await coordinator.handleDidEnterBackground()
        #expect(provider.beginCount == 1)
    }

    @Test("expiration stops gracefully and flags the deferral")
    func expirationDefers() async {
        let provider = MockActivityProvider()
        let counters = ControlCounters()
        let kinds: Set<Job.Kind> = [.diarization, .templateRender]
        let coordinator = makeCoordinator(
            provider: provider,
            counters: counters,
            kinds: kinds
        )
        await coordinator.handleDidEnterBackground()
        await coordinator.handleExpiration()

        #expect(counters.stopCalls == 1)
        #expect(counters.resumeCalls == 0)
        #expect(coordinator.deferredJobKinds == kinds)
        #expect(counters.deferralFlags == [true])
        // The expired token is returned to the system before anything else.
        #expect(provider.endedTokenValues.count == 1)
        #expect(!provider.hasLiveToken)
    }

    @Test("work finishing inside the window expires without stopping")
    func expirationWithFinishedWork() async {
        let provider = MockActivityProvider()
        let counters = ControlCounters()
        // Work exists when the window is granted, and finishes before the
        // system expires it: the kinds box flips to empty in between.
        let kinds = JobKindBox()
        let coordinator = BackgroundProcessingCoordinator(
            activityProvider: provider,
            observesLifecycleNotifications: false,
            controls: .init(
                unfinishedKinds: {
                    counters.kindReads += 1
                    return kinds.value
                },
                stop: { counters.stopCalls += 1 },
                resume: { counters.resumeCalls += 1 }
            ),
            onDeferralChange: { counters.deferralFlags.append($0) }
        )
        kinds.value = [.diarization]
        await coordinator.handleDidEnterBackground()
        kinds.value = []
        await coordinator.handleExpiration()

        // The finished work neither defers nor stops; only the expired
        // token goes back to the system.
        #expect(counters.stopCalls == 0)
        #expect(coordinator.deferredJobKinds.isEmpty)
        #expect(counters.deferralFlags.isEmpty)
        #expect(provider.endedTokenValues.count == 1)
        #expect(!provider.hasLiveToken)
    }

    @Test("refused background time defers immediately")
    func refusedGrantDefersImmediately() async {
        let provider = MockActivityProvider()
        provider.grantOnBegin = false
        let counters = ControlCounters()
        let coordinator = makeCoordinator(
            provider: provider,
            counters: counters,
            kinds: [.finalASR]
        )
        await coordinator.handleDidEnterBackground()
        #expect(provider.beginCount == 0)
        #expect(counters.stopCalls == 1)
        #expect(coordinator.deferredJobKinds == [.finalASR])
    }

    @Test("foreground after deferral resumes and clears the notice")
    func foregroundResumes() async {
        let provider = MockActivityProvider()
        let counters = ControlCounters()
        let coordinator = makeCoordinator(
            provider: provider,
            counters: counters,
            kinds: [.identitySuggestion]
        )
        await coordinator.handleDidEnterBackground()
        await coordinator.handleExpiration()
        await coordinator.handleWillEnterForeground()

        #expect(counters.resumeCalls == 1)
        #expect(coordinator.deferredJobKinds.isEmpty)
        #expect(counters.deferralFlags == [true, false])

        // Foreground without an expiry just releases the token.
        await coordinator.handleDidEnterBackground()
        await coordinator.handleWillEnterForeground()
        #expect(counters.resumeCalls == 1)
        #expect(provider.endedTokenValues.count == 2)
    }
}
