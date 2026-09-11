@preconcurrency import AVFAudio
import Foundation
import StenoDomain
import StenoLibrary
import Testing
@testable import StenoAudioCore

/// The recording is the only irreplaceable artifact: a track that cannot bind
/// must cost that track, never the whole recording.
@Suite("Partial recording start")
struct PartialRecordingStartTests {
    private func makeLibrary() throws -> (URL, Library) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("steno-partial-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let library = try Library.open(
            at: directory.appendingPathComponent("Library")
        )
        return (directory, library)
    }

    private func makeSession(
        library: Library,
        meetingID: MeetingID,
        directory: URL,
        sources: [AudioTrack: any AudioSource],
        order: [AudioTrack]
    ) -> RecordingSession {
        RecordingSession(
            meetingID: meetingID,
            library: library,
            outputDirectory: directory.appendingPathComponent("Capture"),
            sources: sources,
            sourceOrder: order,
            activityManager: FakeActivityManager(),
            availableDiskBytes: { _ in 3_000_000_000 }
        )
    }

    @Test("a microphone that cannot bind leaves the system track recording")
    func keepsRecordingWithoutTheFailedTrack() async throws {
        let (directory, library) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let meeting = try await library.createMeeting(
            title: "Partial",
            status: .recording
        )
        let system = FakeAudioSource(
            track: .system,
            format: syntheticBuffer(channels: 2).format
        )
        let mic = UnbindableAudioSource(track: .microphone)
        let session = makeSession(
            library: library,
            meetingID: meeting.id,
            directory: directory,
            sources: [.microphone: mic, .system: system],
            order: [.system, .microphone]
        )

        try await session.start()
        await system.emit(syntheticBuffer(channels: 2, amplitude: 0.75))

        let failures = await session.failedTracks()
        #expect(Array(failures.keys) == [.microphone])
        // Sol's first hazard: tearing down the failed track must not stop the
        // source that is already capturing.
        #expect(await system.stopCount == 0)

        let result = try await session.stop()
        #expect(result.assets.count == 1)
        #expect(result.assets[.system]?.kind == .systemTrack)
        #expect(result.assets[.microphone] == nil)
        #expect((result.assets[.system]?.duration ?? 0) > 0)
    }

    @Test("the recording still fails when no source binds at all")
    func failsWhenNothingBinds() async throws {
        let (directory, library) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let meeting = try await library.createMeeting(
            title: "Nothing",
            status: .recording
        )
        let session = makeSession(
            library: library,
            meetingID: meeting.id,
            directory: directory,
            sources: [
                .microphone: UnbindableAudioSource(track: .microphone),
                .system: UnbindableAudioSource(track: .system),
            ],
            order: [.system, .microphone]
        )

        await #expect(throws: AudioRecordingError.self) {
            try await session.start()
        }
    }

    @Test("a source failing first does not hold up the one that binds")
    func survivingTrackIsUsableAfterAnEarlierFailure() async throws {
        let (directory, library) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let meeting = try await library.createMeeting(
            title: "SystemFirst",
            status: .recording
        )
        let mic = FakeAudioSource(track: .microphone)
        let session = makeSession(
            library: library,
            meetingID: meeting.id,
            directory: directory,
            sources: [
                .microphone: mic,
                .system: UnbindableAudioSource(track: .system),
            ],
            order: [.system, .microphone]
        )

        try await session.start()
        await mic.emit(syntheticBuffer(amplitude: 0.25))
        // The surviving track must still hand out its live stream exactly once.
        _ = try await session.liveAudioEvents(for: .microphone)
        await #expect(throws: AudioRecordingError.self) {
            _ = try await session.liveAudioEvents(for: .microphone)
        }

        let result = try await session.stop()
        #expect(result.assets[.microphone]?.kind == .micTrack)
        #expect(result.assets[.system] == nil)
    }

    @Test("a microphone that fails while preparing leaves the system track recording")
    func survivesAPrepareFailure() async throws {
        let (directory, library) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let meeting = try await library.createMeeting(
            title: "PrepareFailure",
            status: .recording
        )
        let system = FakeAudioSource(
            track: .system,
            format: syntheticBuffer(channels: 2).format
        )
        let session = makeSession(
            library: library,
            meetingID: meeting.id,
            directory: directory,
            sources: [
                .microphone: UnpreparableAudioSource(track: .microphone),
                .system: system,
            ],
            order: [.system, .microphone]
        )

        try await session.start()
        await system.emit(syntheticBuffer(channels: 2, amplitude: 0.75))

        let failures = await session.failedTracks()
        #expect(Array(failures.keys) == [.microphone])

        let result = try await session.stop()
        #expect(result.assets.count == 1)
        #expect(result.assets[.system]?.kind == .systemTrack)
    }

    @Test("a writer failure on the abandoned track does not end the recording")
    func abandonedTrackWriterFailureIsNotTerminal() async throws {
        let (directory, library) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let meeting = try await library.createMeeting(
            title: "WriterFailure",
            status: .recording
        )
        let system = FakeAudioSource(
            track: .system,
            format: syntheticBuffer(channels: 2).format
        )
        let session = RecordingSession(
            meetingID: meeting.id,
            library: library,
            outputDirectory: directory.appendingPathComponent("Capture"),
            sources: [
                // Emits one buffer and only then refuses to start, so the
                // failing writer below runs before the track is abandoned.
                .microphone: LateFailingAudioSource(track: .microphone),
                .system: system,
            ],
            sourceOrder: [.system, .microphone],
            activityManager: FakeActivityManager(),
            availableDiskBytes: { _ in 3_000_000_000 },
            writerFactory: { url, format in
                if url.lastPathComponent.contains("-microphone-") {
                    return AlwaysFailingWriter(url: url)
                }
                return try TrackWriter(url: url, sourceFormat: format)
            }
        )

        // Without a membership guard the writer failure of the abandoned
        // microphone sets a terminal error and kills the whole recording.
        try await session.start()
        await system.emit(syntheticBuffer(channels: 2, amplitude: 0.75))

        let result = try await session.stop()
        #expect(result.assets[.system]?.kind == .systemTrack)
        #expect(result.assets[.microphone] == nil)
    }

    @Test("an abandoned track leaves no capture file that recovery would adopt")
    func abandonedTrackLeavesNothingToAdopt() async throws {
        let (directory, library) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let meeting = try await library.createMeeting(
            title: "Orphan",
            status: .recording
        )
        let captureDirectory = directory.appendingPathComponent("Capture")
        let session = makeSession(
            library: library,
            meetingID: meeting.id,
            directory: directory,
            sources: [
                .microphone: UnbindableAudioSource(track: .microphone),
                .system: FakeAudioSource(
                    track: .system,
                    format: syntheticBuffer(channels: 2).format
                ),
            ],
            order: [.system, .microphone]
        )

        try await session.start()

        // CaptureRecovery adopts every file in this directory whose name
        // carries a track. A track the user was told was NOT recorded must
        // not come back as a real one after a later crash.
        let files = try FileManager.default.contentsOfDirectory(
            at: captureDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        let adoptable = files.filter {
            CaptureRecovery.trackFromCaptureFileName($0.lastPathComponent)
                == .microphone
        }
        #expect(adoptable.isEmpty)
        _ = try await session.stop()
    }

    @Test("a track that only settles later still joins the running recording")
    func rebindsATrackThatRecoversLater() async throws {
        let (directory, library) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let meeting = try await library.createMeeting(
            title: "Rebind",
            status: .recording
        )
        let system = FakeAudioSource(
            track: .system,
            format: syntheticBuffer(channels: 2).format
        )
        // Fails the first bind the way a webcam microphone does while its
        // camera is being taken over, then settles.
        let mic = EventuallyBindingAudioSource(track: .microphone, failures: 1)
        let session = RecordingSession(
            meetingID: meeting.id,
            library: library,
            outputDirectory: directory.appendingPathComponent("Capture"),
            sources: [.microphone: mic, .system: system],
            sourceOrder: [.system, .microphone],
            rebindPolicy: TrackRebindPolicy(
                interval: .milliseconds(20),
                window: .seconds(10)
            ),
            activityManager: FakeActivityManager(),
            availableDiskBytes: { _ in 3_000_000_000 }
        )

        try await session.start()
        #expect(await session.failedTracks().keys.contains(.microphone))

        try await waitForRebind {
            await session.failedTracks().isEmpty
        }
        await mic.emit(syntheticBuffer(amplitude: 0.25))
        await system.emit(syntheticBuffer(channels: 2, amplitude: 0.75))

        let result = try await session.stop()
        #expect(result.assets[.microphone]?.kind == .micTrack)
        #expect(result.assets[.system]?.kind == .systemTrack)
    }

    @Test("rebinding stops with the recording instead of outliving it")
    func rebindingEndsWithTheRecording() async throws {
        let (directory, library) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let meeting = try await library.createMeeting(
            title: "RebindStop",
            status: .recording
        )
        // Never binds, so the retry is still running when the user stops.
        let mic = EventuallyBindingAudioSource(
            track: .microphone,
            failures: .max
        )
        let session = RecordingSession(
            meetingID: meeting.id,
            library: library,
            outputDirectory: directory.appendingPathComponent("Capture"),
            sources: [
                .microphone: mic,
                .system: FakeAudioSource(
                    track: .system,
                    format: syntheticBuffer(channels: 2).format
                ),
            ],
            sourceOrder: [.system, .microphone],
            rebindPolicy: TrackRebindPolicy(
                interval: .milliseconds(10),
                window: .seconds(600)
            ),
            activityManager: FakeActivityManager(),
            availableDiskBytes: { _ in 3_000_000_000 }
        )

        try await session.start()
        let result = try await session.stop()

        #expect(result.assets.count == 1)
        #expect(result.assets[.system]?.kind == .systemTrack)
        // A retry that kept running would keep touching a stopped session.
        #expect(await session.isRebinding == false)
    }


    @Test("a meeting that lost a track says so after the recording ends")
    func meetingRecordsWhichTrackIsMissing() async throws {
        let (directory, library) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let meeting = try await library.createMeeting(
            title: "Marked",
            status: .recording
        )
        let session = RecordingSession(
            meetingID: meeting.id,
            library: library,
            outputDirectory: directory.appendingPathComponent("Capture"),
            sources: [
                .microphone: UnpreparableAudioSource(track: .microphone),
                .system: FakeAudioSource(
                    track: .system,
                    format: syntheticBuffer(channels: 2).format
                ),
            ],
            sourceOrder: [.system, .microphone],
            rebindPolicy: .disabled,
            activityManager: FakeActivityManager(),
            availableDiskBytes: { _ in 3_000_000_000 }
        )

        try await session.start()
        _ = try await session.stop()

        let stored = try await library.loadMeeting(meeting.id)
        #expect(stored.unrecordedTracks == [.micTrack])
        #expect(!stored.isRecordingComplete)
        #expect(stored.status == .ready)
    }

    @Test("a complete recording is not marked as missing anything")
    func completeRecordingStaysUnmarked() async throws {
        let (directory, library) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let meeting = try await library.createMeeting(
            title: "Complete",
            status: .recording
        )
        let session = makeSession(
            library: library,
            meetingID: meeting.id,
            directory: directory,
            sources: [
                .microphone: FakeAudioSource(track: .microphone),
                .system: FakeAudioSource(
                    track: .system,
                    format: syntheticBuffer(channels: 2).format
                ),
            ],
            order: [.system, .microphone]
        )

        try await session.start()
        _ = try await session.stop()

        let stored = try await library.loadMeeting(meeting.id)
        #expect(stored.isRecordingComplete)
    }


    @Test("a failing rebind never ends the recording that is already running")
    func failingRebindDoesNotEndTheRecording() async throws {
        let (directory, library) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let meeting = try await library.createMeeting(
            title: "RebindFailure",
            status: .recording
        )
        let system = FakeAudioSource(
            track: .system,
            format: syntheticBuffer(channels: 2).format
        )
        // Fails the first bind, then binds and immediately delivers audio into
        // a writer that refuses it: the retry blows up after the session is
        // already recording.
        let mic = LateDeliveringRebindSource(track: .microphone)
        let session = RecordingSession(
            meetingID: meeting.id,
            library: library,
            outputDirectory: directory.appendingPathComponent("Capture"),
            sources: [.microphone: mic, .system: system],
            sourceOrder: [.system, .microphone],
            rebindPolicy: TrackRebindPolicy(
                interval: .milliseconds(20),
                window: .seconds(10)
            ),
            activityManager: FakeActivityManager(),
            availableDiskBytes: { _ in 3_000_000_000 },
            writerFactory: { url, format in
                if url.lastPathComponent.contains("-microphone-") {
                    return AlwaysFailingWriter(url: url)
                }
                return try TrackWriter(url: url, sourceFormat: format)
            }
        )

        try await session.start()
        await system.emit(syntheticBuffer(channels: 2, amplitude: 0.75))

        // Give the retry time to bind, fail, and be discarded.
        try await waitForRebind(timeout: .seconds(10)) {
            await mic.bindAttempts >= 2
        }
        try await Task.sleep(for: .milliseconds(200))

        // The optional track is gone, the irreplaceable one is still recording.
        #expect(await session.state == .recording)
        await system.emit(syntheticBuffer(channels: 2, amplitude: 0.5))

        let result = try await session.stop()
        #expect(result.assets[.system]?.kind == .systemTrack)
        #expect(result.stopReason == .requested)
    }


    @Test("a missing track is on record before a crash could intervene")
    func missingTrackIsPersistedAtStart() async throws {
        let (directory, library) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let meeting = try await library.createMeeting(
            title: "CrashSafe",
            status: .recording
        )
        let session = makeSession(
            library: library,
            meetingID: meeting.id,
            directory: directory,
            sources: [
                .microphone: UnpreparableAudioSource(track: .microphone),
                .system: FakeAudioSource(
                    track: .system,
                    format: syntheticBuffer(channels: 2).format
                ),
            ],
            order: [.system, .microphone]
        )

        try await session.start()

        // Written at start, not at stop: a crash here would otherwise leave
        // recovery adopting the surviving track and presenting the meeting as
        // complete.
        let duringRecording = try await library.loadMeeting(meeting.id)
        #expect(duringRecording.unrecordedTracks == [.micTrack])

        _ = try await session.stop()
    }

    @Test("a track that joins late clears the mark it left at the start")
    func reboundTrackClearsTheMark() async throws {
        let (directory, library) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let meeting = try await library.createMeeting(
            title: "MarkCleared",
            status: .recording
        )
        let mic = EventuallyBindingAudioSource(track: .microphone, failures: 1)
        let session = RecordingSession(
            meetingID: meeting.id,
            library: library,
            outputDirectory: directory.appendingPathComponent("Capture"),
            sources: [
                .microphone: mic,
                .system: FakeAudioSource(
                    track: .system,
                    format: syntheticBuffer(channels: 2).format
                ),
            ],
            sourceOrder: [.system, .microphone],
            rebindPolicy: TrackRebindPolicy(
                interval: .milliseconds(20),
                window: .seconds(10)
            ),
            activityManager: FakeActivityManager(),
            availableDiskBytes: { _ in 3_000_000_000 }
        )

        try await session.start()
        #expect(
            try await library.loadMeeting(meeting.id).unrecordedTracks
                == [.micTrack]
        )

        try await waitForRebind {
            await session.failedTracks().isEmpty
        }
        try await waitForRebind {
            (try? await library.loadMeeting(meeting.id).isRecordingComplete)
                ?? false
        }

        _ = try await session.stop()
        let stored = try await library.loadMeeting(meeting.id)
        #expect(stored.isRecordingComplete)
    }

}

/// Refuses before it ever reports a format, the way a pinned microphone fails
/// when Core Audio will not let it settle. No writer and no file exist yet.
private actor UnpreparableAudioSource: AudioSource {
    nonisolated let track: AudioTrack

    init(track: AudioTrack) {
        self.track = track
    }

    func prepare() throws -> AVAudioFormat {
        throw AudioRecordingError.audioSourceUnavailable(
            "the microphone selected before audio setup is not stable"
        )
    }

    func start(bufferHandler: @escaping AudioBufferHandler) throws {}

    func start(
        bufferHandler: @escaping AudioBufferHandler,
        eventHandler: @escaping AudioSourceEventHandler
    ) throws {}

    func stop() {}
}

/// Delivers audio and only then fails to start, which is what puts data into
/// the writer of a track that is about to be abandoned.
private actor LateFailingAudioSource: AudioSource {
    nonisolated let track: AudioTrack

    init(track: AudioTrack) {
        self.track = track
    }

    func prepare() throws -> AVAudioFormat {
        syntheticBuffer().format
    }

    func start(bufferHandler: @escaping AudioBufferHandler) throws {
        bufferHandler(syntheticBuffer(amplitude: 0.5))
        throw AudioRecordingError.audioSourceUnavailable("late failure")
    }

    func start(
        bufferHandler: @escaping AudioBufferHandler,
        eventHandler: @escaping AudioSourceEventHandler
    ) throws {
        bufferHandler(syntheticBuffer(amplitude: 0.5))
        throw AudioRecordingError.audioSourceUnavailable("late failure")
    }

    func stop() {}
}

private actor AlwaysFailingWriter: AudioTrackWriting {
    nonisolated let url: URL

    init(url: URL) {
        self.url = url
    }

    func write(_ buffer: AVAudioPCMBuffer) throws {
        throw AudioRecordingError.audioSourceUnavailable("writer is broken")
    }

    func close() throws -> TrackWriteSummary {
        throw AudioRecordingError.audioSourceUnavailable("writer is broken")
    }
}

/// A source that reports a format but refuses to start, the way a pinned
/// microphone behaves when Core Audio will not hand it over.
private actor UnbindableAudioSource: AudioSource {
    nonisolated let track: AudioTrack

    init(track: AudioTrack) {
        self.track = track
    }

    func prepare() throws -> AVAudioFormat {
        syntheticBuffer().format
    }

    func start(bufferHandler: @escaping AudioBufferHandler) throws {
        throw AudioRecordingError.audioSourceUnavailable(
            "the microphone selected before audio setup is not stable"
        )
    }

    func start(
        bufferHandler: @escaping AudioBufferHandler,
        eventHandler: @escaping AudioSourceEventHandler
    ) throws {
        throw AudioRecordingError.audioSourceUnavailable(
            "the microphone selected before audio setup is not stable"
        )
    }

    func stop() {}
}

/// Refuses a given number of binds and then behaves like a normal source.
private actor EventuallyBindingAudioSource: AudioSource {
    nonisolated let track: AudioTrack
    private var remainingFailures: Int
    private var handler: AudioBufferHandler?

    init(track: AudioTrack, failures: Int) {
        self.track = track
        remainingFailures = failures
    }

    func prepare() throws -> AVAudioFormat {
        guard remainingFailures <= 0 else {
            remainingFailures -= 1
            throw AudioRecordingError.audioSourceUnavailable(
                "the microphone selected before audio setup is not stable"
            )
        }
        return syntheticBuffer().format
    }

    func start(bufferHandler: @escaping AudioBufferHandler) {
        handler = bufferHandler
    }

    func start(
        bufferHandler: @escaping AudioBufferHandler,
        eventHandler: @escaping AudioSourceEventHandler
    ) {
        handler = bufferHandler
    }

    func stop() {
        handler = nil
    }

    func emit(_ buffer: AVAudioPCMBuffer) async {
        handler?(buffer)
        await Task.yield()
    }
}

/// Polls until a condition holds. Generous on purpose: the point is that the
/// rebind happens at all, not how fast a loaded machine gets there.
private func waitForRebind(
    timeout: Duration = .seconds(10),
    _ condition: @escaping @Sendable () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !(await condition()) {
        guard clock.now < deadline else {
            throw AudioRecordingError.audioSourceUnavailable(
                "condition never became true"
            )
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

/// Fails its first bind, then binds and immediately hands over a buffer, which
/// is what puts data into the writer of a track that has just been rebound.
private actor LateDeliveringRebindSource: AudioSource {
    nonisolated let track: AudioTrack
    private(set) var bindAttempts = 0

    init(track: AudioTrack) {
        self.track = track
    }

    func prepare() throws -> AVAudioFormat {
        bindAttempts += 1
        guard bindAttempts > 1 else {
            throw AudioRecordingError.audioSourceUnavailable(
                "the microphone selected before audio setup is not stable"
            )
        }
        return syntheticBuffer().format
    }

    func start(bufferHandler: @escaping AudioBufferHandler) {
        bufferHandler(syntheticBuffer(amplitude: 0.5))
    }

    func start(
        bufferHandler: @escaping AudioBufferHandler,
        eventHandler: @escaping AudioSourceEventHandler
    ) {
        bufferHandler(syntheticBuffer(amplitude: 0.5))
    }

    func stop() {}
}
