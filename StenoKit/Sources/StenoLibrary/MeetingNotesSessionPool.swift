import Foundation
import StenoDomain

/// Keeps one notes editing session per meeting for a whole app process.
///
/// Multiple windows and platform surfaces therefore join the same load and
/// autosave state instead of letting separate editors overwrite one another.
@MainActor
public final class MeetingNotesSessionPool {
    private let store: any MeetingNotesPersistence
    private let autosaveDelay: Duration
    private let afterRemovalMarkedPreparing: @MainActor @Sendable () async -> Void
    private var sessions: [MeetingID: MeetingNotesEditingSession] = [:]
    private var removalStates: [MeetingID: RemovalState] = [:]

    public init(
        store: any MeetingNotesPersistence,
        autosaveDelay: Duration = .seconds(1)
    ) {
        self.store = store
        self.autosaveDelay = autosaveDelay
        afterRemovalMarkedPreparing = {}
    }

    init(
        store: any MeetingNotesPersistence,
        autosaveDelay: Duration = .seconds(1),
        afterRemovalMarkedPreparing: @escaping @MainActor @Sendable () async -> Void
    ) {
        self.store = store
        self.autosaveDelay = autosaveDelay
        self.afterRemovalMarkedPreparing = afterRemovalMarkedPreparing
    }

    public func session(for meetingID: MeetingID) async -> MeetingNotesEditingSession? {
        guard removalStates[meetingID] == nil else { return nil }
        if let session = sessions[meetingID] {
            await session.load()
            return removalStates[meetingID] == nil ? session : nil
        }

        let session = MeetingNotesEditingSession(
            meetingID: meetingID,
            store: store,
            autosaveDelay: autosaveDelay
        )
        sessions[meetingID] = session
        await session.load()
        return removalStates[meetingID] == nil ? session : nil
    }

    public func prepareForMeetingRemoval(_ meetingID: MeetingID) async throws {
        switch removalStates[meetingID] {
        case .completed:
            return
        case .preparing:
            try await sessions[meetingID]?.prepareForMeetingRemoval()
            return
        case nil:
            removalStates[meetingID] = .preparing
        }
        await afterRemovalMarkedPreparing()
        try await sessions[meetingID]?.prepareForMeetingRemoval()
    }

    public func cancelMeetingRemoval(_ meetingID: MeetingID) {
        guard removalStates[meetingID] == .preparing else { return }
        removalStates[meetingID] = nil
        sessions[meetingID]?.cancelMeetingRemoval()
    }

    public func completeMeetingRemoval(_ meetingID: MeetingID) {
        removalStates[meetingID] = .completed
        sessions[meetingID]?.completeMeetingRemoval()
        sessions[meetingID] = nil
    }

    /// A successful restore permits a fresh editor without reactivating any
    /// editor that still holds the removed session.
    public func completeMeetingRestoration(_ meetingID: MeetingID) {
        guard removalStates[meetingID] == .completed else { return }
        removalStates[meetingID] = nil
    }

    private enum RemovalState: Equatable {
        case preparing
        case completed
    }
}
