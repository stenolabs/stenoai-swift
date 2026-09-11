@preconcurrency import AVFAudio
import Foundation
import StenoDomain
import StenoLibrary
import Testing
@testable import StenoAudioCore

@Suite("RecordingSession")
struct RecordingSessionTests {
    @Test("fans both fake sources out to CAF files and an independent live stream")
    func recordsAndStreams() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try Library.open(at: directory.appendingPathComponent("Library"))
        let meeting = try await library.createMeeting(title: "Test", status: .recording)
        let mic = FakeAudioSource(track: .microphone)
        let system = FakeAudioSource(
            track: .system,
            format: syntheticBuffer(channels: 2).format
        )
        let activity = FakeActivityManager()
        let session = RecordingSession(
            meetingID: meeting.id,
            library: library,
            outputDirectory: directory.appendingPathComponent("Capture"),
            sources: [.microphone: mic, .system: system],
            activityManager: activity,
            availableDiskBytes: { _ in 3_000_000_000 }
        )

        try await session.start()
        let liveStream = try await session.liveAudioEvents(for: .microphone).stream
        let liveBuffer = Task<AVAudioPCMBuffer?, Never> {
            for await event in liveStream {
                if case let .buffer(owned) = event { return owned.buffer }
            }
            return nil
        }
        await mic.emit(syntheticBuffer(amplitude: 0.25))
        await system.emit(syntheticBuffer(channels: 2, amplitude: 0.75))
        let streamed = await liveBuffer.value
        #expect(streamed?.frameLength == 4_000)
        try await waitUntil { await session.levels(for: .system).peak > 0.7 }

        let result = try await session.stop()

        #expect(result.assets.count == 2)
        #expect(result.assets[.microphone]?.kind == .micTrack)
        #expect(result.assets[.system]?.kind == .systemTrack)
        // Mindestens, nicht genau: TrackContinuity polstert die Spur beim
        // Stoppen bewusst auf die Wanduhrzeit, damit Mikro- und Systemspur
        // ausgerichtet bleiben. Auf einer belasteten Maschine vergeht zwischen
        // Start und Stopp mehr Zeit als der emittierte Ton, es wird also mehr
        // Stille geschrieben. Eine Gleichheitspruefung haelt nur auf einer
        // leerlaufenden Maschine und macht den Test unter Last flakig.
        let micDuration = try #require(result.assets[.microphone]?.duration)
        #expect(micDuration >= 0.5)
        #expect(result.assets[.system]?.sampleRate == 8_000)
        let micAsset = try #require(result.assets[.microphone])
        let micURL = library.layout.mediaFile(meeting.id, fileName: micAsset.fileName)
        let recordedFile = try AVAudioFile(forReading: micURL)
        #expect(recordedFile.fileFormat.commonFormat == .pcmFormatInt16)
        #expect(recordedFile.length >= 4_000)
        let stagingFiles = try FileManager.default.contentsOfDirectory(
            at: directory.appendingPathComponent("Capture"),
            includingPropertiesForKeys: nil
        )
        #expect(stagingFiles.filter { $0.pathExtension == "caf" }.isEmpty)
        #expect(try await library.loadMeeting(meeting.id).status == .ready)
        #expect(await activity.counts() == ActivityCounts(begun: 1, ended: 1))
    }

    @Test("finalization renames the durable capture inode into the library")
    func finalizationRenamesCaptureInode() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try Library.open(at: directory.appendingPathComponent("Library"))
        let meeting = try await library.createMeeting(
            title: "Durable",
            status: .recording
        )
        let captureDirectory = library.layout.captureDirectory(meeting.id)
        let mic = FakeAudioSource(track: .microphone)
        let session = RecordingSession(
            meetingID: meeting.id,
            library: library,
            outputDirectory: captureDirectory,
            sources: [.microphone: mic],
            activityManager: FakeActivityManager(),
            availableDiskBytes: { _ in 3_000_000_000 }
        )

        try await session.start()
        let captureURL = try #require(
            try FileManager.default.contentsOfDirectory(
                at: captureDirectory,
                includingPropertiesForKeys: nil
            ).first { $0.pathExtension == "caf" }
        )
        let captureInode = try inode(of: captureURL)
        await mic.emit(syntheticBuffer())

        let result = try await session.stop()
        let asset = try #require(result.assets[.microphone])
        let mediaURL = library.layout.mediaFile(
            meeting.id,
            fileName: asset.fileName
        )

        #expect(try inode(of: mediaURL) == captureInode)
        #expect(!FileManager.default.fileExists(atPath: captureURL.path))
    }

    @Test("a requested source order fully starts system audio before preparing the microphone")
    func startsSourcesSequentiallyInRequestedOrder() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try Library.open(at: directory.appendingPathComponent("Library"))
        let meeting = try await library.createMeeting(title: "Test", status: .recording)
        let lifecycle = SourceLifecycleLog()
        let mic = FakeAudioSource(track: .microphone, lifecycle: lifecycle)
        let system = FakeAudioSource(track: .system, lifecycle: lifecycle)
        let session = RecordingSession(
            meetingID: meeting.id,
            library: library,
            outputDirectory: directory.appendingPathComponent("Capture"),
            sources: [.microphone: mic, .system: system],
            sourceOrder: [.system, .microphone],
            activityManager: FakeActivityManager(),
            availableDiskBytes: { _ in 3_000_000_000 }
        )

        try await session.start()

        #expect(lifecycle.events == [
            "prepare-system",
            "start-system",
            "prepare-microphone",
            "start-microphone",
        ])
        _ = try await session.stop()
    }

    @Test("refuses to start before touching sources when less than two GB are free")
    func checksDiskBeforeStart() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try Library.open(at: directory.appendingPathComponent("Library"))
        let meeting = try await library.createMeeting(title: "Test", status: .recording)
        let mic = FakeAudioSource(track: .microphone)
        let system = FakeAudioSource(track: .system)
        let session = RecordingSession(
            meetingID: meeting.id,
            library: library,
            outputDirectory: directory.appendingPathComponent("Capture"),
            sources: [.microphone: mic, .system: system],
            activityManager: FakeActivityManager(),
            availableDiskBytes: { _ in 1_000_000 }
        )

        await #expect(throws: AudioRecordingError.self) {
            try await session.start()
        }
        #expect(await mic.startCount == 0)
        #expect(await system.startCount == 0)
    }

    @Test("a writer failure automatically stops sources and keeps the written prefix")
    func writerFailureStopsCleanly() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try Library.open(at: directory.appendingPathComponent("Library"))
        let meeting = try await library.createMeeting(title: "Test", status: .recording)
        let mic = FakeAudioSource(track: .microphone)
        let system = FakeAudioSource(track: .system)
        let session = RecordingSession(
            meetingID: meeting.id,
            library: library,
            outputDirectory: directory.appendingPathComponent("Capture"),
            sources: [.microphone: mic, .system: system],
            activityManager: FakeActivityManager(),
            availableDiskBytes: { _ in 3_000_000_000 },
            writerFactory: { url, format in
                let writer = try TrackWriter(url: url, sourceFormat: format)
                if url.lastPathComponent.contains("-microphone-") {
                    return FailingAfterOneWriteWriter(underlying: writer)
                }
                return writer
            }
        )

        try await session.start()
        await mic.emit(syntheticBuffer())
        await mic.emit(syntheticBuffer())
        await system.emit(syntheticBuffer())
        try await waitUntil { await session.state.isTerminal }
        let result = try #require(await session.lastResult())

        #expect(await mic.stopCount == 1)
        #expect(await system.stopCount == 1)
        // Mindestens, nicht genau: TrackContinuity polstert die Spur beim
        // Stoppen bewusst auf die Wanduhrzeit, damit Mikro- und Systemspur
        // ausgerichtet bleiben. Auf einer belasteten Maschine vergeht zwischen
        // Start und Stopp mehr Zeit als der emittierte Ton, es wird also mehr
        // Stille geschrieben. Eine Gleichheitspruefung haelt nur auf einer
        // leerlaufenden Maschine und macht den Test unter Last flakig.
        let micDuration = try #require(result.assets[.microphone]?.duration)
        #expect(micDuration >= 0.5)
        if case .writerFailure(.microphone) = result.stopReason {
            // Expected.
        } else {
            Issue.record("expected a microphone writer failure")
        }
    }

    @Test("the default disk probe accepts a new capture directory")
    func probesNewCaptureDirectory() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try Library.open(at: directory.appendingPathComponent("Library"))
        let meeting = try await library.createMeeting(title: "Test", status: .recording)
        let session = RecordingSession(
            meetingID: meeting.id,
            library: library,
            outputDirectory: directory.appendingPathComponent("New-Capture"),
            sources: [
                .microphone: FakeAudioSource(track: .microphone),
                .system: FakeAudioSource(track: .system),
            ],
            activityManager: FakeActivityManager()
        )

        try await session.start()
        _ = try await session.stop()
    }

    @Test("falling below two GB during recording stops cleanly with both prefixes")
    func stopsWhenDiskRunsLow() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try Library.open(at: directory.appendingPathComponent("Library"))
        let meeting = try await library.createMeeting(title: "Test", status: .recording)
        let mic = FakeAudioSource(track: .microphone)
        let system = FakeAudioSource(track: .system)
        let capacities = CapacitySequence([3_000_000_000, 1_000_000_000])
        let session = RecordingSession(
            meetingID: meeting.id,
            library: library,
            outputDirectory: directory.appendingPathComponent("Capture"),
            sources: [.microphone: mic, .system: system],
            activityManager: FakeActivityManager(),
            diskCheckInterval: .milliseconds(10),
            availableDiskBytes: { _ in capacities.next() }
        )

        try await session.start()
        await mic.emit(syntheticBuffer())
        await system.emit(syntheticBuffer())
        try await waitUntil { await session.state.isTerminal }
        let result = try #require(await session.lastResult())

        #expect(result.stopReason == .lowDiskSpace)
        #expect(result.assets.count == 2)
        #expect(await session.lastError() == .insufficientDiskSpace(
            requiredBytes: 2_000_000_000,
            availableBytes: 1_000_000_000
        ))
    }

    @Test("thirty consecutive disk probe failures finalize the recorded prefix")
    func persistentDiskProbeFailureFinalizesRecording() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try Library.open(at: directory.appendingPathComponent("Library"))
        let meeting = try await library.createMeeting(
            title: "Probe failure",
            status: .recording
        )
        let mic = FakeAudioSource(track: .microphone)
        let probe = FailingCapacityProbe()
        let session = RecordingSession(
            meetingID: meeting.id,
            library: library,
            outputDirectory: library.layout.captureDirectory(meeting.id),
            sources: [.microphone: mic],
            activityManager: FakeActivityManager(),
            diskCheckInterval: .milliseconds(2),
            availableDiskBytes: { _ in try probe.next() }
        )

        try await session.start()
        await mic.emit(syntheticBuffer())
        try await waitUntil { await session.state.isTerminal }
        let result = try #require(await session.lastResult())
        let asset = try #require(result.assets[.microphone])
        let mediaURL = library.layout.mediaFile(
            meeting.id,
            fileName: asset.fileName
        )
        let audio = try AVAudioFile(forReading: mediaURL)

        #expect(probe.failureCount == 30)
        #expect(result.stopReason == .diskSpaceMonitoringFailure)
        #expect(await session.lastError() == .diskSpaceMonitoringFailed(
            message: PersistentDiskProbeError().localizedDescription
        ))
        // Mindestens, nicht genau: TrackContinuity polstert die Spur beim
        // Stoppen bewusst auf die Wanduhrzeit, damit Mikro- und Systemspur
        // ausgerichtet bleiben. Auf einer belasteten Maschine vergeht zwischen
        // Start und Stopp mehr Zeit als der emittierte Ton, es wird also mehr
        // Stille geschrieben. Eine Gleichheitspruefung haelt nur auf einer
        // leerlaufenden Maschine und macht den Test unter Last flakig.
        #expect(audio.length >= 4_000)
        #expect(try await library.loadMeeting(meeting.id).status == .ready)
    }

    @Test("concurrent stop callers share one finalization and one pair of assets")
    func serializesConcurrentStops() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try Library.open(at: directory.appendingPathComponent("Library"))
        let meeting = try await library.createMeeting(title: "Test", status: .recording)
        let mic = FakeAudioSource(track: .microphone)
        let system = FakeAudioSource(track: .system)
        let session = RecordingSession(
            meetingID: meeting.id,
            library: library,
            outputDirectory: directory.appendingPathComponent("Capture"),
            sources: [.microphone: mic, .system: system],
            activityManager: FakeActivityManager(),
            availableDiskBytes: { _ in 3_000_000_000 }
        )

        try await session.start()
        await mic.emit(syntheticBuffer())
        await system.emit(syntheticBuffer())
        async let first = session.stop()
        async let second = session.stop()
        let (firstResult, secondResult) = try await (first, second)

        #expect(firstResult.assets == secondResult.assets)
        #expect(firstResult.assets.count == 2)
    }

    /// The iOS case: one microphone and no system audio at all.
    ///
    /// Worth its own test because a session that quietly produced an empty
    /// system track, or waited for a source that never arrives, would look
    /// correct right up to the moment the recording is actually needed.
    @Test("records a single track when no system audio source exists")
    func recordsMicrophoneOnly() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try Library.open(at: directory.appendingPathComponent("Library"))
        let meeting = try await library.createMeeting(title: "Test", status: .recording)
        let mic = FakeAudioSource(track: .microphone)
        let session = RecordingSession(
            meetingID: meeting.id,
            library: library,
            outputDirectory: directory.appendingPathComponent("Capture"),
            sources: [.microphone: mic],
            activityManager: FakeActivityManager(),
            availableDiskBytes: { _ in 3_000_000_000 }
        )

        try await session.start()
        await mic.emit(syntheticBuffer())
        let result = try await session.stop()

        #expect(result.assets.count == 1)
        #expect(result.assets[.microphone]?.kind == .micTrack)
        #expect(result.assets[.system] == nil)
        #expect(await mic.startCount == 1)
    }

    @Test("a missing microphone is silent while the other track stays continuous")
    func fillsUnavailableMicrophoneGap() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try Library.open(at: directory.appendingPathComponent("Library"))
        let meeting = try await library.createMeeting(title: "Test", status: .recording)
        let mic = FakeAudioSource(track: .microphone)
        let system = FakeAudioSource(track: .system)
        let session = RecordingSession(
            meetingID: meeting.id,
            library: library,
            outputDirectory: directory.appendingPathComponent("Capture"),
            sources: [.microphone: mic, .system: system],
            activityManager: FakeActivityManager(),
            continuityTickInterval: .milliseconds(5),
            availableDiskBytes: { _ in 3_000_000_000 }
        )

        try await session.start()
        let liveStream = try await session.liveAudioEvents(for: .microphone).stream
        await mic.emit(syntheticBuffer(frames: 80))
        await system.emit(syntheticBuffer(frames: 80))
        await mic.emitEvent(.unavailable(deviceName: "AirPods"))
        try await waitUntil {
            await session.status(for: .microphone)?.deviceAvailable == false
        }
        try await Task.sleep(for: .milliseconds(30))
        await mic.emitEvent(.available(deviceName: "AirPods"))
        await mic.emit(syntheticBuffer(frames: 80))
        let result = try await session.stop()
        let events = await collect(liveStream)

        let micDuration = try #require(result.assets[.microphone]?.duration)
        let systemDuration = try #require(result.assets[.system]?.duration)
        #expect(abs(micDuration - systemDuration) <= 0.010_001)
        // Der Live-Strom ist `bufferingNewest` und damit ausdruecklich
        // verlustbehaftet; nur der Writer-Strom der Aufnahme ist es nicht.
        // Auf eine exakte Ereignisfolge zu pruefen, verlangt eine Zusicherung,
        // die es nicht gibt: das letzte Ereignis kann noch unterwegs sein, wenn
        // `stop()` den Strom schliesst. Zugesichert ist die Reihenfolge der
        // Luecke, und dass die Spur trotz der Luecke kontinuierlich bleibt -
        // letzteres pruefen die Dauern oben.
        let kinds = eventKinds(events)
        let gapStart = try #require(kinds.firstIndex(of: .gapStarted))
        let gapEnd = try #require(kinds.firstIndex(of: .gapEnded))
        #expect(gapStart < gapEnd)
        #expect(kinds.first == .buffer)
    }

    @Test("manual microphone pause never pauses system audio or auto-resumes")
    func pausesOnlyMicrophone() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try Library.open(at: directory.appendingPathComponent("Library"))
        let meeting = try await library.createMeeting(title: "Test", status: .recording)
        let mic = FakeAudioSource(track: .microphone)
        let system = FakeAudioSource(track: .system)
        let session = RecordingSession(
            meetingID: meeting.id,
            library: library,
            outputDirectory: directory.appendingPathComponent("Capture"),
            sources: [.microphone: mic, .system: system],
            activityManager: FakeActivityManager(),
            continuityTickInterval: .milliseconds(5),
            availableDiskBytes: { _ in 3_000_000_000 }
        )

        try await session.start()
        let liveStream = try await session.liveAudioEvents(for: .microphone).stream
        await session.setPaused(true, for: .microphone)
        await mic.emit(syntheticBuffer(amplitude: 0.9))
        await system.emit(syntheticBuffer(amplitude: 0.8))
        await mic.emitEvent(.unavailable(deviceName: "AirPods"))
        await mic.emitEvent(.available(deviceName: "AirPods"))
        await mic.emit(syntheticBuffer(amplitude: 0.9))
        try await waitUntil {
            await session.status(for: .microphone)?.deviceAvailable == true
        }

        let status = try #require(await session.status(for: .microphone))
        #expect(status.userPaused)
        try await waitUntil { await session.levels(for: .system).peak > 0.7 }
        #expect(await session.levels(for: .microphone) == .silence)
        _ = try await session.stop()
        let events = await collect(liveStream)
        #expect(eventKinds(events).contains(.buffer) == false)
    }
}

private enum LiveEventKind: Equatable, Sendable {
    case buffer
    case gapStarted
    case gapEnded
}

private func collect(
    _ stream: sending AsyncStream<LiveAudioEvent>
) async -> [LiveAudioEvent] {
    var events: [LiveAudioEvent] = []
    for await event in stream {
        events.append(event)
    }
    return events
}

private func eventKinds(_ events: [LiveAudioEvent]) -> [LiveEventKind] {
    events.map { event in
        switch event {
        case .buffer: .buffer
        case .gapStarted: .gapStarted
        case .gapEnded: .gapEnded
        }
    }
}

struct ActivityCounts: Equatable, Sendable {
    let begun: Int
    let ended: Int
}

actor FakeActivityManager: RecordingActivityManaging {
    private var begun = 0
    private var ended = 0

    func begin() { begun += 1 }
    func end() { ended += 1 }

    func counts() -> ActivityCounts {
        ActivityCounts(begun: begun, ended: ended)
    }
}

private actor FailingAfterOneWriteWriter: AudioTrackWriting {
    nonisolated var url: URL { underlying.url }
    private let underlying: TrackWriter
    private var writes = 0

    init(underlying: TrackWriter) {
        self.underlying = underlying
    }

    func write(_ buffer: sending AVAudioPCMBuffer) async throws {
        writes += 1
        if writes > 1 {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try await underlying.write(buffer)
    }

    func close() async throws -> TrackWriteSummary {
        try await underlying.close()
    }
}

private final class CapacitySequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int64]

    init(_ values: [Int64]) {
        self.values = values
    }

    func next() -> Int64 {
        lock.withLock {
            if values.count > 1 { return values.removeFirst() }
            return values[0]
        }
    }
}

private struct PersistentDiskProbeError: Error, LocalizedError {
    var errorDescription: String? { "disk capacity probe unavailable" }
}

private final class FailingCapacityProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var failures = 0

    var failureCount: Int {
        lock.withLock { failures }
    }

    func next() throws -> Int64 {
        try lock.withLock {
            calls += 1
            guard calls > 1 else { return 3_000_000_000 }
            failures += 1
            throw PersistentDiskProbeError()
        }
    }
}

private func waitUntil(
    timeout: Duration = .seconds(2),
    condition: @escaping @Sendable () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !(await condition()) {
        guard clock.now < deadline else {
            throw CocoaError(.coderReadCorrupt)
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private func inode(of url: URL) throws -> UInt64 {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try #require(
        (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
    )
}
