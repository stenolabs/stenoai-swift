import Foundation
import StenoDomain
import Testing
@testable import Steno

@Suite("Steno commands")
struct StenoCommandStateTests {
    @Test("the app model exposes the shared command action boundary")
    @MainActor
    func appModelBuildsSharedActions() {
        _ = StenoCommandActions(model: AppModel())
    }

    @Test("stop includes preparing but marker does not")
    func stopIncludesPreparingButMarkerDoesNot() {
        let preparing = StenoCommandState(
            libraryReady: true,
            recordingState: .preparing,
            recordingReadyForNewRecording: false,
            canEditAnnotations: false,
            hasSelectedMeeting: false
        )
        let recording = StenoCommandState(
            libraryReady: true,
            recordingState: .recording,
            recordingReadyForNewRecording: false,
            canEditAnnotations: true,
            hasSelectedMeeting: true
        )

        #expect(preparing.canStartRecording == false)
        #expect(preparing.canStopRecording)
        #expect(!preparing.canMark)
        #expect(recording.canStopRecording)
        #expect(recording.canMark)
    }

    @Test("recording start depends on library readiness, not speech model readiness")
    func missingSpeechModelDoesNotBlockStart() {
        let ready = StenoCommandState(
            libraryReady: true,
            recordingState: .idle,
            recordingReadyForNewRecording: true,
            canEditAnnotations: false,
            hasSelectedMeeting: false
        )
        let unavailableLibrary = StenoCommandState(
            libraryReady: false,
            recordingState: .idle,
            recordingReadyForNewRecording: true,
            canEditAnnotations: false,
            hasSelectedMeeting: false
        )

        #expect(ready.canStartRecording)
        #expect(!unavailableLibrary.canStartRecording)
    }

    @Test("recording readiness remains a separate start gate")
    func recordingReadinessAlsoGatesStart() {
        let busyRecording = StenoCommandState(
            libraryReady: true,
            recordingState: .idle,
            recordingReadyForNewRecording: false,
            canEditAnnotations: false,
            hasSelectedMeeting: false
        )

        #expect(!busyRecording.canStartRecording)
    }

    @Test("marker is disabled while annotations are not editable")
    func markerNeedsEditableAnnotations() {
        let stopping = StenoCommandState(
            libraryReady: true,
            recordingState: .recording,
            recordingReadyForNewRecording: false,
            canEditAnnotations: false,
            hasSelectedMeeting: false
        )

        #expect(!stopping.canMark)
    }

    @Test("find in transcript requires a selected meeting")
    func findInTranscriptRequiresMeetingSelection() {
        let noSelection = StenoCommandState(
            libraryReady: true,
            recordingState: .idle,
            recordingReadyForNewRecording: true,
            canEditAnnotations: false,
            hasSelectedMeeting: false
        )
        let selectedMeeting = StenoCommandState(
            libraryReady: true,
            recordingState: .idle,
            recordingReadyForNewRecording: true,
            canEditAnnotations: false,
            hasSelectedMeeting: true
        )

        #expect(!noSelection.canFindInTranscript)
        #expect(selectedMeeting.canFindInTranscript)
    }

    @Test("find in transcript targets only the focused window router")
    @MainActor
    func findInTranscriptTargetsFocusedRouter() {
        let first = NavigationRouter()
        let second = NavigationRouter()
        let actions = StenoCommandActions(
            start: {},
            stop: {},
            mark: {},
            createDraft: { nil },
            reloadMeetings: {}
        )

        actions.focusTranscriptSearch(in: first)
        actions.focusTranscriptSearch(in: first)

        #expect(first.transcriptSearchFocusRequest == 2)
        #expect(second.transcriptSearchFocusRequest == 0)
    }

    @Test("new meeting keeps the router captured and defers its inspector")
    @MainActor
    func newMeetingKeepsRouterCapturedBeforeAwait() async {
        let first = NavigationRouter()
        let second = NavigationRouter()
        let draft = ControlledDraftCreation()
        let actions = StenoCommandActions(
            start: {},
            stop: {},
            mark: {},
            createDraft: { await draft.create() },
            reloadMeetings: {}
        )
        var focusedRouter: NavigationRouter? = first

        let destinationRouter = focusedRouter
        let task = Task {
            await actions.createDraft(in: destinationRouter)
        }
        await draft.waitUntilEntered()
        focusedRouter = second
        await draft.release()
        await task.value

        #expect(first.selection == .meeting(draft.meetingID))
        #expect(!first.isInspectorPresented)
        #expect(second.selection == .home)
        #expect(!second.isInspectorPresented)
        #expect(focusedRouter === second)
    }

    @Test("start reloads meetings after recording startup completes")
    @MainActor
    func startReloadsMeetingsAfterCompletion() async {
        var events: [String] = []
        let actions = StenoCommandActions(
            start: {
                events.append("start began")
                await Task.yield()
                events.append("start completed")
            },
            stop: {},
            mark: {},
            createDraft: { nil },
            reloadMeetings: { events.append("reload") }
        )

        await actions.start()

        #expect(events == ["start began", "start completed", "reload"])
    }

    @Test("stop does not reload meetings a second time")
    @MainActor
    func stopDoesNotDuplicateAppModelsOwnReload() async {
        var events: [String] = []
        let actions = StenoCommandActions(
            start: {},
            stop: { events.append("stop") },
            mark: {},
            createDraft: { nil },
            reloadMeetings: { events.append("reload") }
        )

        await actions.stop()

        #expect(events == ["stop"])
    }
}

private actor ControlledDraftCreation {
    nonisolated let meetingID = MeetingID()

    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?

    func create() async -> MeetingID? {
        entered = true
        await withCheckedContinuation { continuation = $0 }
        return meetingID
    }

    func waitUntilEntered() async {
        while !entered {
            await Task.yield()
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
