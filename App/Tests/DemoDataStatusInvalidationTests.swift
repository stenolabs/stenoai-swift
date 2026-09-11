import Foundation
import StenoDemo
import StenoDomain
import StenoIdentity
import StenoLibrary
import StenoPipeline
import Testing
@testable import steno_macos

@Suite("Demo data status invalidation")
@MainActor
struct DemoDataStatusInvalidationTests {
    @Test("a transcript correction changes an installed demo item to modified")
    func transcriptCorrectionInvalidatesInstalledDemoStatus() async throws {
        try await withInstalledDemoModel { model, library in
            let meeting = try #require(model.meetings.first { $0.isDemo })
            let revision = try await library.loadCurrentRevision(meetingID: meeting.id)
            let originalText = try #require(
                revision.turns.first?.segments.map(\.text).joined(separator: " ")
            )

            let edited = await model.saveTranscriptEdit(
                meetingID: meeting.id,
                revision: revision,
                turnIndex: 0,
                text: "\(originalText) corrected"
            )

            #expect(edited != nil)
            try await waitForDemoItem(
                meeting.id,
                toBecome: .modified,
                in: model
            )
        }
    }

    @Test("adopting a pending transcript invalidates the loaded demo status")
    func pendingTranscriptAdoptionInvalidatesDemoStatus() async throws {
        try await withInstalledDemoModel { model, library in
            let meeting = try #require(model.meetings.first { $0.isDemo })
            let current = try await library.loadCurrentRevision(meetingID: meeting.id)
            let text = try #require(
                current.turns.first?.segments.map(\.text).joined(separator: " ")
            )
            let userEdit = try TranscriptEdit.replacingText(
                in: current,
                turnIndex: 0,
                with: "\(text) edited before adoption"
            )
            _ = try await library.appendRevision(userEdit)
            let rerun = TranscriptRevision(
                meetingID: meeting.id,
                origin: .finalRun(RunID()),
                turns: current.turns
            )
            _ = try await library.appendRevision(rerun)

            #expect(!(await model.adoptPendingTranscript(for: meeting.id, expectedCurrentRevisionID: current.id, expectedCandidateID: rerun.id)))
            #expect(!(await model.adoptPendingTranscript(for: meeting.id, expectedCurrentRevisionID: userEdit.id, expectedCandidateID: RevisionID())))
            #expect(await model.adoptPendingTranscript(for: meeting.id, expectedCurrentRevisionID: userEdit.id, expectedCandidateID: rerun.id))
            try await waitForDemoItem(
                meeting.id,
                toBecome: .modified,
                in: model
            )
        }
    }

    @Test("persisted notes change an installed demo item to modified")
    func notesPersistenceInvalidatesInstalledDemoStatus() async throws {
        try await withInstalledDemoModel { model, _ in
            let meeting = try #require(model.meetings.first { $0.isDemo })
            let session = try #require(await model.notesSession(for: meeting.id))

            session.update("A local benchmark note")
            await session.flush()

            #expect(session.errorMessage == nil)
            try await waitForDemoItem(
                meeting.id,
                toBecome: .modified,
                in: model
            )
        }
    }

    @Test("an evidence-free speaker review changes an installed demo item to modified")
    func speakerReviewInvalidatesInstalledDemoStatus() async throws {
        try await withInstalledDemoModel { model, library in
            let meeting = try #require(model.meetings.first { $0.isDemo })
            let runID = RunID()
            let review = MeetingReviewDocument(
                runID: runID,
                clusters: [IdentityCluster(
                    meetingID: meeting.id,
                    runID: runID,
                    channel: "import",
                    clusterID: "demo-review",
                    recordingType: .imported,
                    embedding: [],
                    speechDurationSeconds: 1,
                    segmentCount: 1,
                    reviewState: .generic
                )]
            )
            try MeetingReviewStore(layout: library.layout).save(
                review,
                meetingID: meeting.id
            )

            await model.demoDataDidPersistSpeakerReview(for: meeting.id)

            try await waitForDemoItem(
                meeting.id,
                toBecome: .modified,
                in: model
            )
        }
    }

    @Test("quarantining a damaged report invalidates the status without polling")
    func damagedReportInvalidatesInstalledDemoStatus() async throws {
        try await withInstalledDemoModel { model, library in
            let reportMeeting = try #require(await demoMeetingWithReport(in: model))
            let reports = await model.reports(for: reportMeeting.id)
            let report = try #require(reports.first)
            try Data("not json".utf8).write(
                to: library.layout.report(reportMeeting.id, runID: report.runID)
            )

            let remainingReports = await model.reports(for: reportMeeting.id)

            #expect(remainingReports.isEmpty)
            try await waitForDemoItem(
                reportMeeting.id,
                toBecome: .modified,
                in: model
            )
        }
    }

    @Test("a later demo event retries a failed reconciliation")
    func statusFailureDoesNotLeaveInstalledDemoDataActionable() async throws {
        try await withInstalledDemoModel { model, library in
            let meeting = try #require(model.meetings.first { $0.isDemo })
            try await MeetingNotesStore(layout: library.layout).setNotes(
                meeting.id,
                to: "A local mutation before checking"
            )
            try Data("{".utf8).write(to: library.layout.folders)

            await model.demoDataMeetingContentDidChange(meeting.id)
            try await waitForStatusFailure(in: model)

            #expect(model.demoDataStatus == nil)
            #expect(
                DemoDataActionPolicy.actions(for: model.demoDataStatus)
                    == .init(canInstall: false, canReplace: false, canRemove: false)
            )

            // Ein fehlgeschlagener Abgleich kann die defekte Ordnerdatei
            // bereits in seinen eigenen Recovery-Schritten entfernt haben.
            // Fehlend bedeutet hier ebenso einen wieder lesbaren Zustand.
            try? FileManager.default.removeItem(at: library.layout.folders)
            await model.demoDataMeetingContentDidChange(meeting.id)
            try await waitForStatusRecovery(in: model)

            #expect(model.demoDataStatusError == nil)
            #expect(model.demoDataStatus != nil)
        }
    }

    private func withInstalledDemoModel(
        _ operation: (AppModel, Library) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Steno-DemoDataStatusInvalidationTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let libraryURL = root.appendingPathComponent("Library", isDirectory: true)
        let modelsURL = root.appendingPathComponent("Models", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let model = AppModel(
            libraryURL: libraryURL,
            modelCacheDirectoryOverride: modelsURL
        )
        #expect(model.resolvedLibraryURL == libraryURL.standardizedFileURL)
        #expect(model.resolvedModelCacheDirectory == modelsURL.standardizedFileURL)
        await model.bootstrap()
        let runtime = try #require(model.runtime)
        #expect(runtime.library.layout.root == libraryURL.standardizedFileURL)

        do {
            await model.installDemoData()
            try await waitForInstalledStatus(in: model)
            try await operation(model, runtime.library)
            await runtime.coordinator.stop()
        } catch {
            await runtime.coordinator.stop()
            throw error
        }
    }

    private func waitForInstalledStatus(in model: AppModel) async throws {
        try await waitUntil {
            guard let status = model.demoDataStatus else { return false }
            return status.items.allSatisfy { $0.state == .installed }
        }
    }

    private func waitForDemoItem(
        _ meetingID: MeetingID,
        toBecome state: DemoLibraryItemState,
        in model: AppModel
    ) async throws {
        try await waitUntil {
            model.demoDataStatus?.items.first { $0.meetingID == meetingID }?.state
                == state
        }
    }

    private func waitForStatusFailure(in model: AppModel) async throws {
        try await waitUntil {
            model.demoDataStatusError != nil && !model.isCheckingDemoDataStatus
        }
    }

    private func waitForStatusRecovery(in model: AppModel) async throws {
        try await waitUntil {
            model.demoDataStatus != nil
                && model.demoDataStatusError == nil
                && !model.isCheckingDemoDataStatus
        }
    }

    private func demoMeetingWithReport(
        in model: AppModel
    ) async -> Meeting? {
        for meeting in model.meetings where meeting.isDemo {
            if !(await model.reports(for: meeting.id)).isEmpty {
                return meeting
            }
        }
        return nil
    }

    private func waitUntil(
        timeout: Duration = .seconds(3),
        condition: @escaping @MainActor () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw DemoDataStatusInvalidationTestError.timedOut
    }

}

private enum DemoDataStatusInvalidationTestError: Error {
    case timedOut
}
