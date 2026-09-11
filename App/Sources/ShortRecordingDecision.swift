import Foundation
import StenoDomain
import StenoLibrary

/// A deferred final-ASR job keeps its original provider and language pins.
/// It lives with the meeting, so Trash/restore and app restarts preserve it.
struct ShortRecordingDecision: Codable, Equatable {
    static let minimumAutomaticDuration: TimeInterval = 15
    let job: Job
    let duration: TimeInterval
    let continuesExistingMeeting: Bool

    static func requiresConfirmation(duration: TimeInterval) -> Bool {
        duration.isFinite && duration >= 0 && duration < minimumAutomaticDuration
    }
}

struct ShortRecordingDecisionStore {
    let layout: LibraryLayout

    func pending(_ id: MeetingID, jobStore: JobStore) async throws -> ShortRecordingDecision? {
        guard let decision = try load(id) else { return nil }
        let alreadyRequested = try await jobStore.list().contains {
            $0.meetingID == id && $0.kind == .finalASR
                && $0.processingGenerationID == decision.job.processingGenerationID
                && $0.createdAt >= decision.job.createdAt
        }
        if alreadyRequested {
            try remove(id, expectedJobID: decision.job.id)
            return nil
        }
        return decision
    }

    /// Returns true only when processing was actually enqueued.
    func schedule(_ job: Job, duration: TimeInterval?, continuesExistingMeeting: Bool, jobStore: JobStore) async throws -> Bool {
        if let duration, ShortRecordingDecision.requiresConfirmation(duration: duration) {
            try save(ShortRecordingDecision(job: job, duration: duration, continuesExistingMeeting: continuesExistingMeeting))
            return false
        }
        try await jobStore.enqueue(job)
        try remove(job.meetingID)
        return true
    }

    private func url(_ id: MeetingID) -> URL {
        layout.meetingDirectory(id).appendingPathComponent("short-recording-decision.json")
    }

    func load(_ id: MeetingID) throws -> ShortRecordingDecision? {
        let file = url(id)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let decision = try JSONDecoder().decode(ShortRecordingDecision.self, from: Data(contentsOf: file))
        guard decision.job.meetingID == id, decision.job.kind == .finalASR else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return decision
    }

    func save(_ decision: ShortRecordingDecision) throws {
        try AtomicFile.write(try JSONEncoder().encode(decision), to: url(decision.job.meetingID))
    }

    func remove(_ id: MeetingID, expectedJobID: JobID? = nil) throws {
        if let expectedJobID, try load(id)?.job.id != expectedJobID { return }
        let file = url(id)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
}
