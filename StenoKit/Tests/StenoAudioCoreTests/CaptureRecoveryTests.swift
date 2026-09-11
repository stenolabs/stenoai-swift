@preconcurrency import AVFAudio
import Foundation
import StenoDomain
import StenoLibrary
@testable import StenoAudioCore
import Testing

@Suite("Capture recovery")
struct CaptureRecoveryTests {
    private func makeLibrary() throws -> (Library, JobStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-recovery-\(UUID())", isDirectory: true)
        let library = try Library.open(at: root)
        let jobStore = try JobStore(layout: library.layout)
        return (library, jobStore, root)
    }

    private func writeCaptureFile(
        _ library: Library,
        meetingID: MeetingID,
        track: AudioTrack,
        seconds: Double = 0.25
    ) throws -> URL {
        let directory = library.layout.captureDirectory(meetingID)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let url = directory.appendingPathComponent(
            "\(meetingID)-\(track.rawValue)-\(UUID()).caf"
        )
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let frames = AVAudioFrameCount(16_000 * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        try file.write(from: buffer)
        return url
    }

    @Test("newly adopted audio is not hidden by a previously finished transcription")
    func adoptedAudioQueuesFreshJob() async throws {
        let (library, jobStore, root) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try await library.createMeeting(title: "Synthetic recovery", status: .interrupted)
        let previous = Job.finalASR(for: meeting)
        try await jobStore.enqueue(previous)
        _ = try await jobStore.transition(previous.id, to: .running)
        _ = try await jobStore.transition(previous.id, to: .finished)
        _ = try writeCaptureFile(library, meetingID: meeting.id, track: .system)
        _ = try await CaptureRecovery.run(library: library, jobStore: jobStore)
        let jobs = try await jobStore.list()
        #expect(jobs.count == 2)
        #expect(jobs.contains { $0.id != previous.id && $0.status == .queued })
    }

    @Test("stop recovery can adopt before the caller schedules transcription")
    func callerOwnsScheduling() async throws {
        let (library, jobStore, root) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try await library.createMeeting(title: "Synthetic recovery", status: .interrupted)
        _ = try writeCaptureFile(library, meetingID: meeting.id, track: .system)
        let report = try await CaptureRecovery.run(library: library, jobStore: jobStore, onlyMeetingID: meeting.id, scheduleJobs: false)
        #expect(report.failures.isEmpty)
        #expect(report.adoptedMeetings.count == 1)
        #expect(try await jobStore.list().isEmpty)
        #expect(try await library.listMediaAssets(meetingID: meeting.id).count == 1)
        // Simulate a restart after adoption but before the caller enqueues.
        let restarted = try await CaptureRecovery.run(library: library, jobStore: jobStore)
        #expect(restarted.failures.isEmpty)
        #expect(try await jobStore.list().count == 1)
    }

    @Test("sweep without assets enqueues nothing, adoption registers and queues")
    func adoptionAfterHardCrash() async throws {
        let (library, jobStore, root) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let plan = TranscriptionPlan(
            liveProviderID: .apple,
            finalProviderID: .parakeetTDTv3
        )
        let sourceLocale = try MeetingSourceLocale(
            localeIdentifier: "de-DE",
            origin: .explicit
        )
        let meeting = try await library.createMeeting(
            title: "Killed",
            status: .recording,
            sourceLocale: sourceLocale,
            transcriptionPlan: plan
        )
        _ = try writeCaptureFile(library, meetingID: meeting.id, track: .microphone)
        _ = try writeCaptureFile(library, meetingID: meeting.id, track: .system)

        let interrupted = try await RecoverySweep.run(
            library: library,
            jobStore: jobStore
        )
        #expect(interrupted == [meeting.id])
        #expect(try await jobStore.list().isEmpty)

        let report = try await CaptureRecovery.run(
            library: library,
            jobStore: jobStore
        )
        let adopted = report.adoptedMeetings
        #expect(adopted.count == 1)
        #expect(adopted[0].adoptedTracks.sorted { $0.rawValue < $1.rawValue }
            == [.microphone, .system])

        let assets = try await library.listMediaAssets(meetingID: meeting.id)
        #expect(assets.map(\.kind).sorted { $0.rawValue < $1.rawValue }
            == [.micTrack, .systemTrack])
        let jobs = try await jobStore.list()
        #expect(jobs.count == 1)
        #expect(jobs[0].kind == .finalASR && jobs[0].status == .queued)
        #expect(jobs[0].transcriptionProviderID == .parakeetTDTv3)
        #expect(jobs[0].localeIdentifier == "de-DE")

        let captureLeftovers = (try? FileManager.default.contentsOfDirectory(
            at: library.layout.captureDirectory(meeting.id),
            includingPropertiesForKeys: nil
        )) ?? []
        #expect(captureLeftovers.isEmpty)
    }

    @Test("adoption reactivates an existing failed finalASR job")
    func reactivatesFailedJob() async throws {
        let (library, jobStore, root) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let meeting = try await library.createMeeting(
            title: "Killed",
            status: .interrupted
        )
        let job = Job(kind: .finalASR, meetingID: meeting.id)
        try await jobStore.enqueue(job)
        _ = try await jobStore.transition(job.id, to: .running)
        _ = try await jobStore.transition(
            job.id,
            to: .failed,
            errorMessage: "has no media assets"
        )
        _ = try writeCaptureFile(library, meetingID: meeting.id, track: .microphone)

        _ = try await CaptureRecovery.run(library: library, jobStore: jobStore)

        let jobs = try await jobStore.list()
        #expect(jobs.count == 1)
        #expect(jobs[0].status == .queued)
    }

    @Test("meetings without capture files are left alone")
    func ignoresMeetingsWithoutCapture() async throws {
        let (library, jobStore, root) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try await library.createMeeting(title: "Clean", status: .interrupted)
        let report = try await CaptureRecovery.run(
            library: library,
            jobStore: jobStore
        )
        #expect(report.adoptedMeetings.isEmpty)
        #expect(report.failures.isEmpty)
        #expect(try await jobStore.list().isEmpty)
    }

    @Test("a corrupt meeting does not block recovery of another meeting")
    func corruptMeetingIsIsolated() async throws {
        let (library, jobStore, root) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let corrupt = try await library.createMeeting(
            title: "Corrupt",
            status: .interrupted
        )
        let recoverable = try await library.createMeeting(
            title: "Recoverable",
            status: .interrupted
        )
        let corruptCapture = try writeCaptureFile(
            library,
            meetingID: corrupt.id,
            track: .microphone
        )
        _ = try writeCaptureFile(
            library,
            meetingID: recoverable.id,
            track: .microphone
        )
        try Data("{".utf8).write(
            to: library.layout.meetingMetadata(corrupt.id)
        )

        let report = try await CaptureRecovery.run(
            library: library,
            jobStore: jobStore
        )

        #expect(report.adoptedMeetings.map(\.meetingID) == [recoverable.id])
        #expect(report.failures.contains {
            $0.meetingID == corrupt.id && $0.stage == .meetingMetadata
        })
        #expect(FileManager.default.fileExists(atPath: corruptCapture.path))
        #expect(
            try await library.listMediaAssets(meetingID: recoverable.id).count == 1
        )
    }

    @Test("an unreadable capture file does not block another track")
    func unreadableCaptureFileIsIsolated() async throws {
        let (library, jobStore, root) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let meeting = try await library.createMeeting(
            title: "Partly recoverable",
            status: .interrupted
        )
        let directory = library.layout.captureDirectory(meeting.id)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let unreadable = directory.appendingPathComponent(
            "\(meeting.id)-microphone-\(UUID()).caf"
        )
        try Data([0x00, 0x01, 0x02]).write(to: unreadable)
        _ = try writeCaptureFile(
            library,
            meetingID: meeting.id,
            track: .system
        )

        let report = try await CaptureRecovery.run(
            library: library,
            jobStore: jobStore
        )

        #expect(report.adoptedMeetings == [
            CaptureRecovery.AdoptedMeeting(
                meetingID: meeting.id,
                adoptedTracks: [.system]
            ),
        ])
        #expect(report.failures.contains {
            $0.meetingID == meeting.id
                && $0.fileName == unreadable.lastPathComponent
                && $0.stage == .captureFile
        })
        #expect(FileManager.default.fileExists(atPath: unreadable.path))
        #expect(try await jobStore.list().isEmpty)
    }

    @Test("a capture file set aside during start is never adopted as a track")
    func ignoresSetAsideCaptureFiles() {
        let live = "01a03d4c-microphone-911619D3.caf"
        let setAside = "01a03d4c-microphone-911619D3.caf.discarded"

        #expect(CaptureRecovery.trackFromCaptureFileName(live) == .microphone)
        // The user was told this track was not recorded. Adopting it after a
        // later crash would hand back a recording that was never claimed.
        #expect(CaptureRecovery.trackFromCaptureFileName(setAside) == nil)
    }

    @Test("a capture file without audio is reported instead of adopted")
    func doesNotAdoptAnEmptyCaptureFile() async throws {
        let (library, jobStore, root) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try await library.createMeeting(
            title: "Empty",
            status: .interrupted
        )
        // What an abandoned track leaves behind when setting it aside failed:
        // a correctly named file that never received a single frame.
        let empty = try writeCaptureFile(
            library,
            meetingID: meeting.id,
            track: .microphone,
            seconds: 0
        )
        _ = try writeCaptureFile(
            library,
            meetingID: meeting.id,
            track: .system
        )

        let report = try await CaptureRecovery.run(
            library: library,
            jobStore: jobStore
        )

        let adopted = try #require(report.adoptedMeetings.first)
        #expect(adopted.adoptedTracks == [.system])
        #expect(report.failures.contains {
            $0.fileName == empty.lastPathComponent
        })
    }
}
