import Foundation
import StenoDomain
import StenoLibrary
import StenoTranscription

actor RecordingFinalizer {
    private struct Prepared: Sendable {
        let revision: TranscriptRevision?
        let job: Job
    }

    private var prepared: [MeetingID: Prepared] = [:]
    private var inFlight: [MeetingID: Task<Void, Error>] = [:]
    private var completed: Set<MeetingID> = []

    func finalize(
        meeting: Meeting,
        output: TranscriptOutput?,
        recordedDuration: TimeInterval? = nil,
        library: Library,
        jobStore: JobStore
    ) async throws {
        let meetingID = meeting.id
        if completed.contains(meetingID) {
            return
        }
        if let inFlight = inFlight[meetingID] {
            try await inFlight.value
            return
        }

        let work = prepared[meetingID] ?? Self.prepare(
            meeting: meeting,
            output: recordedDuration.map(ShortRecordingDecision.requiresConfirmation) == true ? nil : output
        )
        prepared[meetingID] = work

        let task = Task {
            if let revision = work.revision {
                try await Self.persist(revision, in: library)
            }
            let decisions = ShortRecordingDecisionStore(layout: library.layout)
            if let recordedDuration, ShortRecordingDecision.requiresConfirmation(duration: recordedDuration) {
                try decisions.save(ShortRecordingDecision(
                    job: work.job, duration: recordedDuration, continuesExistingMeeting: false
                ))
            } else {
                try await Self.persist(work.job, in: jobStore)
                try decisions.remove(meetingID)
            }
        }
        inFlight[meetingID] = task

        do {
            try await task.value
            completed.insert(meetingID)
            prepared[meetingID] = nil
            inFlight[meetingID] = nil
        } catch {
            inFlight[meetingID] = nil
            throw error
        }
    }

    private static func prepare(
        meeting: Meeting,
        output: TranscriptOutput?
    ) -> Prepared {
        let revision: TranscriptRevision?
        if let output, !output.blocks.isEmpty {
            revision = TranscriptMapper.revision(
                from: output,
                meetingID: meeting.id,
                origin: .liveProvisional
            )
        } else {
            revision = nil
        }
        return Prepared(
            revision: revision,
            job: Job.finalASR(for: meeting)
        )
    }

    private static func persist(
        _ revision: TranscriptRevision,
        in library: Library
    ) async throws {
        let url = library.layout.revision(
            revision.meetingID,
            revisionID: revision.id
        )
        if FileManager.default.fileExists(atPath: url.path) {
            let existing = try await library.loadRevision(
                revision.id,
                meetingID: revision.meetingID
            )
            guard existing == revision else {
                throw RecordingFinalizerError.conflictingArtifact(url)
            }
            return
        }
        _ = try await library.appendRevision(revision)
    }

    private static func persist(_ job: Job, in jobStore: JobStore) async throws {
        let url = jobStore.layout.job(job.id)
        if FileManager.default.fileExists(atPath: url.path) {
            let existing = try await jobStore.load(job.id)
            guard existing.id == job.id,
                  existing.kind == job.kind,
                  existing.meetingID == job.meetingID
            else {
                throw RecordingFinalizerError.conflictingArtifact(url)
            }
            return
        }
        try await jobStore.enqueue(job)
    }
}

private enum RecordingFinalizerError: LocalizedError {
    case conflictingArtifact(URL)

    var errorDescription: String? {
        switch self {
        case .conflictingArtifact(let url):
            "A different recording result already exists at \(url.lastPathComponent)."
        }
    }
}
