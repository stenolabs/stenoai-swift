@preconcurrency import AVFAudio
import Foundation

/// Owns the process-wide `AVAudioSession`, with capture taking priority over playback.
///
/// The Mac has no equivalent: there the engine simply runs. On iOS the session
/// is shared state that the system can revoke, so every capture goes through
/// here and every revocation surfaces as an `AudioSessionEvent` instead of a
/// silent gap in the recording.
public actor AudioSessionController {
    public struct MeteringLease: Hashable, Sendable {
        fileprivate let id: UUID
    }

    public struct RecordingLease: Hashable, Sendable {
        fileprivate let id: UUID
    }

    public struct PlaybackLease: Hashable, Sendable {
        fileprivate let id: UUID
    }

    /// Recording mode. Which one produces better ASR and diarisation on real
    /// room recordings is measurement task R4 in `docs/PLAN-IOS.md`, not a
    /// matter of taste, so it stays configurable and defaults to the mode
    /// Apple applies when an app expresses no preference.
    public enum Mode: Sendable {
        /// System signal processing stays on. Helps distant speakers.
        case standard
        /// Signal processing off, rawest possible signal.
        case measurement

        var sessionMode: AVAudioSession.Mode {
            switch self {
            case .standard: .default
            case .measurement: .measurement
            }
        }
    }

    private let session: AVAudioSession
    private let notificationCenter: NotificationCenter
    private var observers: [NSObjectProtocol] = []
    private var continuations: [UUID: AsyncStream<AudioSessionEvent>.Continuation] = [:]
    private var ownership = AudioSessionOwnership()
    private var meteringStops: [UUID: @Sendable () async -> Void] = [:]
    private var playbackStops: [UUID: @Sendable () async -> Void] = [:]

    public init(
        session: AVAudioSession = .sharedInstance(),
        notificationCenter: NotificationCenter = .default
    ) {
        self.session = session
        self.notificationCenter = notificationCenter
    }

    /// Configures the idle shared session without activating it.
    ///
    /// `.playAndRecord` rather than `.record`, because speaker review plays
    /// audio excerpts back while the library stays recordable.
    ///
    /// Bluetooth HFP is deliberately **not** allowed: it would let AirPods
    /// become the input, and HFP is a narrowband channel that would cost more
    /// transcription accuracy than the convenience is worth. The built-in
    /// microphone or a wired/USB interface is the intended source.
    public func configureForReadiness(mode: Mode = .standard) throws -> Bool {
        guard ownership.allowsReadinessConfiguration else { return false }
        try configureSession(mode: mode)
        return true
    }

    /// Reserves the shared session for diagnostics. A recording atomically
    /// takes this lease and waits for its capture tap to be removed before it
    /// changes or activates the session itself.
    public func beginMetering(
        mode: Mode = .standard,
        stopBeforeRecording: @Sendable @escaping () async -> Void
    ) async throws -> MeteringLease? {
        let id = UUID()
        let playbackID = ownership.playbackID
        guard ownership.beginMetering(id) else { return nil }
        meteringStops[id] = stopBeforeRecording
        let stopPlayback = playbackID.flatMap { playbackStops.removeValue(forKey: $0) }
        await stopPlayback?()
        guard ownership.ownsMetering(id) else {
            meteringStops[id] = nil
            return nil
        }
        do {
            try configureSession(mode: mode)
            try activateSession()
            return MeteringLease(id: id)
        } catch {
            meteringStops[id] = nil
            if ownership.endMetering(id) { try? deactivateSession() }
            throw error
        }
    }

    public func endMetering(_ lease: MeteringLease) throws {
        meteringStops[lease.id] = nil
        guard ownership.endMetering(lease.id) else { return }
        try deactivateSession()
    }

    /// Recording owns the irreplaceable capture. Claim ownership before the
    /// first suspension so no readiness screen can configure or reactivate
    /// the process-wide session while its old tap is being removed.
    public func beginRecording(mode: Mode = .standard) async throws -> RecordingLease {
        let lease = RecordingLease(id: UUID())
        let playbackID = ownership.playbackID
        let meteringID = ownership.beginRecording(lease.id)
        let stopPlayback = playbackID.flatMap { playbackStops.removeValue(forKey: $0) }
        let stopMetering = meteringID.flatMap { meteringStops.removeValue(forKey: $0) }
        await stopPlayback?()
        await stopMetering?()
        guard ownership.ownsRecording(lease.id) else { throw CancellationError() }
        do {
            try configureSession(mode: mode)
            try activateSession()
            return lease
        } catch {
            if ownership.endRecording(lease.id) { try? deactivateSession() }
            throw error
        }
    }

    public func endRecording(_ lease: RecordingLease) throws {
        guard ownership.endRecording(lease.id) else { return }
        try deactivateSession()
    }

    /// Playback is lower priority than either capture or microphone diagnostics.
    /// A capture claims ownership before awaiting this callback, so delayed
    /// playback cleanup cannot deactivate the session of a new recording.
    public func beginPlayback(
        stopBeforeRecording: @Sendable @escaping () async -> Void
    ) throws -> PlaybackLease? {
        let lease = PlaybackLease(id: UUID())
        guard ownership.beginPlayback(lease.id) else { return nil }
        playbackStops[lease.id] = stopBeforeRecording
        do {
            try session.setCategory(.playback, mode: .default)
            try activateSession()
            return lease
        } catch {
            playbackStops[lease.id] = nil
            if ownership.endPlayback(lease.id) { try? deactivateSession() }
            throw error
        }
    }

    public func endPlayback(_ lease: PlaybackLease) throws {
        playbackStops[lease.id] = nil
        guard ownership.endPlayback(lease.id) else { return }
        defer { try? deactivateSession() }
        try configureSession(mode: .standard)
    }

    /// Events for as long as the returned stream is held.
    ///
    /// Each caller gets its own stream so the recording session and the UI can
    /// both listen without one cancelling the other.
    public func events() -> AsyncStream<AudioSessionEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<AudioSessionEvent>.makeStream()
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        startObservingIfNeeded()
        return stream
    }

    /// The sample rate the hardware is actually running at.
    ///
    /// Reported for logging and for the format check when a route changes; the
    /// writer still takes its format from the engine's input node.
    public var currentSampleRate: Double {
        session.sampleRate
    }

    /// Description of the current input, for the recording UI.
    public var currentInputDescription: String? {
        session.currentRoute.inputs.first?.portName
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    private func configureSession(mode: Mode) throws {
        try session.setCategory(
            .playAndRecord,
            mode: mode.sessionMode,
            options: [.defaultToSpeaker]
        )
    }

    private func activateSession() throws {
        try session.setActive(true)
        startObservingIfNeeded()
    }

    private func deactivateSession() throws {
        try session.setActive(
            false,
            options: [.notifyOthersOnDeactivation]
        )
    }

    private func emit(_ event: AudioSessionEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    private func startObservingIfNeeded() {
        guard observers.isEmpty else { return }
        observers.append(
            notificationCenter.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: nil,
                queue: nil
            ) { [weak self] notification in
                guard let event = Self.interruptionEvent(from: notification) else {
                    return
                }
                Task { [weak self] in
                    await self?.emit(event)
                }
            }
        )

        observers.append(
            notificationCenter.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: nil,
                queue: nil
            ) { [weak self] notification in
                let reason = Self.routeChangeReason(from: notification)
                Task { [weak self] in
                    await self?.emit(.routeChanged(reason))
                }
            }
        )

        observers.append(
            notificationCenter.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                Task { [weak self] in
                    await self?.emit(.mediaServicesWereReset)
                }
            }
        )
    }

    deinit {
        for observer in observers {
            notificationCenter.removeObserver(observer)
        }
        for continuation in continuations.values {
            continuation.finish()
        }
    }
}

struct AudioSessionOwnership {
    private var recordingID: UUID?
    private var meteringID: UUID?
    private(set) var playbackID: UUID?

    var isRecording: Bool { recordingID != nil }
    var allowsReadinessConfiguration: Bool { recordingID == nil && playbackID == nil }

    func ownsMetering(_ id: UUID) -> Bool { meteringID == id }
    func ownsRecording(_ id: UUID) -> Bool { recordingID == id }

    mutating func beginMetering(_ id: UUID) -> Bool {
        guard recordingID == nil, meteringID == nil else { return false }
        meteringID = id
        playbackID = nil
        return true
    }

    mutating func endMetering(_ id: UUID) -> Bool {
        guard meteringID == id else { return false }
        meteringID = nil
        return recordingID == nil
    }

    mutating func beginRecording(_ id: UUID) -> UUID? {
        recordingID = id
        playbackID = nil
        defer { meteringID = nil }
        return meteringID
    }

    mutating func endRecording(_ id: UUID) -> Bool {
        guard recordingID == id else { return false }
        recordingID = nil
        return true
    }

    mutating func beginPlayback(_ id: UUID) -> Bool {
        guard recordingID == nil, meteringID == nil, playbackID == nil else { return false }
        playbackID = id
        return true
    }

    mutating func endPlayback(_ id: UUID) -> Bool {
        guard playbackID == id else { return false }
        playbackID = nil
        return recordingID == nil && meteringID == nil
    }
}

// Notification decoding is static and free of actor state so it can be tested
// with synthesised notifications, without a live audio session.
extension AudioSessionController {
    static func interruptionEvent(
        from notification: Notification
    ) -> AudioSessionEvent? {
        guard
            let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: raw)
        else {
            return nil
        }

        switch type {
        case .began:
            let rawReason = notification.userInfo?[
                AVAudioSessionInterruptionReasonKey
            ] as? UInt
            let reason = rawReason
                .flatMap(AVAudioSession.InterruptionReason.init(rawValue:))
                .map(AudioInterruptionReason.from)
            return .interruptionBegan(reason ?? .other)
        case .ended:
            let rawOptions = notification.userInfo?[
                AVAudioSessionInterruptionOptionKey
            ] as? UInt
            let options = rawOptions.map(
                AVAudioSession.InterruptionOptions.init(rawValue:)
            )
            return .interruptionEnded(
                shouldResume: options?.contains(.shouldResume) ?? false
            )
        @unknown default:
            return nil
        }
    }

    static func routeChangeReason(
        from notification: Notification
    ) -> AudioRouteChangeReason {
        guard
            let raw = notification.userInfo?[
                AVAudioSessionRouteChangeReasonKey
            ] as? UInt,
            let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
        else {
            return .unknown
        }
        return AudioRouteChangeReason.from(reason)
    }
}
