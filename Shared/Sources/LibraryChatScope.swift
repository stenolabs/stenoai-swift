import StenoDomain

/// What subset of the library one Library Chat session asks across.
/// Persisted per session inside the sessions store; self-heals against
/// deleted folders/meetings before each turn.
enum LibraryChatScope: Equatable, Sendable {
    case all
    case folder(FolderID)
    case meetings([MeetingID])

    /// Drops dead references: an unknown folder or an empty meeting set
    /// falls back to `.all`; known-but-deleted meeting ids are filtered out.
    static func healed(_ scope: LibraryChatScope, folders: [Folder], meetings: [Meeting]) -> LibraryChatScope {
        switch scope {
        case .all:
            return .all
        case .folder(let folderID):
            return folders.contains { $0.id == folderID } ? .folder(folderID) : .all
        case .meetings(let ids):
            let liveIDs = Set(meetings.map(\.id))
            let surviving = ids.filter { liveIDs.contains($0) }
            return surviving.isEmpty ? .all : .meetings(surviving)
        }
    }
}
