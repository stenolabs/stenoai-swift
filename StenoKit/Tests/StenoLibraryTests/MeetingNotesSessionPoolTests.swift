import StenoDomain
import Testing
@testable import StenoLibrary

@Suite("Meeting notes session pool")
struct MeetingNotesSessionPoolTests {
    @Test("restoration opens a fresh session while the removed editor stays disabled")
    @MainActor
    func restoresFreshSession() async throws {
        let id = MeetingID()
        let pool = MeetingNotesSessionPool(store: PoolNotesPersistence())
        let original = try #require(await pool.session(for: id))
        try await pool.prepareForMeetingRemoval(id)
        pool.completeMeetingRemoval(id)
        #expect(await pool.session(for: id) == nil)
        pool.completeMeetingRestoration(id)
        let restored = try #require(await pool.session(for: id))
        #expect(restored !== original)
        #expect(restored.canEdit)
        #expect(!original.canEdit)
    }

    @Test("removal preparation blocks the first later session acquisition")
    @MainActor
    func preparationBlocksFirstLaterSessionAcquisition() async throws {
        let meetingID = MeetingID()
        let persistence = PoolNotesPersistence()
        let pool = MeetingNotesSessionPool(store: persistence)

        try await pool.prepareForMeetingRemoval(meetingID)
        let session = await pool.session(for: meetingID)

        #expect(session == nil)

        pool.cancelMeetingRemoval(meetingID)
        let restored = try #require(await pool.session(for: meetingID))
        #expect(restored.canEdit)
    }

    @Test("an initial read already in flight joins removal and returns no active session")
    @MainActor
    func suspendedInitialReadJoinsRemoval() async throws {
        let meetingID = MeetingID()
        let persistence = BlockingNotesPersistence(notes: "Vorhandene Notiz")
        let checkpoint = PoolRemovalCheckpointBarrier()
        let pool = MeetingNotesSessionPool(
            store: persistence,
            afterRemovalMarkedPreparing: {
                await checkpoint.reachAndWait()
            }
        )

        let acquisition = Task { @MainActor in
            await pool.session(for: meetingID)
        }
        await persistence.waitUntilReadStarted()
        let preparation = Task { @MainActor in
            try await pool.prepareForMeetingRemoval(meetingID)
        }
        await checkpoint.waitUntilReached()

        await persistence.releaseRead()
        let acquiredSession = await acquisition.value
        #expect(acquiredSession == nil)

        await checkpoint.release()
        try await preparation.value
        pool.completeMeetingRemoval(meetingID)
        #expect(await pool.session(for: meetingID) == nil)
    }

    @Test("concurrent access shares one completely loaded session")
    @MainActor
    func concurrentAccessSharesOneLoadedSession() async throws {
        let meetingID = MeetingID()
        let persistence = BlockingNotesPersistence(notes: "Vorhandene Notiz")
        let pool = MeetingNotesSessionPool(store: persistence)

        let first = Task { @MainActor in
            await pool.session(for: meetingID)
        }
        await persistence.waitUntilReadStarted()
        let second = Task { @MainActor in
            await pool.session(for: meetingID)
        }

        await persistence.releaseRead()
        let firstSession = try #require(await first.value)
        let secondSession = try #require(await second.value)

        #expect(firstSession === secondSession)
        #expect(firstSession.text == "Vorhandene Notiz")
        #expect(await persistence.readCount() == 1)
    }

    @Test("meeting removal is forwarded and completion removes the cached session")
    @MainActor
    func meetingRemovalLifecycleIsForwardedAndCompletionEvictsSession() async throws {
        let meetingID = MeetingID()
        let persistence = PoolNotesPersistence()
        let pool = MeetingNotesSessionPool(
            store: persistence,
            autosaveDelay: .seconds(60)
        )
        let session = try #require(await pool.session(for: meetingID))

        session.update("Ungespeicherte Notiz")
        try await pool.prepareForMeetingRemoval(meetingID)

        #expect(await persistence.currentNotes() == "Ungespeicherte Notiz")
        #expect(!session.canEdit)

        pool.cancelMeetingRemoval(meetingID)
        #expect(session.canEdit)

        session.update("Letzter Stand")
        try await pool.prepareForMeetingRemoval(meetingID)
        pool.completeMeetingRemoval(meetingID)

        let replacement = await pool.session(for: meetingID)
        #expect(replacement == nil)

        session.update("Darf nicht wieder erscheinen")
        await session.flush()
        #expect(await persistence.currentNotes() == "Letzter Stand")
    }

    @Test("concurrent removal preparations await an already running write before completion")
    @MainActor
    func concurrentRemovalPreparationsAwaitRunningWriteBeforeCompletion() async throws {
        let meetingID = MeetingID()
        let persistence = SuspendedWriteNotesPersistence()
        let pool = MeetingNotesSessionPool(
            store: persistence,
            autosaveDelay: .zero
        )
        let session = try #require(await pool.session(for: meetingID))
        let probe = RemovalPreparationProbe()

        session.update("Ungespeicherte Notiz")
        await persistence.waitUntilWriteStarted()

        let firstPreparation = Task { @MainActor in
            try await pool.prepareForMeetingRemoval(meetingID)
            await probe.markFirstFinished()
        }
        while session.canEdit {
            await Task.yield()
        }

        let secondPreparation = Task { @MainActor in
            await probe.markSecondStarted()
            try await pool.prepareForMeetingRemoval(meetingID)
            let activeWritesAtCompletion = await persistence.activeWriteCount()
            pool.completeMeetingRemoval(meetingID)
            await probe.markSecondFinished()
            return activeWritesAtCompletion
        }
        await probe.waitUntilSecondStarted()
        try await Task.sleep(for: .milliseconds(20))

        #expect(!(await probe.firstDidFinish()))
        #expect(!(await probe.secondDidFinish()))

        await persistence.releaseWrites()
        try await firstPreparation.value
        let activeWritesAtCompletion = try await secondPreparation.value

        #expect(activeWritesAtCompletion == 0)
        #expect(await persistence.activeWriteCount() == 0)
    }
}

private actor PoolNotesPersistence: MeetingNotesPersistence {
    private var storedNotes: String?

    func notes(_ meetingID: MeetingID) async throws -> String? {
        storedNotes
    }

    func setNotes(_ meetingID: MeetingID, to notes: String?) async throws {
        storedNotes = notes
    }

    func currentNotes() -> String? {
        storedNotes
    }
}

private actor SuspendedWriteNotesPersistence: MeetingNotesPersistence {
    private var storedNotes: String?
    private var activeWrites = 0
    private var writeStarted = false
    private var writesReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var writeWaiters: [CheckedContinuation<Void, Never>] = []

    func notes(_ meetingID: MeetingID) async throws -> String? {
        storedNotes
    }

    func setNotes(_ meetingID: MeetingID, to notes: String?) async throws {
        activeWrites += 1
        writeStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        if !writesReleased {
            await withCheckedContinuation { continuation in
                writeWaiters.append(continuation)
            }
        }
        storedNotes = notes
        activeWrites -= 1
    }

    func waitUntilWriteStarted() async {
        guard !writeStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseWrites() {
        writesReleased = true
        let waiters = writeWaiters
        writeWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func activeWriteCount() -> Int {
        activeWrites
    }
}

private actor RemovalPreparationProbe {
    private var firstFinished = false
    private var secondStarted = false
    private var secondFinished = false
    private var secondStartWaiters: [CheckedContinuation<Void, Never>] = []

    func markFirstFinished() {
        firstFinished = true
    }

    func markSecondStarted() {
        secondStarted = true
        let waiters = secondStartWaiters
        secondStartWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitUntilSecondStarted() async {
        guard !secondStarted else { return }
        await withCheckedContinuation { continuation in
            secondStartWaiters.append(continuation)
        }
    }

    func markSecondFinished() {
        secondFinished = true
    }

    func firstDidFinish() -> Bool {
        firstFinished
    }

    func secondDidFinish() -> Bool {
        secondFinished
    }
}

private actor PoolRemovalCheckpointBarrier {
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

private actor BlockingNotesPersistence: MeetingNotesPersistence {
    private let storedNotes: String
    private var reads = 0
    private var readStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var blockedRead: CheckedContinuation<Void, Never>?

    init(notes: String) {
        storedNotes = notes
    }

    func notes(_ meetingID: MeetingID) async throws -> String? {
        reads += 1
        readStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            blockedRead = continuation
        }
        return storedNotes
    }

    func setNotes(_ meetingID: MeetingID, to notes: String?) async throws {}

    func waitUntilReadStarted() async {
        guard !readStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseRead() {
        blockedRead?.resume()
        blockedRead = nil
    }

    func readCount() -> Int {
        reads
    }
}
