import Foundation
import StenoLibrary

/// A separate file per conversation avoids overwriting another iPad window's
/// conversations. The directory inherits the library's backup exclusion.
@MainActor
struct IOSChatSessionStore {
    let directory: URL

    init(layout: LibraryLayout) {
        directory = layout.root.appendingPathComponent("chats", isDirectory: true)
    }

    func load() throws -> [LibraryChatSession] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try JSONDecoder().decode(LibraryChatSession.self, from: Data(contentsOf: $0)) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func save(_ session: LibraryChatSession, expected: LibraryChatSession? = nil) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var root = directory
        try root.setResourceValues(values)
        let file = directory.appendingPathComponent(session.id.uuidString).appendingPathExtension("json")
        if FileManager.default.fileExists(atPath: file.path) {
            let existing = try JSONDecoder().decode(LibraryChatSession.self, from: Data(contentsOf: file))
            guard existing == expected else { throw CocoaError(.fileWriteFileExists) }
        } else if expected != nil {
            throw CocoaError(.fileNoSuchFile)
        }
        try AtomicFile.write(JSONEncoder().encode(session), to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    func remove(_ session: LibraryChatSession) throws {
        let file = directory.appendingPathComponent(session.id.uuidString).appendingPathExtension("json")
        let current = try JSONDecoder().decode(LibraryChatSession.self, from: Data(contentsOf: file))
        guard current == session else { throw CocoaError(.fileWriteFileExists) }
        try FileManager.default.removeItem(at: file)
    }
}
