import StenoDomain
import Testing
@testable import Steno

@MainActor
@Suite("Navigation router")
struct NavigationRouterTests {
    @Test("language models selection is independent for each window router")
    func languageModelsSelectionIsWindowLocal() {
        let first = NavigationRouter()
        let second = NavigationRouter()

        first.selection = .languageModels

        #expect(first.selection == .languageModels)
        #expect(second.selection == .home)
    }

    @Test("routers do not share selection or inspector state")
    func routersDoNotShareWindowState() {
        let first = NavigationRouter()
        let second = NavigationRouter()
        let id = MeetingID()

        first.select(.meeting(id))
        first.showInspector()
        second.select(.languageModels)

        #expect(first.selection == .meeting(id))
        #expect(first.selectedMeetingID == id)
        #expect(first.isInspectorPresented)
        #expect(second.selection == .languageModels)
        #expect(second.selectedMeetingID == nil)
        #expect(!second.isInspectorPresented)
    }

    @Test("inspector toggling stays window local")
    func inspectorToggleIsWindowLocal() {
        let first = NavigationRouter()
        let second = NavigationRouter()

        first.toggleInspector()

        #expect(first.isInspectorPresented)
        #expect(!second.isInspectorPresented)

        first.toggleInspector()

        #expect(!first.isInspectorPresented)
        #expect(!second.isInspectorPresented)
    }

    @Test("transcript search focus requests repeat and stay window local")
    func transcriptSearchFocusRequestsAreWindowLocal() {
        let first = NavigationRouter()
        let second = NavigationRouter()

        #expect(first.transcriptSearchFocusRequest == 0)
        #expect(second.transcriptSearchFocusRequest == 0)

        first.requestTranscriptSearchFocus()
        let firstRequest = first.transcriptSearchFocusRequest

        #expect(firstRequest == 1)
        #expect(second.transcriptSearchFocusRequest == 0)

        first.requestTranscriptSearchFocus()

        #expect(first.transcriptSearchFocusRequest == firstRequest + 1)
        #expect(second.transcriptSearchFocusRequest == 0)
    }

    @Test("a transiently empty meeting cache never removes the selected route")
    func transientlyEmptyMeetingCacheKeepsSelection() {
        let router = NavigationRouter()
        let meetingID = MeetingID()

        router.select(.meeting(meetingID))
        router.reconcileSelectedMeeting(removedMeetingIDs: [])

        #expect(router.selection == .meeting(meetingID))
    }

    @Test("an explicit removal routes away before the detail finishes loading")
    func explicitRemovalRoutesBeforeInitialLoad() {
        let router = NavigationRouter()
        let meetingID = MeetingID()

        router.select(.meeting(meetingID))
        router.reconcileSelectedMeeting(removedMeetingIDs: [meetingID])

        #expect(router.selection == .home)
    }

    @Test("a late deletion completion keeps the newer route and publishes its warning")
    func lateDeletionCompletionKeepsNewerRouteAndWarning() {
        let router = NavigationRouter()
        let deletedMeetingID = MeetingID()

        router.select(.meeting(deletedMeetingID))
        router.select(.languageModels)
        router.applyMeetingDeletionCompletion(
            meetingID: deletedMeetingID,
            cleanupWarning: "Job cleanup must be retried."
        )

        #expect(router.selection == .languageModels)
        #expect(router.meetingActionAlert?.title == MeetingActionCopy.cleanupWarningTitle)
        #expect(router.meetingActionAlert?.message == "Job cleanup must be retried.")
    }

    @Test("a late deletion failure keeps the newer route and publishes its error")
    func lateDeletionFailureKeepsNewerRouteAndError() {
        let router = NavigationRouter()
        let deletedMeetingID = MeetingID()

        router.select(.meeting(deletedMeetingID))
        router.select(.languageModels)
        router.applyMeetingDeletionFailure("The meeting stayed in the library.")

        #expect(router.selection == .languageModels)
        #expect(router.meetingActionAlert?.title == MeetingActionCopy.deletionFailureTitle)
        #expect(router.meetingActionAlert?.message == "The meeting stayed in the library.")
    }
}
