import Foundation
import StenoDomain
import StenoIntelligence
import StenoLibrary
import StenoPipeline
import Testing
@testable import Steno

@Suite("iOS parity integration")
@MainActor
struct IOSParityTests {
    @Test("meeting duration combines appended sessions without double-counting simultaneous tracks")
    func appendedDuration() async throws {
        let fixture = try await ParityFixture.make()
        defer { fixture.remove() }
        #expect(await fixture.app.duration(for: fixture.meeting.id) == nil)
        let source = fixture.root.appendingPathComponent("synthetic-track.bin")
        try Data("Synthetic metadata fixture; never decoded".utf8).write(to: source)
        for (kind, duration) in [(MediaAsset.Kind.micTrack, 10.0), (.systemTrack, 8.0), (.micTrack, 5.0)] {
            _ = try await fixture.library.registerMediaAsset(
                for: fixture.meeting.id, sourceURL: source, kind: kind, sampleRate: 16_000, duration: duration
            )
        }
        #expect(await fixture.app.duration(for: fixture.meeting.id) == 15)
    }

    @Test("the iOS trash path preserves originals for undo and restoration after restart")
    func platformTrashUndo() async throws {
        let fixture = try await ParityFixture.make()
        defer { fixture.remove() }
        let notes = MeetingNotesStore(layout: fixture.library.layout)
        try await notes.setNotes(fixture.meeting.id, to: "Synthetic recoverable note")
        _ = try await fixture.app.deleteMeeting(fixture.meeting.id)
        let receipt = try #require(fixture.app.pendingTrashUndo)
        #expect(FileManager.default.fileExists(atPath: receipt.trashedURL.path))
        #expect(try await fixture.app.restoreLastTrashedMeeting() == fixture.meeting.id)
        #expect(try await notes.notes(fixture.meeting.id) == "Synthetic recoverable note")
        _ = try await fixture.app.deleteMeeting(fixture.meeting.id)
        let reopened = await ParityFixture.makeApp(library: fixture.library, jobs: fixture.jobs)
        #expect(reopened.pendingTrashUndo == nil)
        let entry = try #require(try await reopened.recentlyDeletedMeetings().entries.first)
        #expect(entry.meeting.id == fixture.meeting.id)
        #expect(try await reopened.restoreDeletedMeeting(entry) == fixture.meeting.id)
        #expect(try await reopened.recentlyDeletedMeetings().entries.isEmpty)
        #expect(try await notes.notes(fixture.meeting.id) == "Synthetic recoverable note")
        await #expect(throws: (any Error).self) { _ = try await reopened.restoreDeletedMeeting(entry) }
    }

    @Test("content search finds notes, refreshes edits and filters removed meetings")
    func contentSearch() async throws {
        let fixture = try await ParityFixture.make()
        defer { fixture.remove() }
        let notes = MeetingNotesStore(layout: fixture.library.layout)
        try await notes.setNotes(fixture.meeting.id, to: "Synthetic telescope agenda")
        #expect(try await fixture.app.searchMeetingContents("telescope").map(\.meetingID) == [fixture.meeting.id])
        try await notes.setNotes(fixture.meeting.id, to: "Synthetic microscope agenda")
        #expect(try await fixture.app.searchMeetingContents("telescope").isEmpty)
        #expect(try await fixture.app.searchMeetingContents("microscope").count == 1)
        try FileManager.default.removeItem(at: fixture.library.layout.meetingDirectory(fixture.meeting.id))
        await fixture.app.reloadMeetings()
        #expect(try await fixture.app.searchMeetingContents("microscope").isEmpty)
    }

    @Test("short recording confirmation retains job identity and is idempotent")
    func confirmsShortRecording() async throws {
        let fixture = try await ParityFixture.make()
        defer { fixture.remove() }
        let job = Job.finalASR(for: fixture.meeting)
        let decision = ShortRecordingDecision(job: job, duration: 5, continuesExistingMeeting: false)
        try ShortRecordingDecisionStore(layout: fixture.library.layout).save(decision)
        #expect(try await fixture.app.pendingShortRecording(fixture.meeting.id) == decision)
        try await fixture.app.confirmShortRecording(decision)
        try await fixture.app.confirmShortRecording(decision)
        #expect(try await fixture.jobs.list().map(\.id) == [job.id])
        #expect(try await fixture.app.pendingShortRecording(fixture.meeting.id) == nil)
    }

    @Test("chat storage rejects stale saves and deletes and survives reopening")
    func chatStorageConflicts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = IOSChatSessionStore(layout: LibraryLayout(root: root))
        let initial = LibraryChatSession(title: "Synthetic session")
        try store.save(initial)
        #expect(try IOSChatSessionStore(layout: LibraryLayout(root: root)).load() == [initial])
        var edited = initial
        edited.messages.append(LibraryChatMessage(role: .user, text: "Synthetic question"))
        try store.save(edited, expected: initial)
        #expect(throws: CocoaError.self) { try store.save(initial, expected: initial) }
        #expect(throws: CocoaError.self) { try store.remove(initial) }
        #expect(try store.load() == [edited])
        let values = try store.directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
        try store.remove(edited)
        #expect(try store.load().isEmpty)
    }

    @Test("stale chat scopes never expand to the whole library")
    func staleChatScopeRequiresExplicitSelection() {
        let deletedFolder = FolderID()
        let deletedMeeting = MeetingID()

        let folderScope = LibraryChatScope.healed(
            .folder(deletedFolder), folders: [], meetings: []
        )
        let meetingScope = LibraryChatScope.healed(
            .meetings([deletedMeeting]), folders: [], meetings: []
        )

        #expect(folderScope == .meetings([]))
        #expect(meetingScope == .meetings([]))
        #expect(folderScope.requiresExplicitSelection)
        #expect(meetingScope.requiresExplicitSelection)
    }
}

@MainActor
private struct ParityFixture {
    let root: URL
    let library: Library
    let meeting: Meeting
    let jobs: JobStore
    let app: AppModel

    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Steno-Parity-\(UUID())")
        let library = try Library.open(at: root)
        let meeting = try await library.createMeeting(title: "Synthetic planning", status: .ready)
        let jobs = try JobStore(layout: library.layout)
        let app = await makeApp(library: library, jobs: jobs)
        return Self(root: root, library: library, meeting: meeting, jobs: jobs, app: app)
    }

    static func makeApp(library: Library, jobs: JobStore) async -> AppModel {
        let runtime = PipelineRuntime(library: library, jobStore: jobs,
            coordinator: PipelineCoordinator(library: library, jobStore: jobs, providers: [:], locale: Locale(identifier: "en-US")))
        let app = AppModel(prepareLibraryBackup: { _, _ in }, refreshLanguage: { _ in },
                           startPipeline: { _, _, _ in runtime }, libraryURL: library.layout.root)
        await app.bootstrap()
        return app
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
