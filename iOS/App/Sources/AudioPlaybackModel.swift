import AVFAudio
import Foundation
import Observation
import StenoiOSAudio

@MainActor
protocol AudioPlaybackBackend: AnyObject {
    var currentTime: TimeInterval { get set }
    var duration: TimeInterval { get }
    var completion: (@MainActor @Sendable (String?) -> Void)? { get set }
    func play() -> Bool
    func pause()
    func stop()
}

@MainActor
struct AudioPlaybackSessionClient {
    var acquire: @MainActor (@Sendable @escaping () async -> Void) async throws -> UUID?
    var release: @MainActor (UUID) async -> Void
    var events: (@MainActor () async -> AsyncStream<AudioSessionEvent>)? = nil
}

@MainActor
@Observable
final class AudioPlaybackModel {
    private(set) var sourceURL: URL?
    private(set) var isPlaying = false
    private(set) var isBusy = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var errorMessage: String?

    private let session: AudioPlaybackSessionClient
    private let makeBackend: (URL) throws -> any AudioPlaybackBackend
    private var backend: (any AudioPlaybackBackend)?
    private var lease: UUID?
    private var generation: UInt64 = 0
    private var releaseTask: Task<Void, Never>?
    private var acquisitionTask: Task<Void, Error>?
    private var eventTask: Task<Void, Never>?
    private var timer: Task<Void, Never>?

    convenience init(session: AudioSessionController) {
        let leases = PlaybackLeaseStore(session: session)
        self.init(
            session: AudioPlaybackSessionClient(
                acquire: { try await leases.acquire(stop: $0) },
                release: { await leases.release($0) },
                events: { await session.events() }
            ),
            makeBackend: { try LocalAudioPlaybackBackend(url: $0) }
        )
    }

    init(
        session: AudioPlaybackSessionClient,
        makeBackend: @escaping (URL) throws -> any AudioPlaybackBackend
    ) {
        self.session = session
        self.makeBackend = makeBackend
    }

    func togglePlayback(url: URL) async {
        guard !isBusy else { return }
        if sourceURL == url, isPlaying {
            generation &+= 1
            backend?.pause()
            currentTime = backend?.currentTime ?? currentTime
            isPlaying = false
            timer?.cancel()
            timer = nil
            releaseLease()
            return
        }
        if sourceURL != url { stop() }
        errorMessage = nil
        generation &+= 1
        let request = generation
        isBusy = true
        defer { if generation == request { isBusy = false } }
        do {
            guard url.isFileURL else { throw PlaybackFailure.invalidSource }
            if backend == nil {
                backend = try makeBackend(url)
                sourceURL = url
                let length = backend?.duration ?? 0
                guard length.isFinite, length > 0 else { throw PlaybackFailure.cannotPlay }
                duration = length
            }
            _ = await acquisitionTask?.result
            guard generation == request, !Task.isCancelled else { return }
            await releaseTask?.value
            guard generation == request, !Task.isCancelled else { return }
            if let events = session.events {
                let stream = await events()
                guard generation == request, !Task.isCancelled else { return }
                eventTask?.cancel()
                eventTask = Task { [weak self] in
                    for await event in stream {
                        guard !Task.isCancelled else { return }
                        switch event {
                        case .interruptionBegan, .mediaServicesWereReset,
                             .routeChanged(.oldDeviceUnavailable),
                             .routeChanged(.noSuitableRouteForCategory):
                            self?.stopIfCurrent(request)
                            return
                        default: continue
                        }
                    }
                }
            }
            let client = session
            let acquisition = Task { @MainActor [weak self] in
                let acquired = try await client.acquire { [weak self] in
                    await self?.stopIfCurrent(request)
                }
                guard self?.generation == request, !Task.isCancelled else {
                    if let acquired { await client.release(acquired) }
                    return
                }
                guard let acquired else { throw PlaybackFailure.sessionUnavailable }
                self?.lease = acquired
            }
            acquisitionTask = acquisition
            try await acquisition.value
            guard generation == request else { return }
            guard !Task.isCancelled else {
                stop()
                return
            }
            backend?.completion = { [weak self] error in
                guard let self, self.generation == request else { return }
                self.finish(error: error)
            }
            guard backend?.play() == true else { throw PlaybackFailure.cannotPlay }
            isPlaying = true
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled, let self, self.generation == request else { return }
                    self.currentTime = self.backend?.currentTime ?? 0
                }
            }
        } catch {
            guard generation == request else { return }
            finish(error: error.localizedDescription)
        }
    }

    func seek(to time: TimeInterval) {
        guard time.isFinite else { return }
        currentTime = min(max(0, time), duration)
        backend?.currentTime = currentTime
    }

    func stop() {
        generation &+= 1
        eventTask?.cancel()
        eventTask = nil
        timer?.cancel()
        timer = nil
        backend?.completion = nil
        backend?.stop()
        backend = nil
        isPlaying = false
        isBusy = false
        sourceURL = nil
        currentTime = 0
        duration = 0
        releaseLease()
    }

    func clearError() { errorMessage = nil }

    private func stopIfCurrent(_ request: UInt64) {
        guard generation == request else { return }
        stop()
    }

    private func finish(error: String?) {
        stop()
        errorMessage = error
    }

    private func releaseLease() {
        guard let lease else { return }
        self.lease = nil
        let release = session.release
        let previous = releaseTask
        releaseTask = Task {
            await previous?.value
            await release(lease)
        }
    }

    isolated deinit {
        timer?.cancel()
        eventTask?.cancel()
        backend?.completion = nil
        backend?.stop()
        if let lease {
            let release = session.release
            let previous = releaseTask
            Task {
                await previous?.value
                await release(lease)
            }
        }
    }
}

private enum PlaybackFailure: LocalizedError {
    case invalidSource, sessionUnavailable, cannotPlay
    var errorDescription: String? {
        switch self {
        case .invalidSource: String(localized: "Only local recordings can be played.")
        case .sessionUnavailable: String(localized: "Audio playback is unavailable while recording or checking the microphone.")
        case .cannotPlay: String(localized: "The recording could not be played.")
        }
    }
}

@MainActor
private final class PlaybackLeaseStore {
    let session: AudioSessionController
    var leases: [UUID: AudioSessionController.PlaybackLease] = [:]
    init(session: AudioSessionController) { self.session = session }
    func acquire(stop: @Sendable @escaping () async -> Void) async throws -> UUID? {
        guard let lease = try await session.beginPlayback(stopBeforeRecording: stop) else { return nil }
        let id = UUID()
        leases[id] = lease
        return id
    }
    func release(_ id: UUID) async {
        guard let lease = leases.removeValue(forKey: id) else { return }
        try? await session.endPlayback(lease)
    }
}

@MainActor
private final class LocalAudioPlaybackBackend: AudioPlaybackBackend {
    private var delegate: PlaybackDelegate?
    private let player: AVAudioPlayer
    var completion: (@MainActor @Sendable (String?) -> Void)?
    var currentTime: TimeInterval {
        get { player.currentTime }
        set { player.currentTime = newValue }
    }
    var duration: TimeInterval { player.duration }
    init(url: URL) throws {
        player = try AVAudioPlayer(contentsOf: url)

    }
    func play() -> Bool {
        let delegate = PlaybackDelegate(completion: completion)
        self.delegate = delegate
        player.delegate = delegate
        return player.play()
    }
    func pause() { player.pause() }
    func stop() { player.stop() }
}

private final class PlaybackDelegate: NSObject, AVAudioPlayerDelegate, Sendable {
    let completion: (@MainActor @Sendable (String?) -> Void)?
    init(completion: (@MainActor @Sendable (String?) -> Void)?) {
        self.completion = completion
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let handler = completion
        Task { @MainActor in
            handler?(flag ? nil : String(localized: "The recording could not be played completely."))
        }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        let handler = completion
        let message = error?.localizedDescription ?? String(localized: "The recording could not be decoded.")
        Task { @MainActor in handler?(message) }
    }
}
