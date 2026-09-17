import Foundation
import StenoDomain
import StenoIntelligence

/// One persisted chat turn in a library chat session.
struct LibraryChatMessage: Codable, Equatable, Identifiable, Sendable {
    enum Role: String, Codable, Sendable {
        case user
        case assistant
    }

    var id: UUID
    var role: Role
    var text: String
    var createdAt: Date

    init(id: UUID = UUID(), role: Role, text: String, createdAt: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
    }
}

/// One named conversation over the whole meeting library. Sessions persist
/// using each platform's local session store.
struct LibraryChatSession: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var title: String
    var createdAt: Date
    var messages: [LibraryChatMessage]
    /// What this conversation asks across. Sessions written before scoping
    /// existed decode as `.all`.
    var scope: LibraryChatScope = .all

    init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = Date(),
        messages: [LibraryChatMessage] = [],
        scope: LibraryChatScope = .all
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.messages = messages
        self.scope = scope
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, createdAt, messages, scope
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        messages = try container.decode([LibraryChatMessage].self, forKey: .messages)
        scope = try container.decodeIfPresent(LibraryChatScope.self, forKey: .scope) ?? .all
    }
}

/// Cross-note ask scope for one Library Chat turn: the whole library, a
/// single folder, or an explicit set of (non-live) meetings.
extension LibraryChatScope: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, folderID, meetingIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "all": self = .all
        case "folder":
            self = .folder(try container.decode(FolderID.self, forKey: .folderID))
        case "meetings":
            self = .meetings(try container.decode([MeetingID].self, forKey: .meetingIDs))
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container,
                debugDescription: "Unknown chat scope kind \(other)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .all:
            try container.encode("all", forKey: .kind)
        case .folder(let folderID):
            try container.encode("folder", forKey: .kind)
            try container.encode(folderID, forKey: .folderID)
        case .meetings(let ids):
            try container.encode("meetings", forKey: .kind)
            try container.encode(ids, forKey: .meetingIDs)
        }
    }
}
