import Foundation
import StenoDomain
import Testing
@testable import steno_macos

@Suite("App model folder behavior")
@MainActor
struct AppModelFolderBehaviorTests {
    @Test("a failed folder refresh keeps the last visible folder structure")
    func failedFolderRefreshKeepsVisibleFolders() async throws {
        try await withIsolatedModel { model, libraryURL in
            let folder = try #require(
                await model.createFolder(named: "Arbeit")
            )
            let visibleFolders = model.folders
            #expect(visibleFolders == [folder])

            let foldersURL = libraryURL.appendingPathComponent("folders.json")
            let persistedFolders = try Data(contentsOf: foldersURL)

            try Data("{".utf8).write(
                to: foldersURL
            )
            await model.refreshMeetings()

            #expect(model.folders == visibleFolders)
            #expect(model.startupState == .ready)
            #expect(model.runtime != nil)
            #expect(model.canStartRecording)
            let issue = try #require(
                model.libraryIssues.first { $0.id == .folders }
            )

            try persistedFolders.write(to: foldersURL)
            await model.retryLibraryIssue(issue)

            #expect(model.libraryIssues.allSatisfy { $0.id != .folders })
            #expect(model.folders == visibleFolders)
        }
    }

    @Test("a meeting-list retry preserves the open runtime and existing meetings")
    func meetingListRetryDoesNotRestartTheRuntime() async throws {
        try await withIsolatedModel { model, libraryURL in
            let runtime = try #require(model.runtime)
            _ = try #require(await model.createFolder(named: "Retained folder"))
            let meeting = try await runtime.library.createMeeting(
                title: "Persisted meeting",
                status: .ready
            )
            await model.refreshMeetings()
            #expect(model.meetings.contains { $0.id == meeting.id })

            let metadataURL = runtime.library.layout.meetingMetadata(meeting.id)
            let persistedMetadata = try Data(contentsOf: metadataURL)
            let foldersURL = libraryURL.appendingPathComponent("folders.json")
            let persistedFolders = try Data(contentsOf: foldersURL)
            try Data("{".utf8).write(to: metadataURL)
            try Data("{".utf8).write(to: foldersURL)

            await model.refreshMeetings()

            #expect(model.startupState == .ready)
            #expect(model.runtime != nil)
            #expect(model.canStartRecording)
            #expect(model.meetings.contains { $0.id == meeting.id })
            let issue = try #require(
                model.libraryIssues.first { $0.id == .meetings }
            )
            #expect(model.libraryIssues.contains { $0.id == .folders })

            try persistedMetadata.write(to: metadataURL)
            await model.retryLibraryIssue(issue)

            #expect(model.libraryIssues.allSatisfy { $0.id != .meetings })
            #expect(model.libraryIssues.contains { $0.id == .folders })
            #expect(model.meetings.contains { $0.id == meeting.id })
            #expect(model.runtime?.library === runtime.library)

            try persistedFolders.write(to: foldersURL)
            let folderIssue = try #require(
                model.libraryIssues.first { $0.id == .folders }
            )
            await model.retryLibraryIssue(folderIssue)
            #expect(model.libraryIssues.isEmpty)
        }
    }

    @Test("folder deletion unfiles meetings from the current library state")
    func folderDeletionUsesCurrentLibraryState() async throws {
        try await withIsolatedModel { model, _ in
            let runtime = try #require(model.runtime)
            let folder = try #require(
                await model.createFolder(named: "Arbeit")
            )
            let meeting = try await runtime.library.createMeeting(
                title: "Extern geänderte Zuordnung",
                status: .ready
            )
            await model.refreshMeetings()
            #expect(model.meetings.first { $0.id == meeting.id }?.folderID == nil)

            _ = try await runtime.library.setMeetingFolder(
                meeting.id,
                folderID: folder.id
            )
            #expect(model.meetings.first { $0.id == meeting.id }?.folderID == nil)

            #expect(await model.deleteFolder(folder.id))

            let persisted = try await runtime.library.loadMeeting(meeting.id)
            #expect(persisted.folderID == nil)
        }
    }

    @Test("moving a folder reports success after refreshing its parent")
    func folderMoveReportsSuccess() async throws {
        try await withIsolatedModel { model, _ in
            let work = try #require(
                await model.createFolder(named: "Arbeit")
            )
            let product = try #require(
                await model.createFolder(named: "Produktvorstellung")
            )

            #expect(await model.moveFolder(product.id, to: work.id))
            #expect(
                model.folders.first { $0.id == product.id }?.parentFolderID
                    == work.id
            )
        }
    }

    private func withIsolatedModel(
        _ operation: (AppModel, URL) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Steno-AppModelFolderBehaviorTests-\(UUID().uuidString)",
                isDirectory: true
            )
        let libraryURL = root.appendingPathComponent("Library", isDirectory: true)
        let modelURL = root.appendingPathComponent("Models", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let model = AppModel(
            libraryURL: libraryURL,
            modelCacheDirectoryOverride: modelURL
        )
        #expect(model.resolvedLibraryURL == libraryURL.standardizedFileURL)
        #expect(model.resolvedModelCacheDirectory == modelURL.standardizedFileURL)
        await model.bootstrap()
        let runtime = try #require(model.runtime)
        #expect(runtime.library.layout.root == libraryURL.standardizedFileURL)
        _ = try #require(model.folderStore)

        do {
            try await operation(model, libraryURL)
            await model.stopBackgroundLibraryTasksForTesting()
            await model.runtime?.coordinator.stop()
        } catch {
            await model.stopBackgroundLibraryTasksForTesting()
            await model.runtime?.coordinator.stop()
            throw error
        }
    }

}

@Suite("App model meeting deletion", .serialized)
@MainActor
struct AppModelMeetingDeletionTests {
    private enum FixtureError: Error {
        case rejectedTrashMove
    }

    @Test("batch deletion keeps the complete operation available for undo")
    func batchDeletionAndUndo() async throws {
        try await withIsolatedModel { model, trashURL in
            let runtime = try #require(model.runtime)
            let first = try await runtime.library.createMeeting(
                title: "First",
                status: .ready
            )
            let second = try await runtime.library.createMeeting(
                title: "Second",
                status: .ready
            )
            await model.refreshMeetings()
            model.selectedMeetingIDs = [first.id, second.id]

            await model.deleteMeetings([first.id, second.id])

            #expect(model.meetings.isEmpty)
            #expect(model.selectedMeetingIDs.isEmpty)
            let undo = try #require(model.pendingTrashUndo)
            #expect(undo.items.map(\.meetingID) == [first.id, second.id])
            #expect(FileManager.default.fileExists(
                atPath: trashURL.appendingPathComponent(first.id.description).path
            ))
            #expect(FileManager.default.fileExists(
                atPath: trashURL.appendingPathComponent(second.id.description).path
            ))

            await model.restoreTrashedMeetings()

            #expect(model.pendingTrashUndo == nil)
            #expect(Set(model.meetings.map(\.id)) == [first.id, second.id])
            #expect(FileManager.default.fileExists(
                atPath: runtime.library.layout.meetingDirectory(first.id).path
            ))
            #expect(FileManager.default.fileExists(
                atPath: runtime.library.layout.meetingDirectory(second.id).path
            ))
        }
    }

    @Test("a failed trash move keeps that meeting's processing records")
    func failedTrashMovePreservesJobs() async throws {
        try await withIsolatedModel(failingTrashCall: 2) { model, _ in
            let runtime = try #require(model.runtime)
            let first = try await runtime.library.createMeeting(
                title: "First",
                status: .ready
            )
            let second = try await runtime.library.createMeeting(
                title: "Second",
                status: .ready
            )
            let retainedJob = Job(
                kind: .finalASR,
                meetingID: second.id,
                status: .failed
            )
            try await runtime.jobStore.enqueue(retainedJob)
            await model.refreshMeetings()

            await model.deleteMeetings([first.id, second.id])

            #expect(model.meetings.map(\.id) == [second.id])
            #expect(try await runtime.jobStore.load(retainedJob.id) == retainedJob)
            let undo = try #require(model.pendingTrashUndo)
            #expect(undo.items.map(\.meetingID) == [first.id])

            await model.restoreTrashedMeetings()

            #expect(Set(model.meetings.map(\.id)) == [first.id, second.id])
        }
    }

    @Test("moving meetings to trash blocks recording until the move finishes")
    func trashMoveBlocksRecordingStart() async throws {
        let enteredTrashMove = AsyncStream.makeStream(of: Void.self)
        let releaseTrashMove = AsyncStream.makeStream(of: Void.self)

        try await withIsolatedModel(trashCheckpoint: {
            enteredTrashMove.continuation.yield()
            var releases = releaseTrashMove.stream.makeAsyncIterator()
            _ = await releases.next()
        }) { model, _ in
            let runtime = try #require(model.runtime)
            let meeting = try await runtime.library.createMeeting(
                title: "Protected recording start",
                status: .ready
            )
            await model.refreshMeetings()
            #expect(model.canStartRecording)

            let deletion = Task {
                await model.deleteMeetings([meeting.id])
            }
            var entries = enteredTrashMove.stream.makeAsyncIterator()
            _ = await entries.next()

            #expect(model.isMovingMeetingsToTrash)
            #expect(!model.canStartRecording)

            releaseTrashMove.continuation.yield()
            releaseTrashMove.continuation.finish()
            await deletion.value

            #expect(!model.isMovingMeetingsToTrash)
            #expect(model.canStartRecording)
        }
        enteredTrashMove.continuation.finish()
    }

    private func withIsolatedModel(
        failingTrashCall: Int? = nil,
        trashCheckpoint: @escaping @MainActor () async -> Void = {},
        _ operation: (AppModel, URL) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Steno-AppModelMeetingDeletionTests-\(UUID().uuidString)",
                isDirectory: true
            )
        let libraryURL = root.appendingPathComponent("Library", isDirectory: true)
        let modelURL = root.appendingPathComponent("Models", isDirectory: true)
        let trashURL = root.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(
            at: trashURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        var trashCallCount = 0
        let model = AppModel(
            meetingTrasher: { library, meetingID in
                trashCallCount += 1
                if trashCallCount == failingTrashCall {
                    throw FixtureError.rejectedTrashMove
                }
                await trashCheckpoint()
                let source = library.layout.meetingDirectory(meetingID)
                let destination = trashURL.appendingPathComponent(
                    meetingID.description,
                    isDirectory: true
                )
                try FileManager.default.moveItem(at: source, to: destination)
                return destination
            },
            libraryURL: libraryURL,
            modelCacheDirectoryOverride: modelURL
        )
        await model.bootstrap()
        _ = try #require(model.runtime)

        do {
            try await operation(model, trashURL)
            await model.stopBackgroundLibraryTasksForTesting()
            await model.runtime?.coordinator.stop()
        } catch {
            await model.stopBackgroundLibraryTasksForTesting()
            await model.runtime?.coordinator.stop()
            throw error
        }
    }
}
