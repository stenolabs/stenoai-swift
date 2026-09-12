import Observation
import StenoDomain

/// Window-local navigation and inspector state.
///
/// Each `ContentView` instance owns its own router, so two iPad windows never
/// share a selection or an inspector's open/closed state - only the library
/// data behind them (`AppModel`) is process-wide.
@MainActor
@Observable
final class NavigationRouter {
    var selection: SidebarItem? = .home
    var isInspectorPresented = false
    var meetingActionAlert: MeetingActionAlert?
    private(set) var transcriptSearchFocusRequest: UInt64 = 0

    var selectedMeetingID: MeetingID? {
        guard case .meeting(let id) = selection else { return nil }
        return id
    }

    func select(_ item: SidebarItem) {
        selection = item
    }

    func reconcileSelectedMeeting(removedMeetingIDs: Set<MeetingID>) {
        guard let selectedMeetingID,
              removedMeetingIDs.contains(selectedMeetingID)
        else { return }
        select(.recording)
    }

    /// Applies an asynchronous deletion result to this window without
    /// revoking a route the user chose while the deletion was in flight.
    func applyMeetingDeletionCompletion(
        meetingID: MeetingID,
        cleanupWarning: String?
    ) {
        if selectedMeetingID == meetingID {
            select(.recording)
        }
        if let cleanupWarning {
            meetingActionAlert = .cleanupWarning(cleanupWarning)
        }
    }

    func applyMeetingDeletionFailure(_ message: String) {
        meetingActionAlert = .deletionFailure(message)
    }

    func showInspector() {
        isInspectorPresented = true
    }

    func toggleInspector() {
        isInspectorPresented.toggle()
    }

    /// An event counter rather than a Boolean: every Cmd-F request remains
    /// observable, including a later request after search focus moved away.
    func requestTranscriptSearchFocus() {
        transcriptSearchFocusRequest += 1
    }
}
