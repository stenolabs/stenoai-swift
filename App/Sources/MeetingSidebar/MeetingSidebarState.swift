import Foundation
import StenoDomain
import StenoLibrary

enum MeetingSidebarSelectionPolicy {
    static func singleID(in selection: Set<MeetingID>) -> MeetingID? {
        guard selection.count == 1 else { return nil }
        return selection.first
    }

    static func pruned(
        _ selection: Set<MeetingID>,
        to visibleOrExisting: Set<MeetingID>
    ) -> Set<MeetingID> {
        selection.intersection(visibleOrExisting)
    }

    static func draggedIDs(
        startingAt meetingID: MeetingID,
        selection: Set<MeetingID>
    ) -> Set<MeetingID> {
        selection.contains(meetingID) ? selection : Set([meetingID])
    }
}

enum MeetingSidebarAction: Equatable {
    case rename
    case moveMeetings
    case retranscribe
    case export
    case trash
}

enum MeetingSidebarActionPolicy {
    static func actions(
        for meetingIDs: Set<MeetingID>
    ) -> [MeetingSidebarAction] {
        switch meetingIDs.count {
        case 0:
            []
        case 1:
            [.rename, .moveMeetings, .retranscribe, .export, .trash]
        default:
            [.moveMeetings, .trash]
        }
    }

    static func actions(
        for availability: MacMeetingCommandAvailability
    ) -> [MeetingSidebarAction] {
        var actions: [MeetingSidebarAction] = []
        if availability.canRename { actions.append(.rename) }
        if availability.canMove { actions.append(.moveMeetings) }
        if availability.canRetranscribe { actions.append(.retranscribe) }
        if availability.canExportMarkdown { actions.append(.export) }
        if availability.canMoveToTrash { actions.append(.trash) }
        return actions
    }
}

struct MeetingTrashRequest: Equatable {
    struct Item: Equatable {
        let meetingID: MeetingID
        let title: String
    }

    let items: [Item]

    init?(meetings: [Meeting]) {
        guard !meetings.isEmpty else { return nil }
        items = meetings.map {
            Item(meetingID: $0.id, title: $0.title)
        }
    }

    var meetingIDs: [MeetingID] {
        items.map(\.meetingID)
    }

    var confirmationTitle: LocalizedStringResource {
        if items.count == 1, let item = items.first {
            return "Move \u{201C}\(item.title)\u{201D} to the Trash?"
        }
        return "Move \(items.count) Meetings to the Trash?"
    }

    var actionTitle: LocalizedStringResource {
        items.count == 1
            ? "Move to Trash"
            : "Move \(items.count) Meetings to Trash"
    }

    var menuTitle: LocalizedStringResource {
        Self.menuTitle(meetingCount: items.count)
    }

    var message: LocalizedStringResource {
        if items.count == 1 {
            return "The entire meeting folder (audio, transcripts, runs) moves to the Trash and stays recoverable there. Speakers that are still unnamed cannot be named after deletion, because naming needs the audio file."
        }
        return "All selected meeting folders (audio, transcripts, runs) move to the Trash and stay recoverable there. Speakers that are still unnamed cannot be named after deletion, because naming needs the audio files."
    }

    static func menuTitle(meetingCount: Int) -> LocalizedStringResource {
        meetingCount == 1
            ? "Move to Trash…"
            : "Move \(meetingCount) Meetings to Trash…"
    }

    static func commandTitle(meetingCount: Int) -> LocalizedStringResource {
        meetingCount == 1
            ? "Move Meeting to Trash…"
            : "Move \(meetingCount) Meetings to Trash…"
    }
}

enum MeetingTitleValidation: Equatable {
    case valid(normalizedTitle: String)
    case empty

    var normalizedTitle: String? {
        guard case let .valid(normalizedTitle) = self else { return nil }
        return normalizedTitle
    }

    var canSubmit: Bool {
        normalizedTitle != nil
    }

    var message: LocalizedStringResource? {
        switch self {
        case .valid:
            nil
        case .empty:
            "Enter a meeting title."
        }
    }

    static func evaluate(title: String) -> MeetingTitleValidation {
        let normalizedTitle = title
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !normalizedTitle.isEmpty else { return .empty }
        return .valid(normalizedTitle: normalizedTitle)
    }
}

enum SidebarNameValidation: Equatable {
    case valid(normalizedName: String)
    case empty
    case duplicate

    var normalizedName: String? {
        guard case let .valid(normalizedName) = self else { return nil }
        return normalizedName
    }

    var canSubmit: Bool {
        normalizedName != nil
    }

    var message: LocalizedStringResource? {
        switch self {
        case .valid:
            nil
        case .empty:
            "Enter a folder name."
        case .duplicate:
            "A folder with this name already exists here."
        }
    }

    static func evaluate(
        name: String,
        parentFolderID: FolderID?,
        currentFolderID: FolderID?,
        folders: [Folder]
    ) -> SidebarNameValidation {
        let normalizedName = name
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !normalizedName.isEmpty else { return .empty }

        let targetKey = comparisonKey(normalizedName)
        let hasDuplicate = folders.contains { folder in
            guard folder.id != currentFolderID,
                  folder.parentFolderID == parentFolderID
            else { return false }
            return comparisonKey(folder.name) == targetKey
        }
        guard !hasDuplicate else { return .duplicate }
        return .valid(normalizedName: normalizedName)
    }

    private static func comparisonKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.folding(
            options: [.caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}

enum MeetingSidebarVisibility {
    static func effectiveExpandedFolderIDs(
        in tree: MeetingSidebarTree,
        persisted: Set<FolderID>,
        isSearching: Bool
    ) -> Set<FolderID> {
        guard isSearching else { return persisted }
        return tree.folderNodes.reduce(into: persisted) { result, root in
            result.insert(root.id)
            result.formUnion(root.children.map(\.id))
        }
    }

    static func visibleMeetingIDs(
        in tree: MeetingSidebarTree,
        expandedFolderIDs: Set<FolderID>
    ) -> Set<MeetingID> {
        var visible = Set(
            tree.unfiledSections.flatMap(\.meetings).map(\.id)
        )
        for root in tree.folderNodes
        where expandedFolderIDs.contains(root.id) {
            visible.formUnion(root.meetings.map(\.id))
            for child in root.children
            where expandedFolderIDs.contains(child.id) {
                visible.formUnion(child.meetings.map(\.id))
            }
        }
        return visible
    }

    static func prunedSelection(
        _ selection: Set<MeetingID>,
        in tree: MeetingSidebarTree,
        expandedFolderIDs: Set<FolderID>
    ) -> Set<MeetingID> {
        MeetingSidebarSelectionPolicy.pruned(
            selection,
            to: visibleMeetingIDs(
                in: tree,
                expandedFolderIDs: expandedFolderIDs
            )
        )
    }

    static func expandedFolderIDs(
        _ persisted: Set<FolderID>,
        revealing folderID: FolderID,
        folders: [Folder]
    ) -> Set<FolderID> {
        guard let folder = folders.first(where: { $0.id == folderID }) else {
            return persisted
        }
        var expanded = persisted
        expanded.insert(folder.id)
        if let parentFolderID = folder.parentFolderID {
            expanded.insert(parentFolderID)
        }
        return expanded
    }
}

enum MeetingSidebarFolderMenuPolicy {
    static func nestingDestinations(
        for folder: Folder,
        folders: [Folder]
    ) -> [Folder] {
        if folder.parentFolderID == nil,
           folders.contains(where: { $0.parentFolderID == folder.id }) {
            return []
        }
        return folders.filter {
            $0.parentFolderID == nil
                && $0.id != folder.id
                && $0.id != folder.parentFolderID
        }
    }
}

enum MeetingSidebarDropPolicy {
    static func canNegotiateLocalMove(
        itemCount: Int,
        hasLocalSession: Bool,
        suggestsMove: Bool,
        targetExists: Bool
    ) -> Bool {
        itemCount == 1
            && hasLocalSession
            && suggestsMove
            && targetExists
    }

    static func meetingIDsToAttempt(
        _ payload: SidebarDragPayload
    ) -> Set<MeetingID>? {
        guard case let .meetings(payloadMeetingIDs) = payload else {
            return nil
        }
        let meetingIDs = Set(payloadMeetingIDs)
        guard !meetingIDs.isEmpty,
              meetingIDs.count == payloadMeetingIDs.count
        else { return nil }
        return meetingIDs
    }

    static func canMove(
        folder folderID: FolderID,
        onto parentFolderID: FolderID,
        folders: [Folder]
    ) -> Bool {
        guard folderID != parentFolderID,
              let folder = folders.first(where: { $0.id == folderID }),
              let parent = folders.first(where: { $0.id == parentFolderID }),
              parent.parentFolderID == nil,
              !folders.contains(where: { $0.parentFolderID == folderID })
        else { return false }

        return folder.parentFolderID != parentFolderID
    }

    static func canPromote(
        folder folderID: FolderID,
        folders: [Folder]
    ) -> Bool {
        folders.first(where: { $0.id == folderID })?.parentFolderID != nil
    }
}

enum MeetingSidebarDropPresentation {
    static let symbolName = "folder"

    static func isTargeted(
        _ folderID: FolderID,
        targetedFolderID: FolderID?
    ) -> Bool {
        folderID == targetedFolderID
    }
}

struct FolderDisclosureStore {
    private static let key = "steno.sidebar.expandedFolders"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> Set<FolderID> {
        Set((defaults.stringArray(forKey: Self.key) ?? []).compactMap { raw in
            UUID(uuidString: raw).map(FolderID.init(rawValue:))
        })
    }

    func save(_ folderIDs: Set<FolderID>) {
        defaults.set(
            folderIDs.map(\.description).sorted(),
            forKey: Self.key
        )
    }

    func remove(_ folderID: FolderID) {
        var folderIDs = load()
        folderIDs.remove(folderID)
        save(folderIDs)
    }
}

/// Scope of a sidebar search: only meeting titles (fast, in-memory filter)
/// or all indexed content (transcript, note, report via MeetingSearchIndex).
enum MeetingSidebarSearchScope: String, CaseIterable, Equatable {
    case titles
    case allContent
}

/// One "all content" result row the sidebar can render.
struct MeetingSidebarContentHit: Equatable {
    let meetingID: MeetingID
    let snippet: String
}

/// Routes a sidebar query by scope.
///
/// `titles` reuses the existing in-memory `MeetingSearch` title filter.
/// `allContent` consumes index groups (already ranked and grouped by
/// `MeetingSearchIndex.search`) and flattens them to one hit per meeting,
/// keeping the index's stable ordering. Pure and synchronous so the view
/// layer stays testable; fetching from the actor index happens at the call
/// site the orchestrator wires into MeetingSidebarView.swift.
enum MeetingSidebarSearchRouter {
    static func results(
        query: String,
        scope: MeetingSidebarSearchScope,
        meetings: [Meeting],
        contentGroups: [MeetingContentGroup]
    ) -> [MeetingSidebarContentHit] {
        switch scope {
        case .titles:
            return MeetingSearch.matching(meetings, query: query).map { meeting in
                MeetingSidebarContentHit(
                    meetingID: meeting.id,
                    snippet: meeting.title
                )
            }
        case .allContent:
            let needle = MeetingSearch.normalized(query)
            guard !needle.isEmpty else { return [] }
            return contentGroups.map { group in
                // Prefer a hit whose snippet actually contains the folded
                // query; fall back to the best-ranked snippet otherwise.
                let snippet = group.hits.first {
                    MeetingSearch.normalized($0.snippet).contains(needle)
                }?.snippet ?? group.hits.first?.snippet ?? ""
                return MeetingSidebarContentHit(
                    meetingID: group.meetingID,
                    snippet: snippet
                )
            }
        }
    }
}

/// Sidebar-side handle on the file-backed full-text content index.
///
/// `AppModel` owns the authoritative instance: it creates it from the
/// library layout at startup and rebuilds it once. This store opens THE
/// SAME SQLite database through its own connection so the sidebar can
/// query concurrently - the index runs in WAL mode, so a second reader is
/// safe. The connection is created lazily on the first "all content"
/// search; if opening fails (derived data), the sidebar simply renders no
/// content hits.
@MainActor
final class MeetingSidebarContentIndexStore {
    private let layout: LibraryLayout
    private var index: MeetingSearchIndex?

    init(layout: LibraryLayout) {
        self.layout = layout
    }

    /// Existing connection or a newly opened one; nil when the index file
    /// cannot be opened.
    func currentIndex() -> MeetingSearchIndex? {
        if let index { return index }
        guard let created = try? MeetingSearchIndex(layout: layout) else {
            return nil
        }
        index = created
        return created
    }
}
