import Foundation
import StenoDomain
import StenoLibrary
import Testing
@testable import Steno

@Suite("Meeting empty presentation")
struct MeetingPresentationTests {
    @Test("retranscription copy explains revisions, speaker clusters, and corrections")
    func retranscriptionCopyExplainsConsequences() {
        #expect(
            english(MeetingActionCopy.retranscriptionMessage)
                == "Steno adds a new transcript revision and keeps the current transcript and corrections as earlier revisions.\n"
                + "Speaker separation runs again with new cluster identifiers, so speakers must be confirmed again.\n"
                + "Your corrections are never silently overwritten."
        )
    }

    @Test("recording meetings disable destructive and replacement actions")
    func recordingMeetingActionsAreDisabled() {
        #expect(!MeetingActionPolicy.canRetranscribe(status: .recording))
        #expect(!MeetingActionPolicy.canDelete(status: .recording))
        #expect(MeetingActionPolicy.canRetranscribe(status: .ready))
        #expect(MeetingActionPolicy.canDelete(status: .ready))
    }

    @Test("retry job snapshots publish only for the current meeting generation")
    func retryJobSnapshotFollowsCurrentMeetingGeneration() {
        let meetingA = MeetingID()
        let meetingB = MeetingID()
        var identity = ViewIdentityGeneration<MeetingID>()
        let tokenA = identity.begin(meetingA)
        let jobsA = [Job(kind: .finalASR, meetingID: meetingA, status: .running)]

        let tokenB = identity.begin(meetingB)
        let jobsB = [Job(kind: .finalASR, meetingID: meetingB, status: .queued)]

        #expect(MeetingJobSnapshotPublication.accepted(
            jobsA,
            for: tokenA,
            identity: identity,
            currentMeetingID: meetingB
        ) == nil)
        #expect(MeetingJobSnapshotPublication.accepted(
            jobsB,
            for: tokenB,
            identity: identity,
            currentMeetingID: meetingB
        ) == jobsB)
    }

    @Test("queued pipeline jobs show their durable processing step")
    func queuedPipelineJobs() {
        #expect(
            MeetingJobPresentation.make([
                Job(kind: .finalASR, meetingID: MeetingID(), status: .queued)
            ]) == MeetingJobPresentation(
                title: "Transcription queued",
                message: "Step 1 of 3. Steno will transcribe the original audio on this device."
            )
        )
        #expect(
            MeetingJobPresentation.make([
                Job(kind: .diarization, meetingID: MeetingID(), status: .queued)
            ]) == MeetingJobPresentation(
                title: "Speaker separation queued",
                message: "Step 2 of 3. Steno will create new speaker clusters for this transcript."
            )
        )
        #expect(
            MeetingJobPresentation.make([
                Job(kind: .identitySuggestion, meetingID: MeetingID(), status: .queued)
            ]) == MeetingJobPresentation(
                title: "Speaker matching queued",
                message: "Step 3 of 3. Steno will compare the new speaker clusters with confirmed voices."
            )
        )
    }

    @Test("running pipeline jobs show their durable processing step")
    func runningPipelineJobs() {
        #expect(
            MeetingJobPresentation.make([
                Job(kind: .finalASR, meetingID: MeetingID(), status: .running)
            ]) == MeetingJobPresentation(
                title: "Transcribing on this device",
                message: "Step 1 of 3. Steno is creating a new transcript from the original audio."
            )
        )
        #expect(
            MeetingJobPresentation.make([
                Job(kind: .diarization, meetingID: MeetingID(), status: .running)
            ]) == MeetingJobPresentation(
                title: "Separating speakers",
                message: "Step 2 of 3. Steno is creating new speaker clusters on this device."
            )
        )
        #expect(
            MeetingJobPresentation.make([
                Job(kind: .identitySuggestion, meetingID: MeetingID(), status: .running)
            ]) == MeetingJobPresentation(
                title: "Matching speakers",
                message: "Step 3 of 3. Steno is comparing speaker clusters with confirmed voices on this device."
            )
        )
    }

    @Test("terminal and non-pipeline jobs do not show pipeline activity")
    func inactivePipelineJobs() {
        #expect(MeetingJobPresentation.make([
            Job(kind: .finalASR, meetingID: MeetingID(), status: .finished)
        ]) == nil)
        #expect(MeetingJobPresentation.make([
            Job(kind: .diarization, meetingID: MeetingID(), status: .failed)
        ]) == nil)
        #expect(MeetingJobPresentation.make([
            Job(kind: .identitySuggestion, meetingID: MeetingID(), status: .cancelled)
        ]) == nil)
        #expect(MeetingJobPresentation.make([
            Job(kind: .templateRender, meetingID: MeetingID(), status: .running)
        ]) == nil)
        #expect(MeetingJobPresentation.make([
            Job(kind: .export, meetingID: MeetingID(), status: .queued)
        ]) == nil)
    }

    @Test("running wins over queued and queued follows pipeline order")
    func activePipelineJobPriority() {
        #expect(
            MeetingJobPresentation.make([
                Job(kind: .finalASR, meetingID: MeetingID(), status: .queued),
                Job(kind: .identitySuggestion, meetingID: MeetingID(), status: .running)
            ]).map { english($0.title) } == "Matching speakers"
        )
        #expect(
            MeetingJobPresentation.make([
                Job(kind: .identitySuggestion, meetingID: MeetingID(), status: .queued),
                Job(kind: .diarization, meetingID: MeetingID(), status: .queued),
                Job(kind: .finalASR, meetingID: MeetingID(), status: .queued)
            ]).map { english($0.title) } == "Transcription queued"
        )
    }

    private func english(_ resource: LocalizedStringResource) -> String {
        var resource = resource
        resource.locale = Locale(identifier: "en")
        return String(localized: resource)
    }

    @Test("detail snapshot reads status before transcript")
    @MainActor
    func diarizationSnapshotCannotPairCompletedWithAnOlderRevision() async {
        actor Probe {
            var statusWasRead = false

            func readStatus() -> MeetingDiarizationJobState {
                statusWasRead = true
                return .completed
            }

            func readRevision() -> String {
                statusWasRead ? "labels" : "old transcript"
            }
        }
        let probe = Probe()

        let snapshot = await MeetingDiarizationSnapshot.load(
            status: { await probe.readStatus() },
            revision: { await probe.readRevision() }
        )

        #expect(snapshot.state == .completed)
        #expect(snapshot.revision == "labels")
    }

    @Test("content observation reloads when model readiness changes")
    func contentObservationReloadsModelReadinessChange() {
        let initial = MeetingContentObservation(
            currentRevisionPointer: nil,
            diarizationModelsReady: nil,
            jobs: []
        )
        let updated = MeetingContentObservation(
            currentRevisionPointer: nil,
            diarizationModelsReady: true,
            jobs: []
        )

        #expect(updated.requiresReload(after: initial))
    }

    @Test("content observation reloads when only the current revision changes")
    func contentObservationReloadsSameStateRevisionChange() {
        let initial = MeetingContentObservation(
            currentRevisionPointer: CurrentRevisionPointer(
                currentRevisionID: RevisionID()
            ),
            diarizationModelsReady: true,
            jobs: []
        )
        let updated = MeetingContentObservation(
            currentRevisionPointer: CurrentRevisionPointer(
                currentRevisionID: RevisionID()
            ),
            diarizationModelsReady: true,
            jobs: []
        )

        #expect(updated.requiresReload(after: initial))
    }

    @Test("content observation reloads when speaker labels are parked")
    func contentObservationReloadsPendingCandidateChange() {
        let revisionID = RevisionID()
        let initial = MeetingContentObservation(
            currentRevisionPointer: CurrentRevisionPointer(
                currentRevisionID: revisionID
            ),
            diarizationModelsReady: true,
            jobs: []
        )
        let updated = MeetingContentObservation(
            currentRevisionPointer: CurrentRevisionPointer(
                currentRevisionID: revisionID,
                pendingCandidate: RevisionID()
            ),
            diarizationModelsReady: true,
            jobs: []
        )

        #expect(updated.requiresReload(after: initial))
    }

    @Test("content observation fingerprints pipeline jobs through terminal states")
    func contentObservationFingerprintsPipelineJobs() {
        let meetingID = MeetingID()
        let jobID = JobID()
        let queuedJob = Job(
            id: jobID,
            kind: .finalASR,
            meetingID: meetingID,
            status: .queued
        )
        let initial = MeetingContentObservation(
            currentRevisionPointer: nil,
            diarizationModelsReady: true,
            jobs: []
        )
        let queued = MeetingContentObservation(
            currentRevisionPointer: nil,
            diarizationModelsReady: true,
            jobs: [queuedJob]
        )
        let terminal = MeetingContentObservation(
            currentRevisionPointer: nil,
            diarizationModelsReady: true,
            jobs: [Job(
                id: jobID,
                kind: .finalASR,
                meetingID: meetingID,
                status: .finished,
                createdAt: queuedJob.createdAt
            )]
        )
        let unrelated = MeetingContentObservation(
            currentRevisionPointer: nil,
            diarizationModelsReady: true,
            jobs: [Job(kind: .templateRender, meetingID: meetingID, status: .finished)]
        )

        #expect(queued.requiresReload(after: initial))
        #expect(terminal.requiresReload(after: initial))
        #expect(terminal.requiresReload(after: queued))
        #expect(!unrelated.requiresReload(after: initial))
    }

    @Test("content observation uses only lightweight change identities")
    @MainActor
    func contentObservationLoadsPointerModelsStatusAndJobs() async {
        actor Probe {
            var revisionWasRead = false

            func readRevisionPointer() -> CurrentRevisionPointer? {
                revisionWasRead = true
                return CurrentRevisionPointer(currentRevisionID: RevisionID())
            }

            func readModelsReady() -> Bool? {
                revisionWasRead ? true : nil
            }

            func readState() -> MeetingDiarizationJobState {
                .ready
            }
        }
        let probe = Probe()

        let observation = await MeetingContentObservation.load(
            currentRevisionPointer: { await probe.readRevisionPointer() },
            diarizationModelsReady: { await probe.readModelsReady() },
            diarizationState: { await probe.readState() },
            jobs: { [] }
        )

        #expect(observation.currentRevisionPointer != nil)
        #expect(observation.diarizationModelsReady == true)
        #expect(observation.diarizationState == .ready)
    }

    @Test("content observation reloads when an existing status leaves unavailable")
    func contentObservationReloadsUnavailableToReadyAndModelsRequired() {
        let pointer = CurrentRevisionPointer(currentRevisionID: RevisionID())
        let initial = MeetingContentObservation(
            currentRevisionPointer: pointer,
            diarizationModelsReady: true,
            jobs: [],
            diarizationState: .unavailable
        )

        // Without any other change, the same observation must not spin the
        // reload loop.
        #expect(!initial.requiresReload(after: initial))

        // A status that flips while pointer, readiness, and jobs stay
        // identical must still trigger the same full reload a fresh meeting
        // open performs - this is the missed .unavailable -> (.ready |
        // .modelsRequired) transition.
        let ready = MeetingContentObservation(
            currentRevisionPointer: pointer,
            diarizationModelsReady: true,
            jobs: [],
            diarizationState: .ready
        )
        #expect(ready.requiresReload(after: initial))

        let modelsRequired = MeetingContentObservation(
            currentRevisionPointer: pointer,
            diarizationModelsReady: true,
            jobs: [],
            diarizationState: .modelsRequired
        )
        #expect(modelsRequired.requiresReload(after: initial))
    }

    @Test("speaker separation action routes missing models to audio readiness")
    func speakerSeparationNeedsModels() {
        #expect(
            MeetingDiarizationPresentation.make(.modelsRequired)
                == MeetingDiarizationPresentation(
                    title: "Separate speakers",
                    message: "Install the optional speaker separation models under Audio readiness first.",
                    action: .openAudioReadiness
                )
        )
    }

    @Test("speaker separation action starts only when ready")
    func speakerSeparationIsReady() {
        #expect(
            MeetingDiarizationPresentation.make(.ready)
                == MeetingDiarizationPresentation(
                    title: "Separate speakers",
                    message: "Create speaker labels for this transcript. This does not identify people by name.",
                    action: .request
                )
        )
    }

    @Test("active and completed speaker separation are status only")
    func speakerSeparationStatus() {
        #expect(
            MeetingDiarizationPresentation.make(.queued).map { english($0.title) }
                == "Speaker separation queued"
        )
        #expect(
            MeetingDiarizationPresentation.make(.running).map { english($0.title) }
                == "Separating speakers"
        )
        #expect(
            MeetingDiarizationPresentation.make(.completed).map { english($0.title) }
                == "Speaker separation completed"
        )
        #expect(MeetingDiarizationPresentation.make(.completed)?.action == nil)
    }

    @Test("parked speaker labels require explicit adoption")
    func pendingDiarizationResultExplainsTheEditAndOffersAdoption() {
        let presentation = MeetingDiarizationPresentation.make(.resultsPending)

        #expect(presentation.map { english($0.title) } == "Speaker labels ready")
        #expect(presentation.map { english($0.message).contains("edited transcript") } == true)
        #expect(presentation?.action == .adoptPending)
        #expect(presentation.map { english($0.actionTitle) } == "Use speaker labels")
    }

    @Test("other diarization failures stay visible without an automatic retry")
    func otherSpeakerSeparationFailure() {
        let presentation = MeetingDiarizationPresentation.make(
            .failed("inference failed")
        )

        #expect(presentation.map { english($0.title) } == "Speaker separation failed")
        #expect(presentation.map { english($0.message) } == "The speaker labels could not be created.")
        #expect(presentation?.action == nil)
        #expect(MeetingDiarizationPresentation.make(.unavailable) == nil)
    }

    @Test("notes editing starts after the active recording state")
    func notesEditingStartsAfterRecording() {
        #expect(!MeetingPresentation.canEditNotes(status: nil))
        #expect(!MeetingPresentation.canEditNotes(status: .recording))
        #expect(MeetingPresentation.canEditNotes(status: .interrupted))
        #expect(MeetingPresentation.canEditNotes(status: .processing))
        #expect(MeetingPresentation.canEditNotes(status: .ready))
        #expect(MeetingPresentation.canEditNotes(status: .draft))
    }

    @Test("saved audio is stated and gives the transcription recovery path")
    func savedAudioWithoutTranscript() {
        #expect(
            MeetingPresentation.emptyState(status: .ready, hasAudio: true)
                == MeetingEmptyState(
                    title: "No transcript yet",
                    systemImage: "text.quote",
                    description: "Your audio is saved. You can start transcription from the meeting actions when you are ready."
                )
        )
    }

    @Test("a meeting without media does not claim saved audio")
    func noMediaWithoutTranscript() {
        #expect(
            MeetingPresentation.emptyState(status: .ready, hasAudio: false)
                == MeetingEmptyState(
                    title: "No transcript yet",
                    systemImage: "text.quote",
                    description: "This meeting has no saved audio or transcript yet."
                )
        )
    }

    @Test("a draft keeps its existing explanation")
    func draftWithoutRecording() {
        #expect(
            MeetingPresentation.emptyState(status: .draft, hasAudio: false)
                == MeetingEmptyState(
                    title: "Draft",
                    systemImage: "square.and.pencil",
                    description: "This meeting holds a note and no recording yet."
                )
        )
    }

    @Test("the visible correction action has explicit accessible copy")
    func correctionActionCopyIsExplicit() {
        #expect(localized(TranscriptCorrectionCopy.actionLabel) == "Correct line")
        #expect(
            localized(TranscriptCorrectionCopy.actionHint)
                == "Opens an editor for this transcript line."
        )
        #expect(
            localized(TranscriptCorrectionCopy.revisionNote)
                == "The recognised text remains available as an earlier revision."
        )
    }

    @Test("recording, saving, and revision-producing jobs block correction")
    func conflictingWorkBlocksCorrection() {
        let meetingID = MeetingID()
        let runningTranscription = Job(
            kind: .finalASR,
            meetingID: meetingID,
            status: .running
        )
        let queuedDiarization = Job(
            kind: .diarization,
            meetingID: meetingID,
            status: .queued
        )

        #expect(
            TranscriptCorrectionPolicy.availability(
                meetingStatus: .ready,
                recordingIsActive: false,
                actionIsInFlight: false,
                jobs: []
            ) == .available
        )
        #expect(
            TranscriptCorrectionPolicy.availability(
                meetingStatus: .ready,
                recordingIsActive: true,
                actionIsInFlight: false,
                jobs: []
            ) == .blocked(.recording)
        )
        #expect(
            TranscriptCorrectionPolicy.availability(
                meetingStatus: .ready,
                recordingIsActive: false,
                actionIsInFlight: true,
                jobs: []
            ) == .blocked(.actionInFlight)
        )
        #expect(
            TranscriptCorrectionPolicy.availability(
                meetingStatus: .ready,
                recordingIsActive: false,
                actionIsInFlight: false,
                jobs: [runningTranscription]
            ) == .blocked(.processing)
        )
        #expect(
            TranscriptCorrectionPolicy.availability(
                meetingStatus: .ready,
                recordingIsActive: false,
                actionIsInFlight: false,
                jobs: [queuedDiarization]
            ) == .blocked(.processing)
        )
    }

    @Test("terminal and non-revision jobs do not block correction")
    func unrelatedWorkDoesNotBlockCorrection() {
        let meetingID = MeetingID()
        let jobs = [
            Job(kind: .finalASR, meetingID: meetingID, status: .finished),
            Job(kind: .identitySuggestion, meetingID: meetingID, status: .running),
            Job(kind: .templateRender, meetingID: meetingID, status: .queued),
        ]

        #expect(
            TranscriptCorrectionPolicy.availability(
                meetingStatus: .ready,
                recordingIsActive: false,
                actionIsInFlight: false,
                jobs: jobs
            ) == .available
        )
    }

    @Test("search matches preserve original turn indices and complete text")
    func correctionMatchesUseOriginalIndices() throws {
        let revision = transcriptRevision([
            ["First", "matching line"],
            ["Not included"],
            ["Another matching line"],
        ])

        let matches = TranscriptTurnPresentation.matches(
            in: revision,
            query: "matching"
        )

        #expect(matches.map(\.turnIndex) == [0, 2])
        let target = try #require(TranscriptCorrectionTarget(
            meetingID: revision.meetingID,
            revision: revision,
            turnIndex: matches[0].turnIndex
        ))
        #expect(target.initialDraft == "First matching line")
    }

    @Test("a revision conflict keeps the sheet open and preserves its draft")
    func conflictKeepsCorrectionDraft() throws {
        let original = transcriptRevision([["Recognised text"]])
        let target = try #require(TranscriptCorrectionTarget(
            meetingID: original.meetingID,
            revision: original,
            turnIndex: 0
        ))
        var state = TranscriptCorrectionSheetState(target: target)
        state.draft = "My typed correction"
        let current = transcriptRevision(
            [["New current text"]],
            meetingID: original.meetingID
        )

        let effect = state.receive(
            .failed(.revisionConflict(currentRevision: current))
        )

        #expect(state.draft == "My typed correction")
        #expect(state.target.revision.id == original.id)
        #expect(
            state.error == .revisionConflict(currentRevision: current)
        )
        #expect(effect == .reloadAfterConflict(currentRevision: current))
    }

    @Test("a saved correction returns the new visible revision and dismisses")
    func successfulCorrectionUpdatesVisibleRevision() throws {
        let original = transcriptRevision([["Recognised text"]])
        let target = try #require(TranscriptCorrectionTarget(
            meetingID: original.meetingID,
            revision: original,
            turnIndex: 0
        ))
        var state = TranscriptCorrectionSheetState(target: target)
        state.draft = "Corrected text"
        let edited = TranscriptRevision(
            meetingID: original.meetingID,
            origin: .userEdit(original.id),
            turns: original.turns
        )

        let effect = state.receive(.saved(edited))

        #expect(state.error == nil)
        #expect(effect == .saved(updatedVisibleRevision: edited))
    }

    @Test("a suspended save cannot publish after the detail view changes meetings")
    @MainActor
    func lateCorrectionSaveCannotPublishIntoAnotherMeeting() async throws {
        let meetingA = MeetingID()
        let meetingB = MeetingID()
        var identity = ViewIdentityGeneration<MeetingID>()
        var publication = MeetingTranscriptPublicationGate()
        let viewA = identity.begin(meetingA)
        publication.reset(for: viewA)
        let initialLoadValue = publication.beginLoad(for: viewA)
        let initialLoad = try #require(initialLoadValue)
        let original = transcriptRevision(
            [["Recognised text"]],
            meetingID: meetingA
        )
        let originalPointer = CurrentRevisionPointer(
            currentRevisionID: original.id
        )
        let originalPointerSnapshot = try #require(
            MeetingTranscriptPointerSnapshot(
                meetingID: meetingA,
                pointer: originalPointer,
                loadedPendingRevision: nil,
                diarizationState: .completed
            )
        )
        #expect(publication.accepts(
            initialLoad,
            loadedRevision: original,
            loadedDiarizationState: .completed,
            loadedPointerSnapshot: originalPointerSnapshot,
            freshPointer: originalPointer,
            identity: identity,
            currentMeetingID: meetingA
        ))
        let target = try #require(TranscriptCorrectionTarget(
            meetingID: meetingA,
            revision: original,
            turnIndex: 0
        ))
        let saveToken = try #require(publication.sheetSaveToken(
            for: target,
            viewIdentity: viewA
        ))
        let suspension = TranscriptPublicationSuspensionGate()
        let edited = TranscriptRevision(
            meetingID: meetingA,
            origin: .userEdit(original.id),
            turns: original.turns
        )
        let lateSave = Task {
            await suspension.enterAndWait()
            return edited
        }
        await suspension.waitUntilEntered()

        let viewB = identity.begin(meetingB)
        publication.reset(for: viewB)
        await suspension.release()
        let savedRevision = await lateSave.value

        let acceptedLateSave = publication.acceptsSavedRevision(
            savedRevision,
            for: saveToken,
            identity: identity,
            currentMeetingID: meetingB
        )
        #expect(!acceptedLateSave)
    }

    @Test("a newer same-meeting load invalidates an older sheet callback")
    @MainActor
    func newerLoadInvalidatesCorrectionCallback() throws {
        let meetingID = MeetingID()
        var identity = ViewIdentityGeneration<MeetingID>()
        var publication = MeetingTranscriptPublicationGate()
        let view = identity.begin(meetingID)
        publication.reset(for: view)
        let original = transcriptRevision(
            [["Recognised text"]],
            meetingID: meetingID
        )
        let target = try #require(TranscriptCorrectionTarget(
            meetingID: meetingID,
            revision: original,
            turnIndex: 0
        ))
        let saveToken = try #require(publication.sheetSaveToken(
            for: target,
            viewIdentity: view
        ))
        let newerLoad = publication.beginLoad(for: view)
        _ = try #require(newerLoad)
        let edited = TranscriptRevision(
            meetingID: meetingID,
            origin: .userEdit(original.id),
            turns: original.turns
        )

        let acceptedStaleSave = publication.acceptsSavedRevision(
            edited,
            for: saveToken,
            identity: identity,
            currentMeetingID: meetingID
        )
        #expect(!acceptedStaleSave)
    }

    @Test("a sheet callback rejects a revision from another meeting")
    @MainActor
    func correctionCallbackValidatesSavedMeeting() throws {
        let meetingID = MeetingID()
        var identity = ViewIdentityGeneration<MeetingID>()
        var publication = MeetingTranscriptPublicationGate()
        let view = identity.begin(meetingID)
        publication.reset(for: view)
        let original = transcriptRevision(
            [["Recognised text"]],
            meetingID: meetingID
        )
        let target = try #require(TranscriptCorrectionTarget(
            meetingID: meetingID,
            revision: original,
            turnIndex: 0
        ))
        let saveToken = try #require(publication.sheetSaveToken(
            for: target,
            viewIdentity: view
        ))
        let wrongMeetingRevision = TranscriptRevision(
            meetingID: MeetingID(),
            origin: .userEdit(original.id),
            turns: original.turns
        )

        let acceptedWrongMeeting = publication.acceptsSavedRevision(
            wrongMeetingRevision,
            for: saveToken,
            identity: identity,
            currentMeetingID: meetingID
        )
        #expect(!acceptedWrongMeeting)
    }

    @Test("only the newest parallel same-meeting load may publish")
    @MainActor
    func reversedLoadCompletionKeepsNewestTranscript() throws {
        let meetingID = MeetingID()
        var identity = ViewIdentityGeneration<MeetingID>()
        var publication = MeetingTranscriptPublicationGate()
        let view = identity.begin(meetingID)
        publication.reset(for: view)
        let oldLoadValue = publication.beginLoad(for: view)
        let oldLoad = try #require(oldLoadValue)
        let newLoadValue = publication.beginLoad(for: view)
        let newLoad = try #require(newLoadValue)
        let oldRevision = transcriptRevision(
            [["Old"]],
            meetingID: meetingID
        )
        let newRevision = transcriptRevision(
            [["New"]],
            meetingID: meetingID
        )
        let oldPointer = CurrentRevisionPointer(
            currentRevisionID: oldRevision.id
        )
        let oldPointerSnapshot = try #require(
            MeetingTranscriptPointerSnapshot(
                meetingID: meetingID,
                pointer: oldPointer,
                loadedPendingRevision: nil,
                diarizationState: .completed
            )
        )
        let newPointer = CurrentRevisionPointer(
            currentRevisionID: newRevision.id
        )
        let newPointerSnapshot = try #require(
            MeetingTranscriptPointerSnapshot(
                meetingID: meetingID,
                pointer: newPointer,
                loadedPendingRevision: nil,
                diarizationState: .completed
            )
        )

        #expect(publication.accepts(
            newLoad,
            loadedRevision: newRevision,
            loadedDiarizationState: .completed,
            loadedPointerSnapshot: newPointerSnapshot,
            freshPointer: newPointer,
            identity: identity,
            currentMeetingID: meetingID
        ))
        #expect(!publication.accepts(
            oldLoad,
            loadedRevision: oldRevision,
            loadedDiarizationState: .completed,
            loadedPointerSnapshot: oldPointerSnapshot,
            freshPointer: oldPointer,
            identity: identity,
            currentMeetingID: meetingID
        ))
    }

    @Test("a persisted pointer change after transcript loading rejects the stale snapshot")
    @MainActor
    func pointerChangeAfterTranscriptReadRejectsPublication() async throws {
        let meetingID = MeetingID()
        var identity = ViewIdentityGeneration<MeetingID>()
        var publication = MeetingTranscriptPublicationGate()
        let view = identity.begin(meetingID)
        publication.reset(for: view)
        let loadValue = publication.beginLoad(for: view)
        let load = try #require(loadValue)
        let oldRevision = transcriptRevision(
            [["Old visible transcript"]],
            meetingID: meetingID
        )
        let oldCandidate = transcriptRevision(
            [["Old pending transcript"]],
            meetingID: meetingID
        )
        let oldPointer = CurrentRevisionPointer(
            currentRevisionID: oldRevision.id,
            pendingCandidate: oldCandidate.id
        )
        let loadedPointerSnapshot = try #require(
            MeetingTranscriptPointerSnapshot(
                meetingID: meetingID,
                pointer: oldPointer,
                loadedPendingRevision: oldCandidate,
                diarizationState: .completed
            )
        )
        let newRevision = transcriptRevision(
            [["New visible transcript"]],
            meetingID: meetingID
        )
        let newCandidate = transcriptRevision(
            [["New pending transcript"]],
            meetingID: meetingID
        )
        var persistedPointer = oldPointer
        let suspension = TranscriptPublicationSuspensionGate()
        let latePublication = Task { @MainActor in
            await suspension.enterAndWait()
            return publication.accepts(
                load,
                loadedRevision: oldRevision,
                loadedDiarizationState: .completed,
                loadedPointerSnapshot: loadedPointerSnapshot,
                freshPointer: persistedPointer,
                identity: identity,
                currentMeetingID: meetingID
            )
        }
        await suspension.waitUntilEntered()

        persistedPointer = CurrentRevisionPointer(
            currentRevisionID: newRevision.id,
            pendingCandidate: newCandidate.id
        )
        await suspension.release()

        #expect(!(await latePublication.value))
    }

    @Test("speaker-label pending keeps its candidate identity while hiding the generic banner")
    @MainActor
    func diarizationPendingPointerIdentityIsStable() throws {
        let meetingID = MeetingID()
        var identity = ViewIdentityGeneration<MeetingID>()
        var publication = MeetingTranscriptPublicationGate()
        let view = identity.begin(meetingID)
        publication.reset(for: view)
        let loadValue = publication.beginLoad(for: view)
        let load = try #require(loadValue)
        let current = transcriptRevision(
            [["Corrected transcript"]],
            meetingID: meetingID
        )
        let speakerLabels = transcriptRevision(
            [["Separated transcript"]],
            meetingID: meetingID
        )
        let pointer = CurrentRevisionPointer(
            currentRevisionID: current.id,
            pendingCandidate: speakerLabels.id
        )
        let loadedPointerSnapshot = try #require(
            MeetingTranscriptPointerSnapshot(
                meetingID: meetingID,
                pointer: pointer,
                loadedPendingRevision: speakerLabels,
                diarizationState: .resultsPending
            )
        )

        #expect(loadedPointerSnapshot.visiblePendingRevision == nil)
        #expect(publication.accepts(
            load,
            loadedRevision: current,
            loadedDiarizationState: .resultsPending,
            loadedPointerSnapshot: loadedPointerSnapshot,
            freshPointer: pointer,
            identity: identity,
            currentMeetingID: meetingID
        ))
        #expect(!publication.accepts(
            load,
            loadedRevision: current,
            loadedDiarizationState: .resultsPending,
            loadedPointerSnapshot: loadedPointerSnapshot,
            freshPointer: CurrentRevisionPointer(
                currentRevisionID: current.id,
                pendingCandidate: RevisionID()
            ),
            identity: identity,
            currentMeetingID: meetingID
        ))
    }

    @Test("pending transcription captures both visible IDs for explicit adoption")
    func pendingTranscriptRequiresVisibleAction() throws {
        let current = transcriptRevision([["User correction"]])
        let candidate = transcriptRevision(
            [["Automatic transcript"]],
            meetingID: current.meetingID
        )
        let presentation = try #require(PendingTranscriptPresentation.make(
            currentRevision: current,
            pendingRevision: candidate,
            diarizationState: .ready
        ))

        #expect(presentation.expectedCurrentRevisionID == current.id)
        #expect(presentation.expectedCandidateID == candidate.id)
        #expect(localized(presentation.title) == "A newer transcription is ready.")
        #expect(localized(presentation.message) == "Your correction is shown instead.")
        #expect(localized(presentation.actionTitle) == "Use the new one")
        #expect(
            localized(presentation.actionHint)
                == "Your correction remains available as an earlier revision."
        )
        #expect(PendingTranscriptPresentation.make(
            currentRevision: current,
            pendingRevision: nil,
            diarizationState: .ready
        ) == nil)
    }

    @Test("speaker-separation candidates never use the newer-transcription banner")
    func pendingDiarizationIsNotPresentedAsTranscription() {
        let current = transcriptRevision([["User correction"]])
        let candidate = transcriptRevision(
            [["Separated speakers"]],
            meetingID: current.meetingID
        )

        #expect(PendingTranscriptPresentation.make(
            currentRevision: current,
            pendingRevision: candidate,
            diarizationState: .resultsPending
        ) == nil)
        #expect(PendingTranscriptPresentation.make(
            currentRevision: current,
            pendingRevision: candidate,
            diarizationState: .ready
        ) != nil)
    }

    @Test("pending-adoption failures have distinct stable explanations")
    func pendingAdoptionMessagesAreTruthful() throws {
        let cases: [(PendingTranscriptAdoptionResult, String)] = [
            (
                .staleRevisionPair,
                "The shown transcription changed before it could be selected. Nothing was replaced. The current versions have been reloaded."
            ),
            (
                .diarizationCandidate,
                "This is a speaker-separation result. Use “Use speaker labels” instead."
            ),
            (
                .blocked(.recordingInProgress),
                "Stop the recording before switching transcript revisions."
            ),
            (
                .blocked(.editInFlight),
                "Wait for the transcript correction to finish, then try again."
            ),
            (
                .blocked(.conflictingActionInFlight),
                "Another library action is still finishing. Try again in a moment."
            ),
            (
                .blocked(.processingInFlight),
                "Wait for transcription or speaker separation to finish, then try again."
            ),
            (
                .failed(.libraryUnavailable),
                "The library is not ready yet. Try again when the meeting has loaded."
            ),
            (
                .failed(.persistenceFailure),
                "The newer transcription could not be selected because of a storage error. Nothing was replaced."
            ),
        ]

        for (result, expectedMessage) in cases {
            let presentation = try #require(
                PendingTranscriptAdoptionPresentation.make(result)
            )
            #expect(localized(presentation.message) == expectedMessage)
        }
        #expect(PendingTranscriptAdoptionPresentation.make(.adopted) == nil)
    }

    private func transcriptRevision(
        _ segmentsByTurn: [[String]],
        meetingID: MeetingID = MeetingID()
    ) -> TranscriptRevision {
        TranscriptRevision(
            meetingID: meetingID,
            origin: .finalRun(RunID()),
            turns: segmentsByTurn.enumerated().map { turnIndex, texts in
                let turnStart = Double(turnIndex) * 10
                return TranscriptTurn(
                    speaker: .channel("Other"),
                    start: turnStart,
                    end: turnStart + 8,
                    segments: texts.enumerated().map { segmentIndex, text in
                        let start = turnStart + Double(segmentIndex)
                        return TranscriptSegment(
                            text: text,
                            start: start,
                            end: start + 1,
                            words: []
                        )
                    }
                )
            }
        )
    }

    private func localized(_ resource: LocalizedStringResource) -> String {
        english(resource)
    }
}

private actor TranscriptPublicationSuspensionGate {
    private var didEnter = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func enterAndWait() async {
        didEnter = true
        let waiters = entryWaiters
        entryWaiters = []
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilEntered() async {
        guard !didEnter else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
