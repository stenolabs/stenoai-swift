import Foundation
import SwiftUI
import StenoDomain
import Testing
@testable import steno_macos

@Suite("Mac commands")
struct StenoCommandTests {
    @Test("one ready meeting with audio exposes every single-meeting action")
    func singleMeetingAvailability() {
        let meeting = meeting(1, status: .ready)

        let availability = MacMeetingCommandAvailability(
            meetings: [meeting],
            selectedMeetingIDs: [meeting.id],
            meetingsWithAudio: [meeting.id],
            isRecording: false,
            hasRuntime: true
        )

        #expect(availability.canRename)
        #expect(availability.canMove)
        #expect(availability.canRetranscribe)
        #expect(availability.canExportMarkdown)
        #expect(availability.canExportAudio)
        #expect(availability.canMoveToTrash)

        let detailAvailability = MacMeetingDetailCommandAvailability(
            hasTranscript: true,
            meetingStatus: .ready
        )
        #expect(detailAvailability.canFindTranscript)
        #expect(detailAvailability.canToggleInspector)
        #expect(detailAvailability.canShare)
    }

    @Test("multiple meetings expose batch move and trash actions")
    func multipleMeetingAvailability() {
        let first = meeting(1, status: .ready)
        let second = meeting(2, status: .ready)

        let availability = MacMeetingCommandAvailability(
            meetings: [first, second],
            selectedMeetingIDs: [first.id, second.id],
            meetingsWithAudio: [first.id, second.id],
            isRecording: false,
            hasRuntime: true
        )

        #expect(!availability.canRename)
        #expect(availability.canMove)
        #expect(!availability.canRetranscribe)
        #expect(!availability.canExportMarkdown)
        #expect(!availability.canExportAudio)
        #expect(availability.canMoveToTrash)
    }

    @Test("recording and missing audio disable only affected meeting actions")
    func recordingAndAudioAvailability() {
        let ready = meeting(1, status: .ready)
        let active = meeting(2, status: .recording)
        let noAudio = MacMeetingCommandAvailability(
            meetings: [ready],
            selectedMeetingIDs: [ready.id],
            meetingsWithAudio: [],
            isRecording: false,
            hasRuntime: true
        )
        let recording = MacMeetingCommandAvailability(
            meetings: [ready],
            selectedMeetingIDs: [ready.id],
            meetingsWithAudio: [ready.id],
            isRecording: true,
            hasRuntime: true
        )
        let batchContainingActiveMeeting = MacMeetingCommandAvailability(
            meetings: [ready, active],
            selectedMeetingIDs: [ready.id, active.id],
            meetingsWithAudio: [ready.id, active.id],
            isRecording: false,
            hasRuntime: true
        )

        #expect(noAudio.canRename)
        #expect(noAudio.canMove)
        #expect(noAudio.canExportMarkdown)
        #expect(noAudio.canMoveToTrash)
        #expect(!noAudio.canRetranscribe)
        #expect(!noAudio.canExportAudio)
        #expect(recording.canRename)
        #expect(recording.canMove)
        #expect(recording.canExportMarkdown)
        #expect(!recording.canRetranscribe)
        #expect(!recording.canExportAudio)
        #expect(!recording.canMoveToTrash)
        #expect(!batchContainingActiveMeeting.canMoveToTrash)
    }

    @Test("focused folder wins over a stale meeting selection")
    func folderFocusTakesPrecedence() {
        let meetingID = meetingID(1)
        let folderID = folderID(2)

        #expect(MacFocusedCommandResolver.target(
            meetingIDs: [meetingID],
            folderID: folderID
        ) == .folder(folderID))
        #expect(MacFocusedCommandResolver.target(
            meetingIDs: [meetingID],
            folderID: nil
        ) == .meetings([meetingID]))
    }

    @MainActor
    @Test("an async command keeps the synchronously captured target")
    func asyncCommandCapturesOriginalTarget() async {
        let original = meetingID(1)
        let laterFocus = meetingID(2)
        var focusedContext = meetingContext(original)
        var actedOn: MeetingID?
        let action = MacFocusedAsyncAction(
            target: focusedContext.meetingIDs
        ) { meetingIDs in
            await Task.yield()
            actedOn = meetingIDs.first
        }

        focusedContext = meetingContext(laterFocus)
        await action()

        #expect(focusedContext.meetingIDs == [laterFocus])
        #expect(actedOn == original)
    }

    @Test("shortcuts are unique and preserve standard Mac commands")
    func shortcutsAreConflictFree() {
        let shortcuts = StenoCommandShortcuts.all

        #expect(Set(shortcuts.values).count == shortcuts.count)
        #expect(shortcuts.values.filter {
            $0 == StenoCommandShortcut("m", modifiers: [.command])
        }.isEmpty)
        #expect(shortcuts.values.filter {
            $0 == StenoCommandShortcut("i", modifiers: [.command])
        }.isEmpty)
        #expect(shortcuts.values.filter {
            $0 == StenoCommandShortcut("n", modifiers: [.command])
        }.count == 1)
        #expect(shortcuts[.newMeeting]
            == StenoCommandShortcut("n", modifiers: [.command]))
        #expect(shortcuts[.markMoment]
            == StenoCommandShortcut("m", modifiers: [.command, .shift]))
        #expect(shortcuts[.importAudio]
            == StenoCommandShortcut("i", modifiers: [.command, .shift]))
        #expect(shortcuts[.importMeetingPackage]
            == StenoCommandShortcut("i", modifiers: [.command, .option]))
    }

    @Test("the complete command table uses the planned Mac shortcuts")
    func exposesCompleteShortcutTable() {
        #expect(StenoCommandShortcuts.all == [
            .startRecording: StenoCommandShortcut("r", modifiers: [.command]),
            .stopRecording: StenoCommandShortcut(".", modifiers: [.command]),
            .markMoment: StenoCommandShortcut("m", modifiers: [.command, .shift]),
            .newMeeting: StenoCommandShortcut("n", modifiers: [.command]),
            .importAudio: StenoCommandShortcut("i", modifiers: [.command, .shift]),
            .importMeetingPackage: StenoCommandShortcut("i", modifiers: [.command, .option]),
            .findTranscript: StenoCommandShortcut("f", modifiers: [.command]),
            .toggleInspector: StenoCommandShortcut("i", modifiers: [.command, .control]),
            .moveToTrash: StenoCommandShortcut(.delete, modifiers: [.command]),
            .toggleAskBar: StenoCommandShortcut("a", modifiers: [.command, .shift]),
            .commandPalette: StenoCommandShortcut("k", modifiers: [.command]),
        ])
    }

    @Test("Find in transcript is the sole Cmd-F shortcut owner")
    func findTranscriptOwnsCommandFExclusively() throws {
        let commandF = StenoCommandShortcut("f", modifiers: [.command])

        #expect(StenoCommandShortcuts.all[.findTranscript] == commandF)
        #expect(StenoCommandShortcuts.all.values.filter { $0 == commandF }.count == 1)

        let testFileURL = URL(fileURLWithPath: #filePath)
        let detailSourceURL = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MeetingDetailView.swift")
        let detailSource = try String(contentsOf: detailSourceURL, encoding: .utf8)
        let localShortcutPattern = #"\.keyboardShortcut\s*\(\s*"f"\s*(?:,[^)]*)?\)"#

        #expect(
            detailSource.range(of: localShortcutPattern, options: .regularExpression) == nil,
            "MeetingDetailView must route Cmd-F through StenoCommands"
        )
    }

    @Test("command availability follows runtime and recording transitions")
    func derivesAvailability() {
        let unavailable = StenoCommandState(
            hasRuntime: false,
            isRecording: false,
            isStartingRecording: false
        )
        let ready = StenoCommandState(
            hasRuntime: true,
            isRecording: false,
            isStartingRecording: false
        )
        let starting = StenoCommandState(
            hasRuntime: true,
            isRecording: false,
            isStartingRecording: true
        )
        let recording = StenoCommandState(
            hasRuntime: true,
            isRecording: true,
            isStartingRecording: false
        )
        let resolvingPermissions = StenoCommandState(
            hasRuntime: true,
            isRecording: false,
            isStartingRecording: false,
            isResolvingRecordingPermissions: true
        )
        let movingMeetingsToTrash = StenoCommandState(
            hasRuntime: true,
            isRecording: false,
            isStartingRecording: false,
            isMovingMeetingsToTrash: true
        )

        #expect(!unavailable.canStartRecording)
        #expect(!unavailable.canCreateMeeting)
        #expect(!unavailable.canImport)
        #expect(ready.canStartRecording)
        #expect(ready.canCreateMeeting)
        #expect(ready.canImport)
        #expect(!ready.canStopRecording)
        #expect(!ready.canMarkMoment)
        #expect(!starting.canStartRecording)
        #expect(!starting.canCreateMeeting)
        #expect(!starting.canImport)
        #expect(!starting.canStopRecording)
        #expect(!recording.canStartRecording)
        #expect(!recording.canCreateMeeting)
        #expect(!recording.canImport)
        #expect(recording.canStopRecording)
        #expect(recording.canMarkMoment)
        #expect(!resolvingPermissions.canStartRecording)
        #expect(!movingMeetingsToTrash.canStartRecording)
        #expect(!movingMeetingsToTrash.canCreateMeeting)
        #expect(!movingMeetingsToTrash.canImport)
    }

    private func meeting(
        _ value: Int,
        status: Meeting.Status
    ) -> Meeting {
        Meeting(
            id: meetingID(value),
            title: "Meeting \(value)",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            status: status
        )
    }

    @MainActor
    private func meetingContext(
        _ meetingID: MeetingID
    ) -> MacMeetingCommandContext {
        let selectedMeeting = Meeting(
            id: meetingID,
            title: "Captured meeting",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            status: .ready
        )
        return MacMeetingCommandContext(
            meetingIDs: [meetingID],
            availability: MacMeetingCommandAvailability(
                meetings: [selectedMeeting],
                selectedMeetingIDs: [meetingID],
                meetingsWithAudio: [meetingID],
                isRecording: false,
                hasRuntime: true
            ),
            folderDestinations: [],
            rename: {},
            moveToFolder: { _ in },
            createFolder: {},
            retranscribe: {},
            exportMarkdown: {},
            exportAudio: {},
            moveToTrash: {}
        )
    }

    private func meetingID(_ value: Int) -> MeetingID {
        MeetingID(rawValue: uuid(value))
    }

    private func folderID(_ value: Int) -> FolderID {
        FolderID(rawValue: uuid(value))
    }

    private func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(
            format: "00000000-0000-7000-8000-%012d",
            value
        ))!
    }
}
