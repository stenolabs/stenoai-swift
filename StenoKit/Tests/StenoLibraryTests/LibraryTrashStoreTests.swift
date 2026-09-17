import Foundation
import StenoDomain
import Testing
@testable import StenoLibrary

@Suite("Private library trash")
struct LibraryTrashStoreTests {
    @Test("a private trash move preserves originals and can be discovered after reopening")
    func survivesReopening() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try Library.open(at: root)
        let meeting = try await library.createMeeting(title: "Synthetic original", status: .ready)
        let bytes = Data("Synthetic immutable recording".utf8)
        let original = library.layout.mediaDirectory(meeting.id).appendingPathComponent("original.bin")
        try bytes.write(to: original)
        let store = LibraryTrashStore(layout: library.layout)
        let destination = try LibraryMutationCoordination.withExclusiveAccess(layout: library.layout) {
            try store.move(meeting.id)
        }
        #expect(try await library.listMeetings().isEmpty)
        let entries = try LibraryTrashStore(layout: library.layout).entries()
        let entry = try #require(entries.first)
        #expect(entries.count == 1)
        #expect(entry.meeting == meeting)
        #expect(entry.directory == destination)
        #expect(try Data(contentsOf: destination.appendingPathComponent("media/original.bin")) == bytes)
        #expect(try store.directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        try FileManager.default.moveItem(at: destination, to: library.layout.meetingDirectory(meeting.id))
        #expect(try store.entries().isEmpty)
        let second = try LibraryMutationCoordination.withExclusiveAccess(layout: library.layout) {
            try store.move(meeting.id)
        }
        #expect(second != destination)
        #expect(try store.entries().count == 1)
        let empty = store.directory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        #expect(try store.list().entries.count == 1)
        #expect(try store.list().unreadableEntryCount == 0)
        let broken = store.directory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        try Data("incomplete receipt".utf8).write(to: broken.appendingPathComponent("receipt.json"))
        #expect(try store.list().entries.count == 1)
        #expect(try store.list().unreadableEntryCount == 1)
        #expect(FileManager.default.fileExists(atPath: second.path))
    }

    @Test("a redirected trash directory is rejected before moving an original")
    func rejectsSymlink() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try Library.open(at: root)
        let meeting = try await library.createMeeting(title: "Synthetic original", status: .ready)
        let external = root.appendingPathComponent("redirect")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
        let store = LibraryTrashStore(layout: library.layout)
        try FileManager.default.createSymbolicLink(at: store.directory, withDestinationURL: external)
        #expect(throws: (any Error).self) {
            try LibraryMutationCoordination.withExclusiveAccess(layout: library.layout) { try store.move(meeting.id) }
        }
        #expect(FileManager.default.fileExists(atPath: library.layout.meetingMetadata(meeting.id).path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: external.path).isEmpty)
    }
}
