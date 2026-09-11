import Foundation
import StenoDomain
import SwiftUI
import Testing
@testable import steno_macos

@Suite("Meeting sidebar state")
struct MeetingSidebarStateTests {
    @Test("single selection exists only for exactly one meeting")
    func derivesSingleSelection() {
        let a = meetingID(1)
        let b = meetingID(2)

        #expect(MeetingSidebarSelectionPolicy.singleID(in: []) == nil)
        #expect(MeetingSidebarSelectionPolicy.singleID(in: [a]) == a)
        #expect(MeetingSidebarSelectionPolicy.singleID(in: [a, b]) == nil)
    }

    @Test("pruning removes meetings that no longer exist")
    func prunesSelection() {
        let a = meetingID(1)
        let b = meetingID(2)
        let missing = meetingID(3)

        #expect(MeetingSidebarSelectionPolicy.pruned(
            [a, missing],
            to: [a, b]
        ) == [a])
    }

    @Test("dragging a selected row carries the complete selection")
    func dragsCompleteSelection() {
        let a = meetingID(1)
        let b = meetingID(2)

        #expect(MeetingSidebarSelectionPolicy.draggedIDs(
            startingAt: a,
            selection: [a, b]
        ) == Set([a, b]))
    }

    @Test("dragging an unselected row carries only that row")
    func dragsOnlyUnselectedStartRow() {
        let a = meetingID(1)
        let b = meetingID(2)
        let c = meetingID(3)

        #expect(MeetingSidebarSelectionPolicy.draggedIDs(
            startingAt: c,
            selection: [a, b]
        ) == Set([c]))
    }

    @Test("folder disclosure survives reload and removes one folder at a time")
    func persistsFolderDisclosure() throws {
        let suiteName = "MeetingSidebarStateTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let a = folderID(1)
        let b = folderID(2)

        let store = FolderDisclosureStore(defaults: defaults)
        #expect(store.load().isEmpty)
        store.save([b, a])

        let reloaded = FolderDisclosureStore(defaults: defaults)
        #expect(reloaded.load() == Set([a, b]))
        #expect(defaults.stringArray(
            forKey: "steno.sidebar.expandedFolders"
        ) == [a.description, b.description])

        reloaded.remove(a)

        #expect(reloaded.load() == Set([b]))
    }

    @Test("visible meetings follow the expanded folder path")
    func derivesVisibleMeetings() {
        let work = folder(1, name: "Arbeit")
        let product = folder(
            2,
            name: "Produktvorstellung",
            parentFolderID: work.id
        )
        let direct = meeting(1, folderID: work.id)
        let demo = meeting(2, folderID: product.id)
        let loose = meeting(3)
        let tree = MeetingSidebarTree.build(
            for: [direct, demo, loose],
            folders: [work, product]
        )

        #expect(MeetingSidebarVisibility.visibleMeetingIDs(
            in: tree,
            expandedFolderIDs: [work.id, product.id]
        ) == Set([direct.id, demo.id, loose.id]))
        #expect(MeetingSidebarVisibility.visibleMeetingIDs(
            in: tree,
            expandedFolderIDs: [product.id]
        ) == Set([loose.id]))
    }

    @Test("content refresh removes a selection moved under a collapsed folder")
    func contentRefreshPrunesHiddenSelection() {
        let work = folder(1, name: "Arbeit")
        let selected = meeting(1, folderID: work.id)
        let tree = MeetingSidebarTree.build(
            for: [selected],
            folders: [work]
        )

        #expect(MeetingSidebarVisibility.prunedSelection(
            [selected.id],
            in: tree,
            expandedFolderIDs: []
        ).isEmpty)
    }

    @Test("search expands matching paths without changing persistence")
    func expandsSearchPaths() {
        let work = folder(1, name: "Arbeit")
        let product = folder(
            2,
            name: "Produktvorstellung",
            parentFolderID: work.id
        )
        let hit = meeting(1, folderID: product.id)
        let tree = MeetingSidebarTree.build(
            for: [hit],
            folders: [work, product],
            hidesEmptyFolders: true
        )
        let persisted = Set<FolderID>()

        let effective = MeetingSidebarVisibility.effectiveExpandedFolderIDs(
            in: tree,
            persisted: persisted,
            isSearching: true
        )

        #expect(effective == Set([work.id, product.id]))
        #expect(persisted.isEmpty)
        #expect(MeetingSidebarVisibility.effectiveExpandedFolderIDs(
            in: tree,
            persisted: persisted,
            isSearching: false
        ).isEmpty)
    }

    @Test("multi-selection exposes its common move and trash actions")
    func derivesSelectionActions() {
        let a = meetingID(1)
        let b = meetingID(2)

        #expect(MeetingSidebarActionPolicy.actions(for: [a, b]) == [
            .moveMeetings,
            .trash,
        ])
        #expect(MeetingSidebarActionPolicy.actions(for: [a]) == [
            .rename,
            .moveMeetings,
            .retranscribe,
            .export,
            .trash,
        ])
        #expect(MeetingSidebarActionPolicy.actions(for: []).isEmpty)
    }

    @Test("trash confirmation snapshots every selected meeting")
    func snapshotsTrashConfirmation() throws {
        let first = meeting(1)
        let second = meeting(2)

        let request = try #require(MeetingTrashRequest(meetings: [first, second]))

        #expect(request.meetingIDs == [first.id, second.id])
        #expect(localizedEnglish(request.confirmationTitle)
            == "Move 2 Meetings to the Trash?")
        #expect(localizedEnglish(request.actionTitle)
            == "Move 2 Meetings to Trash")
        #expect(localizedEnglish(request.menuTitle)
            == "Move 2 Meetings to Trash…")
    }

    @Test("sidebar actions follow contextual availability")
    func derivesAvailableContextActions() {
        let ready = meeting(1)
        let recording = Meeting(
            id: meetingID(2),
            title: "Recording",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            status: .recording
        )

        #expect(MeetingSidebarActionPolicy.actions(
            for: MacMeetingCommandAvailability(
                meetings: [ready],
                selectedMeetingIDs: [ready.id],
                meetingsWithAudio: [ready.id],
                isRecording: false,
                hasRuntime: true
            )
        ) == [
            .rename,
            .moveMeetings,
            .retranscribe,
            .export,
            .trash,
        ])
        #expect(MeetingSidebarActionPolicy.actions(
            for: MacMeetingCommandAvailability(
                meetings: [recording],
                selectedMeetingIDs: [recording.id],
                meetingsWithAudio: [recording.id],
                isRecording: true,
                hasRuntime: true
            )
        ) == [
            .rename,
            .moveMeetings,
            .export,
        ])
    }

    @Test("meeting title validation normalizes whitespace before submission")
    func validatesMeetingTitlesBeforeSubmission() {
        #expect(MeetingTitleValidation.evaluate(title: " \n\t ") == .empty)
        #expect(!MeetingTitleValidation.evaluate(title: " \n\t ").canSubmit)
        #expect(MeetingTitleValidation.evaluate(
            title: "  Quarterly\n  review  "
        ) == .valid(normalizedTitle: "Quarterly review"))
    }

    @Test("folder name validation matches the store's sibling rules")
    func validatesFolderNamesBeforeSubmission() {
        let work = folder(1, name: "Work")
        let product = folder(
            2,
            name: "Product",
            parentFolderID: work.id
        )
        let privateFolder = folder(3, name: "Private")

        #expect(SidebarNameValidation.evaluate(
            name: " \n\t ",
            parentFolderID: nil,
            currentFolderID: nil,
            folders: [work, product, privateFolder]
        ) == .empty)
        #expect(SidebarNameValidation.evaluate(
            name: " work ",
            parentFolderID: nil,
            currentFolderID: nil,
            folders: [work, product, privateFolder]
        ) == .duplicate)
        #expect(SidebarNameValidation.evaluate(
            name: "PRODUCT",
            parentFolderID: work.id,
            currentFolderID: nil,
            folders: [work, product, privateFolder]
        ) == .duplicate)
        #expect(SidebarNameValidation.evaluate(
            name: " WORK ",
            parentFolderID: nil,
            currentFolderID: work.id,
            folders: [work, product, privateFolder]
        ) == .valid(normalizedName: "WORK"))
        #expect(SidebarNameValidation.evaluate(
            name: "Product",
            parentFolderID: privateFolder.id,
            currentFolderID: nil,
            folders: [work, product, privateFolder]
        ) == .valid(normalizedName: "Product"))
    }

    @Test("folder validation help is a localized resource")
    func localizesFolderValidationHelp() throws {
        let emptyMessage = try #require(SidebarNameValidation.evaluate(
            name: " \n\t ",
            parentFolderID: nil,
            currentFolderID: nil,
            folders: []
        ).message)
        let duplicate = folder(1, name: "Work")
        let duplicateMessage = try #require(SidebarNameValidation.evaluate(
            name: "work",
            parentFolderID: nil,
            currentFolderID: nil,
            folders: [duplicate]
        ).message)
        let english = Locale(identifier: "en_US_POSIX")
        var localizedEmptyMessage = emptyMessage
        localizedEmptyMessage.locale = english
        var localizedDuplicateMessage = duplicateMessage
        localizedDuplicateMessage.locale = english

        #expect(String(localized: localizedEmptyMessage)
            == "Enter a folder name.")
        #expect(String(localized: localizedDuplicateMessage)
            == "A folder with this name already exists here.")
    }

    @Test("drag payloads round-trip without meeting contents")
    func transferPayloadsRoundTrip() throws {
        let a = meetingID(2)
        let b = meetingID(1)
        let meetingPayload = SidebarDragPayload(meetingIDs: [a, b])
        let folderPayload = SidebarDragPayload(folderID: folderID(3))

        #expect(try JSONDecoder().decode(
            SidebarDragPayload.self,
            from: JSONEncoder().encode(meetingPayload)
        ) == meetingPayload)
        #expect(try JSONDecoder().decode(
            SidebarDragPayload.self,
            from: JSONEncoder().encode(folderPayload)
        ) == folderPayload)
        #expect(MeetingSidebarDropPolicy.meetingIDsToAttempt(meetingPayload) == [a, b])
        #expect(MeetingSidebarDropPolicy.meetingIDsToAttempt(folderPayload) == nil)
    }

    @Test("drag source and folder destination agree on moving items")
    func dragContractAllowsMoveAtBothEnds() {
        #expect(MeetingSidebarDragContract.sourceAllowsMove)
        #expect(MeetingSidebarDragContract.destinationOperation == .move)
    }

    @Test("folder negotiates a local move without relying on unavailable drag IDs")
    func negotiatesLocalMoveWithoutDragIDs() {
        #expect(MeetingSidebarDropPolicy.canNegotiateLocalMove(
            itemCount: 1,
            hasLocalSession: true,
            suggestsMove: true,
            targetExists: true
        ))
        #expect(!MeetingSidebarDropPolicy.canNegotiateLocalMove(
            itemCount: 2,
            hasLocalSession: true,
            suggestsMove: true,
            targetExists: true
        ))
        #expect(!MeetingSidebarDropPolicy.canNegotiateLocalMove(
            itemCount: 1,
            hasLocalSession: false,
            suggestsMove: true,
            targetExists: true
        ))
    }

    @Test("drop indicator belongs only to the currently targeted folder")
    func targetsOneFolderForDropFeedback() {
        let work = folderID(1)
        let privateFolder = folderID(2)

        #expect(MeetingSidebarDropPresentation.isTargeted(
            work,
            targetedFolderID: work
        ))
        #expect(!MeetingSidebarDropPresentation.isTargeted(
            privateFolder,
            targetedFolderID: work
        ))
        #expect(MeetingSidebarDropPresentation.symbolName == "folder")
    }

    @Test("folder drop preview mirrors the two-level hierarchy")
    func validatesFolderDropPreview() {
        let work = folder(1, name: "Arbeit")
        let product = folder(
            2,
            name: "Produktvorstellung",
            parentFolderID: work.id
        )
        let emptyRoot = folder(3, name: "Privat")
        let rootWithChildren = folder(4, name: "Kunden")
        let child = folder(
            5,
            name: "Vorstellung",
            parentFolderID: rootWithChildren.id
        )
        let folders = [work, product, emptyRoot, rootWithChildren, child]

        #expect(MeetingSidebarDropPolicy.canMove(
            folder: emptyRoot.id,
            onto: work.id,
            folders: folders
        ))
        #expect(!MeetingSidebarDropPolicy.canMove(
            folder: work.id,
            onto: product.id,
            folders: folders
        ))
        #expect(!MeetingSidebarDropPolicy.canMove(
            folder: rootWithChildren.id,
            onto: work.id,
            folders: folders
        ))
        #expect(MeetingSidebarDropPolicy.canPromote(
            folder: product.id,
            folders: folders
        ))
        #expect(!MeetingSidebarDropPolicy.canPromote(
            folder: work.id,
            folders: folders
        ))
    }

    @Test("a nested folder can move directly into another root from the menu")
    func derivesNestedFolderMenuDestinations() {
        let work = folder(1, name: "Arbeit")
        let product = folder(
            2,
            name: "Produktvorstellung",
            parentFolderID: work.id
        )
        let privateFolder = folder(3, name: "Privat")

        #expect(MeetingSidebarFolderMenuPolicy.nestingDestinations(
            for: product,
            folders: [work, product, privateFolder]
        ).map(\.id) == [privateFolder.id])
    }

    @Test("a structurally valid stale meeting payload reaches operation validation")
    func attemptsStaleMeetingPayload() {
        let missing = meetingID(42)
        let payload = SidebarDragPayload(meetingIDs: [missing])

        #expect(
            MeetingSidebarDropPolicy.meetingIDsToAttempt(payload)
                == Set([missing])
        )
    }

    @Test("revealing a nested destination expands its complete path")
    func expandsDestinationPath() {
        let work = folder(1, name: "Arbeit")
        let product = folder(
            2,
            name: "Produktvorstellung",
            parentFolderID: work.id
        )

        #expect(MeetingSidebarVisibility.expandedFolderIDs(
            [folderID(9)],
            revealing: product.id,
            folders: [work, product]
        ) == Set([folderID(9), work.id, product.id]))
    }

    private func meetingID(_ value: Int) -> MeetingID {
        MeetingID(rawValue: uuid(value))
    }

    private func localizedEnglish(
        _ resource: LocalizedStringResource
    ) -> String {
        var resource = resource
        resource.locale = Locale(identifier: "en")
        return String(localized: resource)
    }

    private func folderID(_ value: Int) -> FolderID {
        FolderID(rawValue: uuid(value))
    }

    private func folder(
        _ value: Int,
        name: String,
        parentFolderID: FolderID? = nil
    ) -> Folder {
        Folder(
            id: folderID(value),
            name: name,
            parentFolderID: parentFolderID,
            sortIndex: value,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func meeting(
        _ value: Int,
        folderID: FolderID? = nil
    ) -> Meeting {
        Meeting(
            id: meetingID(value),
            title: "Meeting \(value)",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            status: .ready,
            folderID: folderID
        )
    }

    private func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(
            format: "00000000-0000-7000-8000-%012d",
            value
        ))!
    }
}
