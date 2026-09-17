import StenoDomain

/// What subset of the library one Library Chat session asks across.
/// Persisted per session inside the sessions store; self-heals against
/// deleted folders/meetings before each turn.
enum LibraryChatScope: Equatable, Sendable {
    case all
    case folder(FolderID)
    case meetings([MeetingID])

    /// Drops dead references without broadening what the user selected.
    /// A scope whose last target disappeared becomes an empty explicit
    /// meeting selection and therefore requires a new user choice.
    static func healed(_ scope: LibraryChatScope, folders: [Folder], meetings: [Meeting]) -> LibraryChatScope {
        switch scope {
        case .all:
            return .all
        case .folder(let folderID):
            return folders.contains { $0.id == folderID } ? .folder(folderID) : .meetings([])
        case .meetings(let ids):
            let liveIDs = Set(meetings.map(\.id))
            let surviving = ids.filter { liveIDs.contains($0) }
            return .meetings(surviving)
        }
    }

    var requiresExplicitSelection: Bool {
        if case .meetings(let ids) = self {
            return ids.isEmpty
        }
        return false
    }
}
