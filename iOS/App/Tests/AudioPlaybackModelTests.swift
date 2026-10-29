import Foundation
import Testing
import StenoiOSAudio
@testable import Steno

@Suite("Local original audio playback")
@MainActor
struct AudioPlaybackModelTests {
    private let first = URL(fileURLWithPath: "/synthetic/first.caf")
    private let second = URL(fileURLWithPath: "/synthetic/second.caf")

    @Test("cancelling a delayed play releases its acquired session without playing")
    func cancelledAcquireReleasesSession() async {
        let fixture = PlaybackFixture()
        fixture.delayAcquire = true
        let pending = Task { await fixture.model.togglePlayback(url: first) }
        while fixture.continuation == nil { await Task.yield() }
        pending.cancel()
        fixture.continuation?.resume(returning: UUID())
        fixture.continuation = nil
        await pending.value
        for _ in 0..<20 { await Task.yield() }
        #expect(fixture.player.playCount == 0)
        #expect(fixture.released.count == 1)
        #expect(fixture.model.sourceURL == nil)
        #expect(!fixture.model.isBusy)
    }

    @Test("pause and resume preserve the playback position")
    func playPauseResume() async {
        let fixture = PlaybackFixture()
        await fixture.model.togglePlayback(url: first)
        #expect(fixture.model.isPlaying)
        fixture.player.currentTime = 4
        await fixture.model.togglePlayback(url: first)
        #expect(!fixture.model.isPlaying)
        #expect(fixture.model.currentTime == 4)
        await fixture.model.togglePlayback(url: first)
        #expect(fixture.player.currentTime == 4)
        #expect(fixture.player.playCount == 2)
        fixture.model.stop()
    }

    @Test("a completion from an earlier play cannot stop resumed audio")
    func staleCompletion() async {
        let fixture = PlaybackFixture()
        await fixture.model.togglePlayback(url: first)
        let earlierCompletion = fixture.player.completion
        await fixture.model.togglePlayback(url: first)
        await fixture.model.togglePlayback(url: first)
        earlierCompletion?("Earlier decode failure")
        #expect(fixture.model.isPlaying)
        #expect(fixture.model.errorMessage == nil)
        fixture.model.stop()
    }

    @Test("seeking clamps finite positions and ignores nonfinite input")
    func seekBounds() async {
        let fixture = PlaybackFixture()
        await fixture.model.togglePlayback(url: first)
        fixture.model.seek(to: 100)
        #expect(fixture.player.currentTime == 10)
        fixture.model.seek(to: -.infinity)
        fixture.model.seek(to: .nan)
        #expect(fixture.player.currentTime == 10)
        fixture.model.seek(to: -1)
        #expect(fixture.player.currentTime == 0)
        fixture.model.stop()
    }

    @Test("changing originals stops the previous player")
    func sourceChange() async {
        let fixture = PlaybackFixture()
        await fixture.model.togglePlayback(url: first)
        await fixture.model.togglePlayback(url: second)
        #expect(fixture.player.stopCount == 1)
        #expect(fixture.model.sourceURL == second)
        #expect(fixture.model.isPlaying)
        fixture.model.stop()
    }

    @Test("completion and decode errors end playback and release the session")
    func completionAndFailure() async {
        let fixture = PlaybackFixture()
        await fixture.model.togglePlayback(url: first)
        fixture.player.completion?(nil)
        #expect(!fixture.model.isPlaying)
        #expect(fixture.model.errorMessage == nil)
        await fixture.model.togglePlayback(url: first)
        fixture.player.completion?("Synthetic decode failure")
        #expect(!fixture.model.isPlaying)
        #expect(fixture.model.errorMessage == "Synthetic decode failure")
        for _ in 0..<20 { await Task.yield() }
        #expect(fixture.released.count == 2)
    }

    @Test("a refused player start leaves an actionable error and no active player")
    func refusedStart() async {
        let fixture = PlaybackFixture()
        fixture.player.startSucceeds = false
        await fixture.model.togglePlayback(url: first)
        #expect(!fixture.model.isPlaying)
        #expect(!fixture.model.isBusy)
        #expect(fixture.model.errorMessage != nil)
        for _ in 0..<20 { await Task.yield() }
        #expect(fixture.released.count == 1)
    }

    @Test("stop invalidates a delayed session acquisition", arguments: [false, true])
    func stopDuringAcquire(preemptedByRecording: Bool) async {
        let fixture = PlaybackFixture()
        fixture.delayAcquire = true
        let pending = Task { await fixture.model.togglePlayback(url: first) }
        while fixture.continuation == nil { await Task.yield() }
        if preemptedByRecording {
            await fixture.preempt?()
        } else {
            fixture.model.stop()
        }
        #expect(!fixture.model.isBusy)
        fixture.continuation?.resume(returning: UUID())
        fixture.continuation = nil
        await pending.value
        #expect(fixture.player.playCount == 0)
        #expect(!fixture.model.isPlaying)
        #expect(fixture.model.sourceURL == nil)
        #expect(fixture.released.count == 1)
    }

    @Test("a denied audio-session lease never starts the player")
    func deniedSession() async {
        let fixture = PlaybackFixture()
        fixture.denyAcquire = true
        await fixture.model.togglePlayback(url: first)
        #expect(fixture.player.playCount == 0)
        #expect(fixture.model.errorMessage != nil)
        #expect(!fixture.model.isBusy)
    }

    @Test("a new play waits for a stopped acquisition and its stale lease release")
    func restartDuringAcquire() async {
        let fixture = PlaybackFixture()
        fixture.delayAcquire = true
        let firstRequest = Task { await fixture.model.togglePlayback(url: first) }
        while fixture.continuation == nil { await Task.yield() }
        fixture.model.stop()
        fixture.delayAcquire = false
        fixture.blockRelease = true
        let secondRequest = Task { await fixture.model.togglePlayback(url: second) }
        for _ in 0..<20 { await Task.yield() }
        #expect(fixture.acquireCount == 1)
        fixture.continuation?.resume(returning: UUID())
        fixture.continuation = nil
        while fixture.releaseContinuation == nil { await Task.yield() }
        #expect(fixture.acquireCount == 1)
        #expect(fixture.player.playCount == 0)
        fixture.releaseContinuation?.resume()
        fixture.releaseContinuation = nil
        await firstRequest.value
        await secondRequest.value
        #expect(fixture.acquireCount == 2)
        #expect(fixture.model.isPlaying)
        #expect(fixture.model.sourceURL == second)
        #expect(fixture.model.errorMessage == nil)
        #expect(fixture.released.count == 1)
        fixture.blockRelease = false
        fixture.model.stop()
    }

    @Test("resume waits for the previous lease release", arguments: [false, true])
    func waitsForRelease(changesSource: Bool) async {
        let fixture = PlaybackFixture()
        await fixture.model.togglePlayback(url: first)
        fixture.blockRelease = true
        if !changesSource { await fixture.model.togglePlayback(url: first) }
        let nextURL = changesSource ? second : first
        let next = Task { await fixture.model.togglePlayback(url: nextURL) }
        while fixture.releaseContinuation == nil { await Task.yield() }
        #expect(fixture.acquireCount == 1)
        #expect(fixture.player.playCount == 1)
        fixture.releaseContinuation?.resume()
        fixture.releaseContinuation = nil
        await next.value
        #expect(fixture.acquireCount == 2)
        #expect(fixture.model.isPlaying)
        fixture.blockRelease = false
        fixture.model.stop()
    }

    @Test("invalid durations cannot reach the playback controls", arguments: [0.0, -1.0, Double.infinity, Double.nan])
    func invalidDuration(length: Double) async {
        let fixture = PlaybackFixture()
        fixture.player.duration = length
        await fixture.model.togglePlayback(url: first)
        #expect(fixture.model.duration == 0)
        #expect(fixture.model.errorMessage != nil)
        #expect(fixture.player.playCount == 0)
    }

    @Test("audio-session loss ends playback without automatic resume", arguments: [
        AudioSessionEvent.interruptionBegan(.other),
        .mediaServicesWereReset,
        .routeChanged(.oldDeviceUnavailable),
        .routeChanged(.noSuitableRouteForCategory),
    ])
    func interruptionStopsPlayback(event: AudioSessionEvent) async {
        let fixture = PlaybackFixture()
        let (stream, continuation) = AsyncStream<StenoiOSAudio.AudioSessionEvent>.makeStream()
        fixture.events = stream
        await fixture.model.togglePlayback(url: first)
        continuation.yield(event)
        for _ in 0..<20 { await Task.yield() }
        #expect(!fixture.model.isPlaying)
        continuation.yield(.interruptionEnded(shouldResume: true))
        for _ in 0..<20 { await Task.yield() }
        #expect(fixture.player.playCount == 1)
        continuation.finish()
    }

    @Test("an unreadable original reports failure without acquiring the audio session")
    func unreadableSource() async {
        var acquired = false
        let model = AudioPlaybackModel(
            session: AudioPlaybackSessionClient(
                acquire: { _ in acquired = true; return UUID() },
                release: { _ in }
            ),
            makeBackend: { _ in throw CocoaError(.fileReadCorruptFile) }
        )
        await model.togglePlayback(url: first)
        #expect(!acquired)
        #expect(!model.isPlaying)
        #expect(!model.isBusy)
        #expect(model.errorMessage != nil)
    }
}

@MainActor
private final class PlaybackFixture {
    let player = PlaybackBackendFake()
    var released: [UUID] = []
    var acquireCount = 0
    var ownsLease = false
    var blockRelease = false
    var releaseContinuation: CheckedContinuation<Void, Never>?
    var events: AsyncStream<AudioSessionEvent>?
    var preempt: (@Sendable () async -> Void)?
    var delayAcquire = false
    var denyAcquire = false
    var continuation: CheckedContinuation<UUID?, Never>?
    lazy var model = AudioPlaybackModel(
        session: AudioPlaybackSessionClient(
            acquire: { [unowned self] stop in
                self.acquireCount += 1
                self.preempt = stop
                guard !self.ownsLease, !self.denyAcquire else { return nil }
                self.ownsLease = true
                if self.delayAcquire {
                    return await withCheckedContinuation { self.continuation = $0 }
                }
                return self.denyAcquire ? nil : UUID()
            },
            release: { [weak self] id in
                guard let self else { return }
                if self.blockRelease {
                    await withCheckedContinuation { self.releaseContinuation = $0 }
                }
                self.released.append(id)
                self.ownsLease = false
            },
            events: { [unowned self] in self.events ?? AsyncStream { $0.finish() } }
        ),
        makeBackend: { [unowned self] _ in self.player }
    )
}

@MainActor
private final class PlaybackBackendFake: AudioPlaybackBackend {
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 10
    var completion: (@MainActor @Sendable (String?) -> Void)?
    var startSucceeds = true
    var playCount = 0
    var stopCount = 0
    func play() -> Bool {
        playCount += 1
        return startSucceeds
    }
    func pause() {}
    func stop() { stopCount += 1; currentTime = 0 }
}
