import Foundation
import StenoDomain
import StenoLibrary
import Testing
@testable import steno_macos

@Suite("Short recording decisions")
struct ShortRecordingDecisionTests {
    @Test("only recordings shorter than fifteen seconds wait", arguments: [0.0, 3, 5, 10, 14.999, 15, 30])
    func boundary(duration: Double) {
        #expect(ShortRecordingDecision.requiresConfirmation(duration: duration) == (duration < 15))
    }

    @Test("short capture persists its exact job without queueing and a longer capture clears it")
    func deferredJobSurvivesRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("short-recording-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try Library.open(at: root)
        let meeting = try await library.createMeeting(title: "Synthetic short recording", status: .ready)
        let jobs = try JobStore(layout: library.layout)
        let store = ShortRecordingDecisionStore(layout: library.layout)
        let job = Job.finalASR(for: meeting)
        let queued = try await store.schedule(job, duration: 5, continuesExistingMeeting: true, jobStore: jobs)
        #expect(!queued)
        #expect(try await jobs.list().isEmpty)
        let reopened = ShortRecordingDecisionStore(layout: try Library.open(at: root).layout)
        let decision = try #require(try reopened.load(meeting.id))
        #expect(decision.job == job)
        #expect(decision.continuesExistingMeeting)
        #expect(decision.duration == 5)
        let longer = Job.finalASR(for: meeting)
        let queuedLonger = try await reopened.schedule(longer, duration: 15, continuesExistingMeeting: true, jobStore: jobs)
        #expect(queuedLonger)
        #expect(try reopened.load(meeting.id) == nil)
        #expect(try await jobs.list().map(\.id) == [longer.id])
    }

    @Test("a stale confirmation cannot remove a newer short recording decision")
    func replacementDecisionSurvivesStaleRemoval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("short-recording-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try Library.open(at: root)
        let meeting = try await library.createMeeting(title: "Synthetic replacement", status: .ready)
        let store = ShortRecordingDecisionStore(layout: library.layout)
        let first = Job.finalASR(for: meeting)
        let second = ShortRecordingDecision(job: Job.finalASR(for: meeting), duration: 3, continuesExistingMeeting: true)
        try store.save(ShortRecordingDecision(job: first, duration: 5, continuesExistingMeeting: false))
        try store.save(second)
        try store.remove(meeting.id, expectedJobID: first.id)
        #expect(try store.load(meeting.id) == second)
    }

    @Test("a transcription requested elsewhere consumes the deferred prompt")
    func anotherTranscriptionConsumesDecision() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("short-recording-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try Library.open(at: root)
        let meeting = try await library.createMeeting(title: "Synthetic manual retry", status: .ready)
        let store = ShortRecordingDecisionStore(layout: library.layout)
        let jobs = try JobStore(layout: library.layout)
        let deferred = Job(kind: .finalASR, meetingID: meeting.id, createdAt: Date(timeIntervalSince1970: 100))
        try store.save(ShortRecordingDecision(job: deferred, duration: 5, continuesExistingMeeting: false))
        let manual = Job(kind: .finalASR, meetingID: meeting.id, createdAt: Date(timeIntervalSince1970: 101))
        try await jobs.enqueue(manual)
        #expect(try await store.pending(meeting.id, jobStore: jobs) == nil)
        #expect(try store.load(meeting.id) == nil)
        #expect(try await jobs.list().map(\.id) == [manual.id])
    }
}
