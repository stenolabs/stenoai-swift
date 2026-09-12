import Darwin
import Foundation
import StenoDomain

/// Recoverable storage for platforms without a system Trash. Originals remain
/// intact inside the library, including across process restarts.
public struct LibraryTrashStore: Sendable {
    public struct Entry: Identifiable, Sendable {
        public let id: UUID
        public let meeting: Meeting
        public let directory: URL
        public let deletedAt: Date
    }

    public struct Listing: Sendable {
        public let entries: [Entry]
        public let unreadableEntryCount: Int
    }

    private struct Receipt: Codable {
        let id: UUID
        let meetingID: MeetingID
        let deletedAt: Date
    }

    private let layout: LibraryLayout
    public var directory: URL { layout.root.appendingPathComponent(".trash", isDirectory: true) }

    public init(layout: LibraryLayout) { self.layout = layout }

    public func entries() throws -> [Entry] {
        try list().entries
    }

    public func list() throws -> Listing {
        try LibraryMutationCoordination.withExclusiveAccess(layout: layout) {
            guard FileManager.default.fileExists(atPath: directory.path) else {
                return Listing(entries: [], unreadableEntryCount: 0)
            }
            try requirePrivateDirectory(directory)
            var entries: [Entry] = []
            var unreadable = 0
            for container in try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            ) {
                guard let id = UUID(uuidString: container.lastPathComponent) else { continue }
                do {
                    try requirePrivateDirectory(container)
                    // A crash before receipt creation must not hide other originals.
                    guard try !FileManager.default.contentsOfDirectory(atPath: container.path).isEmpty else { continue }
                    let receiptURL = container.appendingPathComponent("receipt.json")
                    let receipt = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: receiptURL))
                    guard receipt.id == id else { throw CocoaError(.fileReadCorruptFile) }
                    let original = container.appendingPathComponent(receipt.meetingID.description, isDirectory: true)
                    // A prepared move that never happened, or an already restored entry.
                    guard FileManager.default.fileExists(atPath: original.path) else { continue }
                    try requireDirectory(original)
                    let metadata = original.appendingPathComponent("meeting.json")
                    let meeting = try JSONDecoder().decode(Meeting.self, from: Data(contentsOf: metadata))
                    guard meeting.id == receipt.meetingID,
                          meeting.schemaVersion == Meeting.currentSchemaVersion else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    entries.append(Entry(id: id, meeting: meeting, directory: original.resolvingSymlinksInPath(), deletedAt: receipt.deletedAt))
                } catch {
                    // Keep damaged entries on disk and make the limitation visible,
                    // while preserving access to every independently valid entry.
                    unreadable += 1
                }
            }
            return Listing(entries: entries.sorted { $0.deletedAt < $1.deletedAt },
                           unreadableEntryCount: unreadable)
        }
    }

    /// The caller holds the library's exclusive mutation lock.
    package func move(_ meetingID: MeetingID) throws -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: false,
                                   attributes: [.posixPermissions: 0o700])
        }
        try requirePrivateDirectory(directory)
        var protectedDirectory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try protectedDirectory.setResourceValues(values)
        guard try protectedDirectory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true else {
            throw CocoaError(.fileWriteNoPermission)
        }

        let receipt = Receipt(id: UUID(), meetingID: meetingID, deletedAt: Date())
        let container = directory.appendingPathComponent(receipt.id.uuidString, isDirectory: true)
        try fm.createDirectory(at: container, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        let receiptURL = container.appendingPathComponent("receipt.json")
        try AtomicFile.write(JSONEncoder().encode(receipt), to: receiptURL)
        try AtomicFile.synchronizeDirectory(directory)
        try AtomicFile.synchronizeDirectory(layout.root)
        // Complete all fallible metadata work before moving the sole original.
        let source = layout.meetingDirectory(meetingID)
        try requireDirectory(source)
        let destination = container.appendingPathComponent(meetingID.description, isDirectory: true)
        try fm.moveItem(at: source, to: destination)
        return destination.resolvingSymlinksInPath()
    }

    private func requireDirectory(_ url: URL) throws {
        var status = stat()
        guard lstat(url.path, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == geteuid() else {
            throw CocoaError(.fileReadNoPermission)
        }
    }

    private func requirePrivateDirectory(_ url: URL) throws {
        try requireDirectory(url)
        var status = stat()
        guard lstat(url.path, &status) == 0,
              status.st_mode & 0o7777 == 0o700 else {
            throw CocoaError(.fileReadNoPermission)
        }
    }
}
