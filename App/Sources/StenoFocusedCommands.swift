import StenoDomain
import SwiftUI

struct MacMeetingCommandAvailability: Equatable {
    let canRename: Bool
    let canMove: Bool
    let canRetranscribe: Bool
    let canExportMarkdown: Bool
    let canExportAudio: Bool
    let canMoveToTrash: Bool

    init(
        meetings: [Meeting],
        selectedMeetingIDs: Set<MeetingID>,
        meetingsWithAudio: Set<MeetingID>,
        isRecording: Bool,
        hasRuntime: Bool
    ) {
        let selectedMeetings = meetings.filter {
            selectedMeetingIDs.contains($0.id)
        }
        let hasCompleteSelection = !selectedMeetingIDs.isEmpty
            && selectedMeetings.count == selectedMeetingIDs.count
        let singleMeeting = selectedMeetings.count == 1
            ? selectedMeetings[0]
            : nil
        let selectedMeetingIsRecording = selectedMeetings.contains {
            $0.status == .recording
        }

        canRename = hasRuntime && singleMeeting != nil
        canMove = hasRuntime && hasCompleteSelection
        canExportMarkdown = hasRuntime && singleMeeting != nil
        canRetranscribe = hasRuntime
            && singleMeeting != nil
            && !isRecording
            && !selectedMeetingIsRecording
            && singleMeeting.map { meetingsWithAudio.contains($0.id) } == true
        canExportAudio = canRetranscribe
        canMoveToTrash = hasRuntime
            && hasCompleteSelection
            && !isRecording
            && !selectedMeetingIsRecording
    }
}

struct MacMeetingFolderDestination: Identifiable, Equatable {
    let id: FolderID
    let name: String
    let parentFolderID: FolderID?
}

@MainActor
struct MacMeetingCommandContext {
    let meetingIDs: Set<MeetingID>
    let availability: MacMeetingCommandAvailability
    let folderDestinations: [MacMeetingFolderDestination]
    let rename: () -> Void
    let moveToFolder: (FolderID?) -> Void
    let createFolder: () -> Void
    let retranscribe: () -> Void
    let exportMarkdown: () -> Void
    let exportAudio: () -> Void
    let moveToTrash: () -> Void
}

struct MacFolderCommandAvailability: Equatable {
    let canCreateSubfolder: Bool
    let canRename: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let canMoveToTopLevel: Bool
    let canDelete: Bool
}

@MainActor
struct MacFolderCommandContext {
    let folderID: FolderID
    let folderName: String
    let availability: MacFolderCommandAvailability
    let nestingDestinations: [MacMeetingFolderDestination]
    let createSubfolder: () -> Void
    let rename: () -> Void
    let moveUp: () -> Void
    let moveDown: () -> Void
    let moveIntoFolder: (FolderID) -> Void
    let moveToTopLevel: () -> Void
    let delete: () -> Void
}

struct MacMeetingDetailCommandAvailability: Equatable {
    let canFindTranscript: Bool
    let canToggleInspector: Bool
    let canShare: Bool

    init(
        hasTranscript: Bool,
        meetingStatus: Meeting.Status?
    ) {
        canFindTranscript = hasTranscript
        canToggleInspector = meetingStatus != nil
        canShare = MeetingPresentation.canShareMeeting(status: meetingStatus)
    }
}

@MainActor
struct MacMeetingDetailCommandContext {
    let meetingID: MeetingID
    let availability: MacMeetingDetailCommandAvailability
    let findTranscript: () -> Void
    let toggleInspector: () -> Void
    let share: () -> Void
}

enum MacFocusedCommandTarget: Equatable {
    case folder(FolderID)
    case meetings(Set<MeetingID>)
    case none
}

enum MacFocusedCommandResolver {
    static func target(
        meetingIDs: Set<MeetingID>,
        folderID: FolderID?
    ) -> MacFocusedCommandTarget {
        if let folderID {
            return .folder(folderID)
        }
        if !meetingIDs.isEmpty {
            return .meetings(meetingIDs)
        }
        return .none
    }
}

@MainActor
struct MacFocusedAsyncAction<Target> {
    private let target: Target
    private let operation: @MainActor (Target) async -> Void

    init(
        target: Target,
        operation: @escaping @MainActor (Target) async -> Void
    ) {
        self.target = target
        self.operation = operation
    }

    func callAsFunction() async {
        await operation(target)
    }
}

private struct MacMeetingCommandContextKey: FocusedValueKey {
    typealias Value = MacMeetingCommandContext
}

private struct MacFolderCommandContextKey: FocusedValueKey {
    typealias Value = MacFolderCommandContext
}

private struct MacMeetingDetailCommandContextKey: FocusedValueKey {
    typealias Value = MacMeetingDetailCommandContext
}

extension FocusedValues {
    var stenoMeetingCommandContext: MacMeetingCommandContext? {
        get { self[MacMeetingCommandContextKey.self] }
        set { self[MacMeetingCommandContextKey.self] = newValue }
    }

    var stenoFolderCommandContext: MacFolderCommandContext? {
        get { self[MacFolderCommandContextKey.self] }
        set { self[MacFolderCommandContextKey.self] = newValue }
    }

    var stenoMeetingDetailCommandContext: MacMeetingDetailCommandContext? {
        get { self[MacMeetingDetailCommandContextKey.self] }
        set { self[MacMeetingDetailCommandContextKey.self] = newValue }
    }
}
