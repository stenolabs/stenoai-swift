import Foundation
import StenoDomain
import StenoLibrary
import StenoPipeline
import Testing
@testable import Steno

@Suite("iOS meeting playback lifetime")
@MainActor
struct MeetingAudioPlaybackStateTests {
    @Test("the initial load exposes registered audio without a transcript")
    func initialLoad() async throws {
        let fixture = try await PlaybackStateFixture.make()
        defer { fixture.remove() }
        let state = MeetingAudioPlaybackState()
        await state.load(app: fixture.app, meetingID: fixture.meeting.id)
        #expect(state.sources.map(\.id) == [fixture.asset.id])
        #expect(state.selectedID == fixture.asset.id)
        #expect(state.loadError == nil)
        #expect(!state.isLoading)
        state.leave(app: fixture.app)
    }

    @Test("leaving the meeting discards a delayed load and stale button request")
    func leaveInvalidatesPendingWork() async throws {
        let fixture = try await PlaybackStateFixture.make()
        defer { fixture.remove() }
        let (started, startSignal) = AsyncStream<Void>.makeStream()
        let (released, releaseSignal) = AsyncStream<Void>.makeStream()
        let state = MeetingAudioPlaybackState { library, meetingID in
            let sources = try await MeetingAudioSource.load(in: library, meetingID: meetingID)
            startSignal.yield(())
            var release = released.makeAsyncIterator()
            _ = await release.next()
            return sources
        }
        let task = Task { await state.load(app: fixture.app, meetingID: fixture.meeting.id) }
        var start = started.makeAsyncIterator()
        _ = await start.next()
        let request = state.generation
        state.leave(app: fixture.app)
        releaseSignal.yield(())
        await task.value
        #expect(state.sources.isEmpty)
        #expect(state.selectedID == nil)
        #expect(state.loadError == nil)
        #expect(!state.isLoading)
        await state.reload(app: fixture.app, request: request)
        #expect(state.sources.isEmpty)
        #expect(fixture.app.audioPlayback.sourceURL == nil)
        startSignal.finish()
        releaseSignal.finish()
    }
}

@MainActor
private struct PlaybackStateFixture {
    let root: URL
    let app: AppModel
    let meeting: Meeting
    let asset: MediaAsset

    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Steno-PlaybackStateTests-\(UUID().uuidString)")
        let libraryRoot = root.appendingPathComponent("Library")
        let library = try Library.open(at: libraryRoot)
        let meeting = try await library.createMeeting(title: "Synthetic playback", status: .ready)
        let asset = MediaAsset(
            meetingID: meeting.id, kind: .micTrack, sampleRate: 16_000,
            duration: 1, provenanceKey: "synthetic-state-fixture", fileName: "audio.caf"
        )
        // State loading validates registration and paths, not audio decoding.
        try Data("synthetic placeholder".utf8).write(to: library.layout.mediaFile(meeting.id, fileName: asset.fileName))
        try JSONEncoder().encode(asset).write(to: library.layout.mediaMetadata(meeting.id, assetID: asset.id))
        let jobs = try JobStore(layout: library.layout)
        let runtime = PipelineRuntime(
            library: library, jobStore: jobs,
            coordinator: PipelineCoordinator(library: library, jobStore: jobs, providers: [:], locale: Locale(identifier: "en-US"))
        )
        let app = AppModel(
            prepareLibraryBackup: { _, _ in }, refreshLanguage: { _ in },
            startPipeline: { _, _, _ in runtime }, libraryURL: libraryRoot
        )
        await app.bootstrap()
        return Self(root: root, app: app, meeting: meeting, asset: asset)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
