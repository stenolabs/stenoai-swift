import Foundation
import StenoDomain
import StenoLibrary
import StenoPipeline
import Testing
@testable import Steno

@Suite("iOS app model meeting deletion", .serialized)
@MainActor
struct AppModelMeetingDeletionTests {
    @Test("undo restores original notes without reviving cancelled jobs or old editors")
    func undoRestoresMeeting() async throws {
        let fixture = try await MeetingDeletionFixture.make()
        defer { fixture.remove() }
        let oldEditor = try #require(await fixture.app.notesSession(for: fixture.meeting.id))
        oldEditor.update("Synthetic note to preserve")
        try await fixture.jobStore.enqueue(Job(kind: .finalASR, meetingID: fixture.meeting.id))
        _ = try await fixture.app.deleteMeeting(fixture.meeting.id)
        #expect(fixture.app.pendingTrashUndo?.meetingID == fixture.meeting.id)
        #expect(try await fixture.app.restoreLastTrashedMeeting() == fixture.meeting.id)
        #expect(fixture.app.pendingTrashUndo == nil)
        #expect(!fixture.app.removedMeetingIDs.contains(fixture.meeting.id))
        #expect(try await fixture.jobStore.list().isEmpty)
        #expect(!oldEditor.canEdit)
        let restoredEditor = try #require(await fixture.app.notesSession(for: fixture.meeting.id))
        #expect(restoredEditor !== oldEditor)
        #expect(restoredEditor.canEdit)
        #expect(try await MeetingNotesStore(layout: fixture.library.layout).notes(fixture.meeting.id) == "Synthetic note to preserve")
    }

    @Test("undo refuses an occupied destination and preserves the receipt for retry")
    func undoDoesNotOverwrite() async throws {
        let fixture = try await MeetingDeletionFixture.make()
        defer { fixture.remove() }
        _ = try await fixture.app.deleteMeeting(fixture.meeting.id)
        let destination = fixture.library.layout.meetingDirectory(fixture.meeting.id)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        await #expect(throws: CocoaError.self) {
            _ = try await fixture.app.restoreLastTrashedMeeting()
        }
        #expect(fixture.app.pendingTrashUndo != nil)
        try FileManager.default.removeItem(at: destination)
        #expect(try await fixture.app.restoreLastTrashedMeeting() == fixture.meeting.id)
    }

    @Test("deletion cancels queued work, trashes once, and publishes the removal")
    func deletionCancelsWorkAndPublishesRemoval() async throws {
        let fixture = try await MeetingDeletionFixture.make()
        defer { fixture.remove() }
        let job = Job(kind: .finalASR, meetingID: fixture.meeting.id)
        try await fixture.jobStore.enqueue(job)
        let notes = try #require(await fixture.app.notesSession(for: fixture.meeting.id))
        notes.update("Keep this until the folder moves")
        _ = try #require(
            await fixture.app.loadMeetingReviewPublication(for: fixture.meeting.id)
        )

        let outcome = try await fixture.app.deleteMeeting(fixture.meeting.id)

        #expect(outcome.cleanupWarning == nil)
        #expect(fixture.trasher.callCount == 1)
        #expect(fixture.trasher.observedCancelledJob)
        #expect(!fixture.app.meetings.contains { $0.id == fixture.meeting.id })
        #expect(fixture.app.removedMeetingIDs.contains(fixture.meeting.id))
        #expect(try await fixture.jobStore.list().isEmpty)
        #expect(!notes.canEdit)
        #expect(fixture.app.meetingReviewPublication(for: fixture.meeting.id) == nil)
    }

    @Test("a trash failure keeps the meeting visible and releases its notes session")
    func trashFailureKeepsMeetingAndReleasesNotes() async throws {
        let fixture = try await MeetingDeletionFixture.make(trashFails: true)
        defer { fixture.remove() }
        let notes = try #require(await fixture.app.notesSession(for: fixture.meeting.id))
        notes.update("Still editable after a failed move")

        await #expect(throws: MeetingDeletionFixtureError.trashFailed) {
            try await fixture.app.deleteMeeting(fixture.meeting.id)
        }

        #expect(fixture.trasher.callCount == 1)
        #expect(fixture.app.meetings.contains { $0.id == fixture.meeting.id })
        #expect(!fixture.app.removedMeetingIDs.contains(fixture.meeting.id))
        #expect(notes.canEdit)
        notes.update("Retry remains possible")
        await notes.flush()
        #expect(
            try await MeetingNotesStore(layout: fixture.library.layout)
                .notes(fixture.meeting.id) == "Retry remains possible"
        )
    }

    @Test("the runtime guard rejects only the meeting currently being recorded")
    func activeRecordingMeetingIsRejected() throws {
        let activeMeetingID = MeetingID()

        #expect(throws: MeetingDeletionError.activeRecording) {
            try MeetingDeletionRuntimeGuard.requireDeletionAllowed(
                meetingID: activeMeetingID,
                recordingIsActive: true,
                recordingMeetingID: activeMeetingID
            )
        }

        try MeetingDeletionRuntimeGuard.requireDeletionAllowed(
            meetingID: MeetingID(),
            recordingIsActive: true,
            recordingMeetingID: activeMeetingID
        )
    }

    @Test("deletion held at Trash excludes a retranscription request before preflight")
    func deletionAtTrashExcludesRetranscription() async throws {
        let fixture = try await MeetingDeletionFixture.make(
            suspendAtTrash: true,
            includeTranscript: true
        )
        defer { fixture.remove() }
        let barrier = try #require(fixture.trashBarrier)
        let preflight = try await fixture.app.reportPreflight(for: fixture.meeting.id)
        let operationMessage =
            AppModelLibraryOperationError.operationInProgress.localizedDescription
        let deletion = Task { @MainActor in
            try await fixture.app.deleteMeeting(fixture.meeting.id)
        }
        await barrier.waitUntilReached()

        do {
            try await fixture.app.requestRetranscription(meetingID: fixture.meeting.id)
            Issue.record("Retranscription passed the active deletion boundary")
        } catch {
            #expect(error.localizedDescription == operationMessage)
        }

        await fixture.app.retryFinalASRWithApple(Job(
            kind: .finalASR,
            meetingID: fixture.meeting.id,
            status: .failed
        ))
        #expect(
            fixture.app.startupFailure
                == IOSActionNotice.appleRetryQueue(operationMessage)
                    .compatibilityMessage
        )

        #expect(
            await fixture.app.requestMeetingDiarization(for: fixture.meeting.id)
                == .failed(operationMessage)
        )
        #expect(
            await fixture.app.adoptPendingMeetingDiarization(
                for: fixture.meeting.id,
                expectedCurrentRevisionID: preflight.revisionID
            ) == .failed(operationMessage)
        )

        do {
            _ = try await fixture.app.requestMeetingMinutes(
                meetingID: fixture.meeting.id,
                textModelEndpointID: nil,
                preflight: preflight
            )
            Issue.record("Meeting minutes passed the active deletion boundary")
        } catch {
            #expect(error.localizedDescription == operationMessage)
        }
        #expect(try await fixture.jobStore.list().isEmpty)

        await barrier.release()
        _ = try await deletion.value
    }
}

@MainActor
private struct MeetingDeletionFixture {
    let root: URL
    let library: Library
    let meeting: Meeting
    let jobStore: JobStore
    let app: AppModel
    let trasher: MeetingDeletionTrasherProbe
    let trashBarrier: MeetingDeletionTrashBarrier?

    static func make(
        trashFails: Bool = false,
        suspendAtTrash: Bool = false,
        includeTranscript: Bool = false
    ) async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "Steno-AppModelMeetingDeletionTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let libraryRoot = root.appending(path: "Library", directoryHint: .isDirectory)
        let trashRoot = root.appending(path: "Trash", directoryHint: .isDirectory)
        let library = try Library.open(at: libraryRoot)
        let meeting = try await library.createMeeting(
            title: "Planning",
            status: .ready
        )
        if includeTranscript {
            _ = try await library.appendRevision(TranscriptRevision(
                meetingID: meeting.id,
                origin: .legacyImport,
                turns: [TranscriptTurn(
                    start: 0,
                    end: 1,
                    segments: [TranscriptSegment(
                        text: "Agenda",
                        start: 0,
                        end: 1,
                        words: []
                    )]
                )]
            ))
        }
        let jobStore = try JobStore(layout: library.layout)
        let coordinator = PipelineCoordinator(
            library: library,
            jobStore: jobStore,
            providers: [:],
            locale: Locale(identifier: "de-DE")
        )
        let runtime = PipelineRuntime(
            library: library,
            jobStore: jobStore,
            coordinator: coordinator
        )
        let trashBarrier = suspendAtTrash ? MeetingDeletionTrashBarrier() : nil
        let trasher = MeetingDeletionTrasherProbe(
            jobStore: jobStore,
            trashRoot: trashRoot,
            shouldFail: trashFails,
            barrier: trashBarrier
        )
        let app = AppModel(
            prepareLibraryBackup: { _, _ in },
            refreshLanguage: { _ in },
            startPipeline: { _, _, _ in runtime },
            meetingTrasher: { library, meetingID in
                try await trasher.trash(library: library, meetingID: meetingID)
            },
            libraryURL: libraryRoot
        )
        await app.bootstrap()
        return Self(
            root: root,
            library: library,
            meeting: meeting,
            jobStore: jobStore,
            app: app,
            trasher: trasher,
            trashBarrier: trashBarrier
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class MeetingDeletionTrasherProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let jobStore: JobStore
    private let trashRoot: URL
    private let shouldFail: Bool
    private let barrier: MeetingDeletionTrashBarrier?
    private var calls = 0
    private var sawCancelledJob = false

    init(
        jobStore: JobStore,
        trashRoot: URL,
        shouldFail: Bool,
        barrier: MeetingDeletionTrashBarrier?
    ) {
        self.jobStore = jobStore
        self.trashRoot = trashRoot
        self.shouldFail = shouldFail
        self.barrier = barrier
    }

    var callCount: Int {
        lock.withLock { calls }
    }

    var observedCancelledJob: Bool {
        lock.withLock { sawCancelledJob }
    }

    func trash(library: Library, meetingID: MeetingID) async throws -> URL? {
        lock.withLock { calls += 1 }
        if shouldFail { throw MeetingDeletionFixtureError.trashFailed }
        let jobs = try await jobStore.list().filter { $0.meetingID == meetingID }
        lock.withLock {
            sawCancelledJob = jobs.contains { $0.status == .cancelled }
        }
        await barrier?.reachAndWait()

        try FileManager.default.createDirectory(
            at: trashRoot,
            withIntermediateDirectories: true
        )
        let destination = trashRoot.appendingPathComponent(meetingID.description)
        try FileManager.default.moveItem(
            at: library.layout.meetingDirectory(meetingID),
            to: destination
        )
        return destination
    }
}

private actor MeetingDeletionTrashBarrier {
    private var reached = false
    private var released = false
    private var reachWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func reachAndWait() async {
        reached = true
        let waiters = reachWaiters
        reachWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilReached() async {
        guard !reached else { return }
        await withCheckedContinuation { continuation in
            reachWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private enum MeetingDeletionFixtureError: Error, Equatable {
    case trashFailed
}
