@preconcurrency import AVFAudio
import Foundation
import StenoDomain
import StenoLibrary

public enum RecordingSessionState: Equatable, Sendable {
    case idle
    case starting
    case recording
    case stopping
    case stopped
    case failed

    public var isTerminal: Bool {
        self == .stopped || self == .failed
    }
}

public enum RecordingStopReason: Equatable, Sendable {
    case requested
    case lowDiskSpace
    case writerFailure(AudioTrack)
    case ringBufferOverflow(AudioTrack)
    case diskSpaceMonitoringFailure
}

/// How long a track that failed to bind keeps being retried while the
/// recording runs.
///
/// A bind failure is not permanent by nature: the pinned microphone is waited
/// for, and a device that needs a moment longer than the start budget would
/// otherwise be lost for the entire meeting, even though the same device is
/// picked back up without question when it drops out mid-recording.
///
/// Ten minutes by default, because the usual order is to start recording and
/// then join the call. The microphone the automatic choice looks for does not
/// exist until someone else claims it.
public struct TrackRebindPolicy: Equatable, Sendable {
    public var interval: Duration
    public var window: Duration

    public init(
        interval: Duration = .seconds(5),
        window: Duration = .seconds(600)
    ) {
        self.interval = interval
        self.window = window
    }

    public static let standard = TrackRebindPolicy()
    /// For callers that want a failed track to stay failed.
    public static let disabled = TrackRebindPolicy(window: .zero)
}

public struct RecordingResult: Sendable {
    public let assets: [AudioTrack: MediaAsset]
    public let stopReason: RecordingStopReason

    public init(
        assets: [AudioTrack: MediaAsset],
        stopReason: RecordingStopReason
    ) {
        self.assets = assets
        self.stopReason = stopReason
    }
}

public typealias TrackWriterFactory = @Sendable (
    _ url: URL,
    _ sourceFormat: AVAudioFormat
) throws -> any AudioTrackWriting

public actor RecordingSession {
    public private(set) var state: RecordingSessionState = .idle

    private enum TrackIngressEvent: Sendable {
        case buffer(OwnedAudioBuffer, at: ContinuousClock.Instant)
        case source(AudioSourceEvent, at: ContinuousClock.Instant)
    }

    private struct TrackPipeline {
        let timeline: TrackContinuity
        let ingressContinuation: AsyncStream<TrackIngressEvent>.Continuation
    }

    private let meetingID: MeetingID
    private let library: Library
    private let outputDirectory: URL
    private let sources: [AudioTrack: any AudioSource]
    private let sourceOrder: [AudioTrack]
    private let activityManager: any RecordingActivityManaging
    private let availableDiskBytes: @Sendable (URL) throws -> Int64
    private let writerFactory: TrackWriterFactory
    private let diagnostics: any RecordingDiagnosticsRecording
    private let rebindPolicy: TrackRebindPolicy
    private let ringCapacity: Int
    private let diskCheckInterval: Duration
    private let continuityTickInterval: Duration
    private let maximumConsecutiveDiskProbeFailures = 30

    private var pipelines: [AudioTrack: TrackPipeline] = [:]
    private var availableLiveStreams: [AudioTrack: LiveAudioEventStream] = [:]
    private var writers: [AudioTrack: any AudioTrackWriting] = [:]
    private var writerTasks: [AudioTrack: Task<Void, Never>] = [:]
    private var ingressTasks: [AudioTrack: Task<Void, Never>] = [:]
    private var formats: [AudioTrack: AVAudioFormat] = [:]
    private var levelValues: [AudioTrack: AudioLevels] = [:]
    private var diskMonitorTask: Task<Void, Never>?
    private var continuityMonitorTask: Task<Void, Never>?
    private var pendingStopReason: RecordingStopReason = .requested
    private var terminalError: AudioRecordingError?
    private var result: RecordingResult?
    private var stopTask: Task<RecordingResult, any Error>?
    private var activityIsActive = false
    private var startFailures: [AudioTrack: AudioRecordingError] = [:]
    private var sessionAnchor: ContinuousClock.Instant?
    /// Tracks that joined a recording that was already running.
    ///
    /// Their failures belong to them alone, for as long as they last. The
    /// recording started and ran without this track, so losing it again is a
    /// return to a state that was already acceptable - never a reason to end
    /// the recording that is still capturing.
    private var reboundTracks: Set<AudioTrack> = []
    private var rebindTask: Task<Void, Never>?

    /// Records whichever tracks it is handed.
    ///
    /// The source list is variable because iOS has no system audio: there is
    /// the microphone and nothing else, while the Mac always has both. `start()`
    /// already skipped absent tracks (`guard let source = sources[track]`);
    /// only this initializer insisted on two. Each source must sit under its
    /// own track, otherwise the writer files the audio under the wrong name.
    public init(
        meetingID: MeetingID,
        library: Library,
        outputDirectory: URL,
        sources: [AudioTrack: any AudioSource],
        sourceOrder: [AudioTrack]? = nil,
        diagnostics: any RecordingDiagnosticsRecording = NullRecordingDiagnostics(),
        rebindPolicy: TrackRebindPolicy = .standard,
        activityManager: any RecordingActivityManaging,
        ringCapacity: Int = 64,
        diskCheckInterval: Duration = .seconds(1),
        continuityTickInterval: Duration = .milliseconds(100),
        availableDiskBytes: @escaping @Sendable (URL) throws -> Int64 = {
            try DiskSpaceChecker().availableBytes(at: $0)
        },
        writerFactory: @escaping TrackWriterFactory = {
            try TrackWriter(url: $0, sourceFormat: $1)
        }
    ) {
        precondition(ringCapacity > 0)
        precondition(continuityTickInterval > .zero)
        precondition(!sources.isEmpty)
        precondition(sources.allSatisfy { $0.key == $0.value.track })
        let resolvedSourceOrder = sourceOrder
            ?? AudioTrack.allCases.filter { sources[$0] != nil }
        precondition(resolvedSourceOrder.count == sources.count)
        precondition(Set(resolvedSourceOrder) == Set(sources.keys))
        self.meetingID = meetingID
        self.library = library
        self.outputDirectory = outputDirectory
        self.sources = sources
        self.sourceOrder = resolvedSourceOrder
        self.diagnostics = diagnostics
        self.rebindPolicy = rebindPolicy
        self.activityManager = activityManager
        self.ringCapacity = ringCapacity
        self.diskCheckInterval = diskCheckInterval
        self.continuityTickInterval = continuityTickInterval
        self.availableDiskBytes = availableDiskBytes
        self.writerFactory = writerFactory
    }

    public func start() async throws {
        guard state == .idle else { throw AudioRecordingError.alreadyRecording }
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        let available = try availableDiskBytes(outputDirectory)
        try DiskSpaceChecker.validate(availableBytes: available)
        state = .starting

        do {
            var failures: [AudioTrack: AudioRecordingError] = [:]
            await activityManager.begin()
            activityIsActive = true
            for track in sourceOrder {
                guard let source = sources[track] else { continue }
                do {
                    // Only a source that actually started may set the shared
                    // anchor. Setting it earlier would give the next track
                    // artificial leading silence for a source that never ran.
                    sessionAnchor = try await bind(
                        track: track,
                        source: source,
                        sessionStart: sessionAnchor
                    )
                } catch {
                    // The recording is the only irreplaceable artifact. A track
                    // that cannot bind costs that track and nothing else, as
                    // long as one source is still capturing.
                    failures[track] = (error as? AudioRecordingError)
                        ?? .audioSourceUnavailable("\(error)")
                    await discardTrack(track)
                }
                // An overflow on a track that is already recording still ends
                // the session. `discardTrack` has already withdrawn one that
                // belonged to the track just abandoned.
                if let terminalError { throw terminalError }
            }
            guard !writers.isEmpty else {
                throw failures.first?.value
                    ?? AudioRecordingError.audioSourceUnavailable(
                        "no audio source could be started"
                    )
            }
            startFailures = failures
            // Written now, not at stop. A crash between here and the end of
            // the recording would otherwise let recovery adopt the surviving
            // track and present an incomplete meeting as a complete one.
            await persistUnrecordedTracks()
            state = .recording
            // Deliberately started only now, so a track that bound first runs
            // without disk and continuity monitoring while later sources bind.
            // The window is bounded by the sources' own start deadlines, the
            // disk was checked immediately above, and `tickContinuity` ignores
            // anything that is not yet `.recording` anyway.
            startContinuityMonitor()
            startDiskMonitor()
            startRebinding(for: Array(failures.keys))
        } catch {
            await discardPreparedRecording()
            state = .failed
            throw error
        }
    }


    /// Whether a track is still being retried. False once the retry window has
    /// passed, every track is back, or the recording has stopped.
    public var isRebinding: Bool { rebindTask != nil }

    /// Keeps trying to bring back the tracks that did not bind at the start.
    ///
    /// A late track joins the recording that is already running: it is aligned
    /// to the same anchor as the others, so its file begins with the silence it
    /// missed and stays comparable to the track that was there from the start.
    /// It has no live transcript, because the live pass for this recording was
    /// wired up when it started; the final pass reads the file like any other.
    private func startRebinding(for tracks: [AudioTrack]) {
        guard !tracks.isEmpty,
              rebindPolicy.window > .zero,
              sessionAnchor != nil else { return }
        rebindTask = Task { [weak self] in
            await self?.rebindLoop(tracks: tracks)
        }
    }

    private func rebindLoop(tracks: [AudioTrack]) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: rebindPolicy.window)
        var pending = tracks
        while !pending.isEmpty, clock.now < deadline {
            do {
                try await Task.sleep(for: rebindPolicy.interval)
            } catch {
                break
            }
            guard !Task.isCancelled, state == .recording else { break }
            pending = await attemptRebind(of: pending)
        }
        if !pending.isEmpty {
            diagnostics.record(RecordingDiagnosticEvent(
                name: "track-rebind-gave-up",
                details: [
                    "tracks": pending.map(\.rawValue).sorted()
                        .joined(separator: ", "),
                ]
            ))
        }
        rebindTask = nil
    }

    /// Records which tracks this recording is currently missing.
    ///
    /// Kept current while the recording runs rather than written once at the
    /// end, so the stored state is truthful at any moment a crash could
    /// interrupt it.
    private func persistUnrecordedTracks() async {
        let missing = AudioTrack.allCases
            .filter { sources[$0] != nil && startFailures[$0] != nil }
            .map { $0 == .microphone ? MediaAsset.Kind.micTrack : .systemTrack }
        _ = try? await library.updateUnrecordedTracks(meetingID, to: missing)
    }

    /// Drops a track that had joined late and then failed, without touching the
    /// recording that is still running.
    private func abandonReboundTrack(
        _ track: AudioTrack,
        reason: AudioRecordingError
    ) {
        reboundTracks.remove(track)
        startFailures[track] = reason
        diagnostics.record(RecordingDiagnosticEvent(
            name: "track-rebind-lost",
            details: ["track": track.rawValue, "error": "\(reason)"]
        ))
        Task { [weak self] in
            await self?.discardTrack(track)
            await self?.persistUnrecordedTracks()
        }
    }

    /// Returns the tracks that are still missing.
    private func attemptRebind(
        of tracks: [AudioTrack]
    ) async -> [AudioTrack] {
        var stillMissing: [AudioTrack] = []
        for track in tracks {
            guard let source = sources[track] else { continue }
            do {
                _ = try await bind(
                    track: track,
                    source: source,
                    sessionStart: sessionAnchor
                )
                // The recording may have stopped while this was binding. A
                // track half-attached to a stopped session is worse than a
                // missing one.
                guard state == .recording else {
                    await discardTrack(track)
                    return []
                }
                reboundTracks.insert(track)
                startFailures.removeValue(forKey: track)
                await persistUnrecordedTracks()
                diagnostics.record(RecordingDiagnosticEvent(
                    name: "track-rebound",
                    details: ["track": track.rawValue]
                ))
            } catch {
                // bind() may have created a writer and a file before failing.
                await discardTrack(track)
                stillMissing.append(track)
            }
        }
        return stillMissing
    }

    /// Every track that could not be bound, whether it failed while preparing
    /// or while starting. Empty for a recording that bound all of its sources.
    public func failedTracks() -> [AudioTrack: AudioRecordingError] {
        startFailures
    }

    /// Brings one source up and returns the shared session anchor, which the
    /// first successfully started track establishes for all later ones.
    private func bind(
        track: AudioTrack,
        source: any AudioSource,
        sessionStart: ContinuousClock.Instant?
    ) async throws -> ContinuousClock.Instant {
        let format = try await source.prepare()
        formats[track] = format
        let url = outputDirectory.appendingPathComponent(
            "\(meetingID)-\(track.rawValue)-\(UUID()).caf"
        )
        let writer = try writerFactory(url, format)
        writers[track] = writer
        let alignsFirstBuffer = sessionStart != nil
        let sharedSessionStart = sessionStart ?? .now
        let writerPair = AsyncStream.makeStream(
            of: TrackWriteEvent.self,
            bufferingPolicy: .bufferingOldest(ringCapacity)
        )
        let livePair = AsyncStream.makeStream(
            of: LiveAudioEvent.self,
            bufferingPolicy: .bufferingNewest(ringCapacity)
        )
        let timeline = TrackContinuity(
            format: format,
            sessionStart: sharedSessionStart,
            writerContinuation: writerPair.continuation,
            liveContinuation: livePair.continuation,
            alignFirstBufferToSessionStart: alignsFirstBuffer,
            writerOverflowHandler: { [weak self] in
                Task {
                    await self?.writerRingDidOverflow(track: track)
                }
            }
        )
        let ingressPair = AsyncStream.makeStream(
            of: TrackIngressEvent.self,
            bufferingPolicy: .bufferingOldest(ringCapacity)
        )
        let pipeline = TrackPipeline(
            timeline: timeline,
            ingressContinuation: ingressPair.continuation
        )
        pipelines[track] = pipeline
        availableLiveStreams[track] = LiveAudioEventStream(
            stream: livePair.stream
        )
        writerTasks[track] = makeWriterTask(
            track: track,
            stream: writerPair.stream,
            writer: writer
        )
        ingressTasks[track] = makeIngressTask(
            stream: ingressPair.stream,
            timeline: timeline
        )
        try await source.start(
            bufferHandler: { [weak self] buffer in
                let event = TrackIngressEvent.buffer(
                    OwnedAudioBuffer(buffer: buffer),
                    at: .now
                )
                if case .dropped = pipeline.ingressContinuation.yield(event) {
                    Task {
                        await self?.writerRingDidOverflow(track: track)
                    }
                }
            },
            eventHandler: { [weak self] event in
                if case .dropped = pipeline.ingressContinuation.yield(
                    .source(event, at: .now)
                ) {
                    Task {
                        await self?.writerRingDidOverflow(track: track)
                    }
                }
            }
        )
        return sharedSessionStart
    }

    /// Tears down exactly one track, leaving every other source untouched.
    /// `discardPreparedRecording` is session-wide and would stop sources that
    /// are already capturing, so it must never be used for this.
    private func discardTrack(_ track: AudioTrack) async {
        // Remove the track from the session BEFORE awaiting anything. Its
        // writer task may still fail while draining, and `writerDidFail`
        // runs from exactly the task awaited below: finding the track already
        // gone is what stops it from ending a recording that is still running.
        reboundTracks.remove(track)
        let writer = writers.removeValue(forKey: track)
        let pipeline = pipelines.removeValue(forKey: track)
        let ingressTask = ingressTasks.removeValue(forKey: track)
        let writerTask = writerTasks.removeValue(forKey: track)
        formats.removeValue(forKey: track)
        availableLiveStreams.removeValue(forKey: track)
        levelValues.removeValue(forKey: track)

        await sources[track]?.stop()
        pipeline?.ingressContinuation.finish()
        await ingressTask?.value
        if let pipeline {
            await pipeline.timeline.finish(at: ContinuousClock.now)
        }
        await writerTask?.value
        if let writer {
            _ = try? await writer.close()
            setAsideCaptureFile(at: writer.url)
        }
        // A failure already attributed to this track before it was removed
        // must not end the session either.
        withdrawTerminalError(for: track)
    }

    /// Takes back a terminal error that belongs to a track the session has
    /// abandoned. Any other track's failure still ends the recording.
    private func withdrawTerminalError(for track: AudioTrack) {
        switch terminalError {
        case .ringBufferOverflow(let failing) where failing == track,
             .writerFailed(let failing, _) where failing == track:
            terminalError = nil
            pendingStopReason = .requested
        default:
            break
        }
    }

    /// Moves the capture file of an abandoned track out of the way.
    ///
    /// The file is never deleted, because originals are immutable. But it must
    /// stop looking like a track: `CaptureRecovery` adopts every capture file
    /// it can read, and a track the user was told was not recorded must not
    /// reappear as a real one after a later crash.
    private func setAsideCaptureFile(at url: URL) {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { return }
        do {
            try manager.moveItem(
                at: url,
                to: url.appendingPathExtension(Self.discardedCaptureExtension)
            )
        } catch {
            // Setting it aside is the first line of defence, not the only one:
            // `CaptureRecovery` refuses a capture file without audio as well.
            // A file that carries audio and could not be moved would still be
            // adopted, so the failure must be visible rather than swallowed.
            diagnostics.record(RecordingDiagnosticEvent(
                name: "capture-file-not-set-aside",
                details: [
                    "file": url.lastPathComponent,
                    "error": "\(error)",
                ]
            ))
        }
    }

    static let discardedCaptureExtension = "discarded"

    public func liveAudioEvents(
        for track: AudioTrack
    ) throws -> LiveAudioEventStream {
        try takeLiveAudioEvents(for: track)
    }

    public func setPaused(_ paused: Bool, for track: AudioTrack) async {
        guard state == .recording,
              let timeline = pipelines[track]?.timeline else { return }
        await timeline.setUserPaused(paused, at: .now)
    }

    public func status(for track: AudioTrack) async -> RecordingTrackStatus? {
        guard let timeline = pipelines[track]?.timeline else { return nil }
        return await timeline.status
    }

    private func takeLiveAudioEvents(
        for track: AudioTrack
    ) throws -> LiveAudioEventStream {
        guard state == .recording,
              let stream = availableLiveStreams.removeValue(forKey: track) else {
            throw AudioRecordingError.notRecording
        }
        return stream
    }

    public func levels(for track: AudioTrack) -> AudioLevels {
        levelValues[track] ?? .silence
    }

    public func lastError() -> AudioRecordingError? {
        terminalError
    }

    public func lastResult() -> RecordingResult? {
        result
    }

    @discardableResult
    public func stop() async throws -> RecordingResult {
        if let result { return result }
        if let stopTask { return try await stopTask.value }
        guard state == .recording || state == .stopping else {
            throw AudioRecordingError.notRecording
        }
        state = .stopping
        let task = Task { try await self.finalizeStop() }
        stopTask = task
        return try await task.value
    }

    private func finalizeStop() async throws -> RecordingResult {
        // Before anything else: a retry still running would attach a track to
        // a session that is being torn down.
        rebindTask?.cancel()
        await rebindTask?.value
        rebindTask = nil
        diskMonitorTask?.cancel()
        diskMonitorTask = nil

        for track in AudioTrack.allCases {
            await sources[track]?.stop()
        }
        for pipeline in pipelines.values {
            pipeline.ingressContinuation.finish()
        }
        for track in AudioTrack.allCases {
            await ingressTasks[track]?.value
        }
        continuityMonitorTask?.cancel()
        continuityMonitorTask = nil
        let stopInstant = ContinuousClock.now
        for pipeline in pipelines.values {
            await pipeline.timeline.finish(at: stopInstant)
        }
        for track in AudioTrack.allCases {
            await writerTasks[track]?.value
        }

        var assets: [AudioTrack: MediaAsset] = [:]
        do {
            for track in AudioTrack.allCases {
                guard let writer = writers[track],
                      let format = formats[track] else { continue }
                let summary = try await writer.close()
                let asset = try await library.registerCapturedMediaAsset(
                    for: meetingID,
                    sourceURL: writer.url,
                    kind: track == .microphone ? .micTrack : .systemTrack,
                    sampleRate: format.sampleRate,
                    duration: summary.duration
                )
                assets[track] = asset
            }
            // At the end the assets are the truth, whatever happened in
            // between. Only sources this session was actually given count: a
            // single track is normal on a platform that has only one.
            let missing = AudioTrack.allCases.filter {
                sources[$0] != nil && assets[$0] == nil
            }
            try await library.updateUnrecordedTracks(
                meetingID,
                to: missing.map { $0 == .microphone ? .micTrack : .systemTrack }
            )
            _ = try await library.updateMeetingStatus(meetingID, to: .ready)
            await endActivityIfNeeded()
            let completed = RecordingResult(
                assets: assets,
                stopReason: pendingStopReason
            )
            result = completed
            state = pendingStopReason == .requested ? .stopped : .failed
            return completed
        } catch {
            await endActivityIfNeeded()
            state = .failed
            throw error
        }
    }

    private func writerRingDidOverflow(track: AudioTrack) {
        // Same as above: a late overflow from an abandoned track must not end
        // a recording that is still running on another one.
        guard writers[track] != nil else { return }
        if reboundTracks.contains(track) {
            abandonReboundTrack(
                track,
                reason: .ringBufferOverflow(track: track)
            )
            return
        }
        if state == .starting {
            pendingStopReason = .ringBufferOverflow(track)
            terminalError = .ringBufferOverflow(track: track)
            return
        }
        guard state == .recording else { return }
        requestAutomaticStop(
            reason: .ringBufferOverflow(track),
            error: .ringBufferOverflow(track: track)
        )
    }

    private func makeWriterTask(
        track: AudioTrack,
        stream: sending AsyncStream<TrackWriteEvent>,
        writer: any AudioTrackWriting
    ) -> Task<Void, Never> {
        Task { [weak self] in
            do {
                for await event in stream {
                    let levels = try await event.write(to: writer)
                    await self?.updateLevels(levels, for: track)
                }
            } catch {
                await self?.writerDidFail(track: track, error: error)
            }
        }
    }

    private func makeIngressTask(
        stream: sending AsyncStream<TrackIngressEvent>,
        timeline: TrackContinuity
    ) -> Task<Void, Never> {
        Task {
            for await event in stream {
                switch event {
                case let .buffer(owned, instant):
                    await timeline.receive(owned.buffer, at: instant)
                case let .source(event, instant):
                    switch event {
                    case let .unavailable(deviceName):
                        await timeline.setDeviceAvailable(
                            false,
                            deviceName: deviceName,
                            at: instant
                        )
                    case let .available(deviceName):
                        await timeline.setDeviceAvailable(
                            true,
                            deviceName: deviceName,
                            at: instant
                        )
                    }
                }
            }
        }
    }

    private func updateLevels(_ levels: AudioLevels, for track: AudioTrack) {
        guard state == .recording else { return }
        levelValues[track] = levels
    }

    private func writerDidFail(track: AudioTrack, error: any Error) {
        // A track abandoned during start is no longer part of this session.
        guard writers[track] != nil else { return }
        if reboundTracks.contains(track) {
            abandonReboundTrack(track, reason: .writerFailed(
                track: track,
                message: error.localizedDescription
            ))
            return
        }
        if state == .starting {
            pendingStopReason = .writerFailure(track)
            terminalError = .writerFailed(
                track: track,
                message: error.localizedDescription
            )
            return
        }
        if state == .stopping {
            pendingStopReason = .writerFailure(track)
            terminalError = .writerFailed(
                track: track,
                message: error.localizedDescription
            )
            return
        }
        requestAutomaticStop(
            reason: .writerFailure(track),
            error: .writerFailed(track: track, message: error.localizedDescription)
        )
    }

    private func requestAutomaticStop(
        reason: RecordingStopReason,
        error: AudioRecordingError
    ) {
        guard state == .recording else { return }
        pendingStopReason = reason
        terminalError = error
        state = .stopping
        Task { [weak self] in
            _ = try? await self?.stop()
        }
    }

    private func startDiskMonitor() {
        diskMonitorTask = Task { [weak self] in
            guard let self else { return }
            var consecutiveFailures = 0
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: self.diskCheckInterval)
                    guard !Task.isCancelled else { return }
                    let available = try self.availableDiskBytes(self.outputDirectory)
                    consecutiveFailures = 0
                    if available < DiskSpaceChecker.minimumRecordingBytes {
                        await self.diskSpaceDidRunLow(availableBytes: available)
                        return
                    }
                } catch is CancellationError {
                    return
                } catch {
                    consecutiveFailures += 1
                    guard consecutiveFailures
                        >= self.maximumConsecutiveDiskProbeFailures else {
                        continue
                    }
                    await self.diskSpaceMonitorDidFail(error)
                    return
                }
            }
        }
    }

    private func startContinuityMonitor() {
        continuityMonitorTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: self.continuityTickInterval)
                    guard !Task.isCancelled else { return }
                    await self.tickContinuity(at: .now)
                } catch is CancellationError {
                    return
                } catch {
                    continue
                }
            }
        }
    }

    private func tickContinuity(at instant: ContinuousClock.Instant) async {
        guard state == .recording else { return }
        for pipeline in pipelines.values {
            await pipeline.timeline.tick(at: instant)
        }
    }

    private func diskSpaceDidRunLow(availableBytes: Int64) {
        requestAutomaticStop(
            reason: .lowDiskSpace,
            error: .insufficientDiskSpace(
                requiredBytes: DiskSpaceChecker.minimumRecordingBytes,
                availableBytes: availableBytes
            )
        )
    }

    private func diskSpaceMonitorDidFail(_ error: any Error) {
        requestAutomaticStop(
            reason: .diskSpaceMonitoringFailure,
            error: .diskSpaceMonitoringFailed(
                message: error.localizedDescription
            )
        )
    }

    private func discardPreparedRecording() async {
        rebindTask?.cancel()
        await rebindTask?.value
        rebindTask = nil
        diskMonitorTask?.cancel()
        diskMonitorTask = nil
        for track in AudioTrack.allCases {
            await sources[track]?.stop()
        }
        for pipeline in pipelines.values {
            pipeline.ingressContinuation.finish()
        }
        for track in AudioTrack.allCases {
            await ingressTasks[track]?.value
        }
        continuityMonitorTask?.cancel()
        continuityMonitorTask = nil
        let stopInstant = ContinuousClock.now
        for pipeline in pipelines.values {
            await pipeline.timeline.finish(at: stopInstant)
        }
        for track in AudioTrack.allCases {
            await writerTasks[track]?.value
        }
        for writer in writers.values {
            _ = try? await writer.close()
        }
        await endActivityIfNeeded()
    }

    private func endActivityIfNeeded() async {
        guard activityIsActive else { return }
        await activityManager.end()
        activityIsActive = false
    }
}
