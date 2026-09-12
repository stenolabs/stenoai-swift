import StenoDomain
import StenoLibrary
import StenoPipeline
import SwiftUI

/// A meeting, for reading, plus its editing inspector.
///
/// Transcript and speaker review stay read-only in the main view. The
/// inspector is the one writable surface: it edits the meeting's canonical
/// notes session and routes speaker review through the shared transactional
/// controller, so autosave, markers and later edits cannot overwrite one
/// another and two windows never disagree about the same meeting.
///
/// Follows `steno-macos/App/Sources/MeetingDetailView.swift` in the parts that
/// carry meaning: timestamp left, speaker above the line, colour only ever as
/// a marker beside a name, and a guess visibly marked as a guess.
struct MeetingDetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    let meetingID: MeetingID
    let router: NavigationRouter
    var showAudioReadiness: () -> Void = {}

    @State private var showBrief = false
    @State private var revision: TranscriptRevision?
    @State private var speakerPresentationContext = SpeakerPresentationContext.empty
    @State private var duration: TimeInterval?
    @State private var jobs: [Job] = []
    @State private var didLoad = false
    @State private var query = ""
    @State private var isShowingMeetingTransfer = false
    @State private var diarizationState: MeetingDiarizationJobState = .unavailable
    @State private var isRequestingDiarization = false
    @State private var identity = ViewIdentityGeneration<MeetingID>()
    @State private var contentObservation: MeetingContentObservation?
    @State private var inspectorPresentation = MeetingInspectorPresentation()
    @State private var shouldPresentDraftInspector = false
    @State private var retranscribeTarget: Meeting?
    @State private var deleteTarget: Meeting?
    @State private var correctionSession: TranscriptCorrectionSession?
    @State private var transcriptPublication = MeetingTranscriptPublicationGate()
    @State private var pendingRevision: TranscriptRevision?
    @State private var isAdoptingPendingTranscript = false
    @State private var pendingAdoptionPresentation:
        PendingTranscriptAdoptionPresentation?
    @FocusState private var transcriptSearchIsFocused: Bool

    private static let readableWidth: CGFloat = 720

    /// Read from the process-wide publication rather than view-local state:
    /// every window observes the exact same meeting/review pair, and a
    /// review action in one window is visible in another without a manual
    /// reload. Gated on `hasCurrentIdentity` so a still-loading view never
    /// shows a cached pair under the wrong meeting title.
    private var meeting: Meeting? {
        hasCurrentIdentity ? app.meetingReviewPublication(for: meetingID)?.meeting : nil
    }

    private var review: MeetingReviewData? {
        hasCurrentIdentity ? app.meetingReviewPublication(for: meetingID)?.review : nil
    }

    var body: some View {
        @Bindable var router = router

        actionPresentationContent
        .sheet(isPresented: $showBrief) { MeetingBriefView(meetingID: meetingID) }
        .safeAreaInset(edge: .top, spacing: 0) {
            ShortRecordingBanner(meetingID: meetingID)
        }
        .inspector(isPresented: $router.isInspectorPresented) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    MeetingNotesSection(meetingID: meetingID)
                    Divider()
                    MeetingParticipantsSection(meeting: meeting, review: review)
                    if SpeakerReviewPresentation.shouldShowSection(
                        hasReview: review != nil,
                        error: app.reviewError(for: meetingID)
                    ) {
                        Divider()
                        SpeakerReviewSection(
                            meetingID: meetingID,
                            review: review,
                            isDemoMeeting: meeting?.isDemo ?? false
                        )
                    }
                }
                .padding()
            }
            .inspectorColumnWidth(min: 300, ideal: 360, max: 460)
        }
        .task(id: meetingID) { await observeMeeting() }
        .task(id: shouldPresentDraftInspector) {
            guard shouldPresentDraftInspector else { return }
            // Run only after `didLoad` has produced a rendered detail. On
            // iPhone, presenting the adaptive inspector from inside the load
            // task cancels that task and leaves the replacement view loading.
            shouldPresentDraftInspector = false
            router.showInspector()
        }
    }

    private var navigationContent: AnyView {
        AnyView(
            meetingContent
                .navigationTitle(currentMeeting?.title ?? "")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button("Prepare brief…", systemImage: "sparkles") { showBrief = true }
                            .disabled(app.recording.isActive)
                        if let subtitle {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Button {
                            router.toggleInspector()
                        } label: {
                            Label(
                                router.isInspectorPresented ? "Hide Inspector" : "Show Inspector",
                                systemImage: "sidebar.right"
                            )
                        }
                        .accessibilityHint(
                            router.isInspectorPresented
                                ? "Hides meeting notes, participants, and speaker review."
                                : "Shows meeting notes, participants, and speaker review."
                        )
                        .accessibilityIdentifier("meeting-inspector-toggle")
                        if MeetingPresentation.canShareMeeting(status: currentMeeting?.status) {
                            Button {
                                isShowingMeetingTransfer = true
                            } label: {
                                Label("Share meeting", systemImage: "square.and.arrow.up")
                            }
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        MeetingActionsMenu(
                            movePolicy: meetingMovePolicy,
                            canRetranscribe: MeetingActionPolicy.canRetranscribe(
                                status: currentMeeting?.status
                            ),
                            canDelete: MeetingActionPolicy.canDelete(
                                status: currentMeeting?.status
                            ),
                            move: { folderID in
                                Task {
                                    _ = await app.moveMeeting(meetingID, to: folderID)
                                }
                            },
                            retranscribe: { retranscribeTarget = currentMeeting },
                            delete: { deleteTarget = currentMeeting }
                        )
                        .accessibilityIdentifier("meeting-actions-menu")
                    }
                }
        )
    }

    private var meetingMovePolicy: IOSSidebarMeetingActionPolicy {
        IOSMeetingSidebarPresentation(
            folders: app.folders,
            meetings: app.meetings,
            query: ""
        ).meetingActionPolicy(for: meetingID)
    }

    private var actionPresentationContent: AnyView {
        AnyView(
            navigationContent
                .searchable(
                    text: $query,
                    placement: .navigationBarDrawer(displayMode: .automatic),
                    prompt: "Find in transcript"
                )
                .searchFocused($transcriptSearchIsFocused)
                .accessibilityIdentifier("transcript-search")
                .onChange(of: router.transcriptSearchFocusRequest) { _, _ in
                    // The request belongs to this focused scene's router. A
                    // detail being replaced for another route must not steal
                    // focus during that transition.
                    guard router.selectedMeetingID == meetingID else { return }
                    transcriptSearchIsFocused = true
                }
                .sheet(isPresented: $isShowingMeetingTransfer) {
                    MeetingTransferExportSheet(meetingID: meetingID)
                }
                .sheet(item: $correctionSession) { session in
                    TranscriptCorrectionSheet(
                        target: session.target,
                        availability: correctionAvailability,
                        save: { target, text in
                            await app.saveTranscriptEdit(
                                meetingID: target.meetingID,
                                revision: target.revision,
                                turnIndex: target.turnIndex,
                                text: text
                            )
                        },
                        didSave: { updatedRevision in
                            publishSavedCorrection(
                                updatedRevision,
                                session: session
                            )
                        },
                        didEncounterConflict: { currentRevision in
                            await reloadAfterCorrectionConflict(
                                currentRevision,
                                session: session
                            )
                        }
                    )
                }
                .alert(
                    retranscribeTarget.map {
                        MeetingActionCopy.retranscriptionTitle(meetingTitle: $0.title)
                    } ?? "",
                    isPresented: retranscribeTargetIsPresented,
                    presenting: retranscribeTarget
                ) { meeting in
                    Button("Transcribe Again") {
                        retranscribeTarget = nil
                        requestRetranscription(meeting)
                    }
                    Button("Cancel", role: .cancel) { retranscribeTarget = nil }
                } message: { _ in
                    Text(MeetingActionCopy.retranscriptionMessage)
                }
                .confirmationDialog(
                    deleteTarget.map {
                        MeetingActionCopy.deletionTitle(meetingTitle: $0.title)
                    } ?? "",
                    isPresented: deleteTargetIsPresented,
                    titleVisibility: .visible,
                    presenting: deleteTarget
                ) { meeting in
                    Button(MeetingActionCopy.deletionConfirmationLabel, role: .destructive) {
                        deleteTarget = nil
                        deleteMeeting(meeting)
                    }
                    Button("Cancel", role: .cancel) { deleteTarget = nil }
                } message: { _ in
                    Text(MeetingActionCopy.deletionMessage)
                }
        )
    }

    private var meetingContent: some View {
        VStack(spacing: 0) {
            if let currentMeeting, DemoBadge.shouldShow(for: currentMeeting) {
                HStack {
                    DemoBadge(meeting: currentMeeting)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }
            if let receipt = currentMeeting?.metadata?.transferReceipt {
                importedMeetingSummary(MeetingTransferDetailPresentation(receipt: receipt))
            }
            pendingTranscriptStatus
            meetingProcessingStatus
            if didLoad, hasCurrentIdentity {
                detailList
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private var meetingProcessingStatus: some View {
        if hasCurrentIdentity, let presentation = MeetingJobPresentation.make(jobs) {
            jobStatus(presentation)
        } else if hasCurrentIdentity,
                  let presentation = MeetingDiarizationPresentation.make(diarizationState)
        {
            diarizationStatus(presentation)
        }
    }

    // MARK: - Transcript

    private var detailList: some View {
        List {
            failedParakeetSection
            MeetingReportsSection(
                meetingID: meetingID,
                review: review,
                hasTranscript: revision?.turns.isEmpty == false,
                unrecordedTracks: meeting?.unrecordedTracks ?? []
            )
            transcriptSection()
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 0)
    }

    @ViewBuilder
    private var failedParakeetSection: some View {
        if let failedParakeetJob {
            Section {
                Label(
                    failedParakeetJob.errorMessage ?? "Parakeet transcription failed.",
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.red)
                // Ausdrueckliches Angebot, kein stiller Rueckfall: der Nutzer
                // entscheidet, nicht das Programm (Falle 3).
                Button("Run with Apple") {
                    retryFinalASRWithApple(failedParakeetJob)
                }
            }
        }
    }

    private func retryFinalASRWithApple(_ job: Job) {
        guard let token = identity.token(for: meetingID) else { return }
        Task {
            await app.retryFinalASRWithApple(job)
            let loadedJobs = await app.meetingJobs(for: token.value)
            guard let acceptedJobs = MeetingJobSnapshotPublication.accepted(
                loadedJobs,
                for: token,
                identity: identity,
                currentMeetingID: meetingID
            ) else { return }
            updateObservedJobs(acceptedJobs)
        }
    }

    @ViewBuilder
    private func transcriptSection() -> some View {
        Section("Transcript") {
            if let revision, !revision.turns.isEmpty {
                let matches = TranscriptTurnPresentation.matches(
                    in: revision,
                    query: query
                )
                if matches.isEmpty {
                    Text("Nothing in this transcript matches “\(query)”.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(matches) { match in
                        TranscriptTurnRow(
                            turn: match.turn,
                            turnIndex: match.turnIndex,
                            review: review,
                            presentationContext: speakerPresentationContext,
                            query: query,
                            correctionAvailability: correctionAvailability,
                            correct: {
                                presentCorrection(
                                    revision: revision,
                                    turnIndex: match.turnIndex
                                )
                            }
                        )
                        .frame(maxWidth: Self.readableWidth, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowSeparator(.hidden)
                    }
                }
            } else {
                let state = MeetingPresentation.emptyState(
                    status: meeting?.status,
                    hasAudio: duration != nil
                )
                Label {
                    VStack(alignment: .leading, spacing: Steno.Space.xs) {
                        Text(state.title)
                            .font(.headline)
                        Text(state.description)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: state.systemImage)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, Steno.Space.s)
            }
        }
    }

    private var correctionAvailability: TranscriptCorrectionAvailability {
        TranscriptCorrectionPolicy.availability(
            meetingStatus: currentMeeting?.status,
            recordingIsActive: app.recording.isActive,
            actionIsInFlight: app.libraryActionIsInFlight
                || app.transcriptEditsInFlight.contains(meetingID)
                || isAdoptingPendingTranscript
                || isRequestingDiarization,
            jobs: jobs
        )
    }

    @ViewBuilder
    private var pendingTranscriptStatus: some View {
        if let revision,
           let presentation = PendingTranscriptPresentation.make(
               currentRevision: revision,
               pendingRevision: pendingRevision,
               diarizationState: diarizationState
           )
        {
            VStack(alignment: .leading, spacing: Steno.Space.xs) {
                Label {
                    Text(presentation.title)
                        .font(.subheadline.weight(.semibold))
                } icon: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                Text(presentation.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(presentation.actionTitle) {
                    adoptPendingTranscript(presentation)
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    isAdoptingPendingTranscript
                        || !correctionAvailability.isAvailable
                )
                .accessibilityHint(presentation.actionHint)
                .accessibilityIdentifier("use-pending-transcript")
                if let pendingAdoptionPresentation {
                    Label {
                        Text(pendingAdoptionPresentation.message)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .font(.caption)
                    .foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.vertical, Steno.Space.s)
            .background(.thinMaterial)
        } else if let pendingAdoptionPresentation {
            Label {
                Text(pendingAdoptionPresentation.message)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
            .font(.caption)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.vertical, Steno.Space.s)
            .background(.thinMaterial)
        }
    }

    // MARK: - Header data

    private var hasCurrentIdentity: Bool {
        identity.token(for: meetingID) != nil
    }

    private var currentMeeting: Meeting? {
        hasCurrentIdentity ? meeting : nil
    }

    private var subtitle: String? {
        guard hasCurrentIdentity else { return nil }
        var parts: [String] = []
        if let duration { parts.append(durationText(duration)) }
        if let count = revision?.turns.count, count > 0 {
            parts.append("\(count) turns")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Nur der juengste Fehlschlag: ein alter Parakeet-Fehlschlag darf nicht
    /// dauerhaft ein Retry-Angebot zeigen, wenn ein spaeterer Lauf (etwa
    /// schon das Apple-Retry) laengst durchgelaufen ist.
    private var failedParakeetJob: Job? {
        let finalASRJobs = jobs.filter { $0.kind == .finalASR }
        let failed = finalASRJobs
            .filter { $0.status == .failed && $0.transcriptionProviderID == .parakeetTDTv3 }
            .sorted { $0.createdAt > $1.createdAt }
        return failed.first { job in
            !finalASRJobs.contains {
                $0.status == .finished && $0.createdAt > job.createdAt
            }
        }
    }

    private func load(
        _ token: ViewIdentityGeneration<MeetingID>.Token
    ) async {
        guard identity.accepts(token, currentValue: meetingID) else { return }
        var publication = transcriptPublication
        guard let loadToken = publication.beginLoad(for: token) else { return }
        transcriptPublication = publication
        let inspectorWasAlreadyPresented = router.isInspectorPresented
        let previouslyShownPendingRevisionID = pendingRevision?.id
        // Keep the baseline from before the full load. Any pointer, model, or
        // job transition that happens while the slower snapshot is being read
        // therefore remains visible to the next lightweight poll.
        let observationBeforeLoad = await MeetingContentObservation.load(
            currentRevisionPointer: {
                await app.currentRevisionPointer(for: token.value)
            },
            diarizationModelsReady: {
                app.diarizationModels.isReady(for: app.language.locale)
            },
            diarizationState: {
                await app.meetingDiarizationState(for: token.value)
            },
            jobs: { await app.meetingJobs(for: token.value) }
        )
        let loadedPublication = await app.loadMeetingReviewPublication(for: token.value)
        let loadedSpeakerContext = await app.speakerPresentationContext(
            for: token.value
        )
        let loadedDiarization = await MeetingDiarizationSnapshot.load(
            status: { await app.meetingDiarizationState(for: token.value) },
            revision: { await app.transcript(for: token.value) }
        )
        let loadedPointerSnapshot = await app.pendingTranscriptSnapshot(
            for: token.value
        )
        let loadedPendingRevision =
            loadedPointerSnapshot?.visiblePendingRevision
        let loadedDuration = await app.duration(for: token.value)
        let loadedJobs = await app.meetingJobs(for: token.value)
        // Re-read the durable pointer immediately before publication. A
        // different window or pipeline stage may have committed a revision
        // while the slower transcript and review snapshot was loading.
        let freshPointer = await app.currentRevisionPointer(for: token.value)
        // Compact navigation may cancel SwiftUI's task while this exact view
        // identity is still current. The generation and identity gate below
        // is the authoritative stale-result check, so a valid completed load
        // must still publish instead of leaving the replacement view spinning.
        let currentPublication = transcriptPublication
        guard currentPublication.accepts(
            loadToken,
            loadedRevision: loadedDiarization.revision,
            loadedDiarizationState: loadedDiarization.state,
            loadedPointerSnapshot: loadedPointerSnapshot,
            freshPointer: freshPointer,
            identity: identity,
            currentMeetingID: meetingID
        ) else {
            // Only invalidate this meeting's baseline. An older load that
            // lost its generation or view identity must not mutate the newer
            // view. The next one-second poll performs the controlled reload.
            if currentPublication.acceptsLoadIdentity(
                loadToken,
                identity: identity,
                currentMeetingID: meetingID
            ) {
                contentObservation = nil
            }
            return
        }
        speakerPresentationContext = loadedSpeakerContext
        diarizationState = loadedDiarization.state
        revision = loadedDiarization.revision
        pendingRevision = loadedPendingRevision
        if previouslyShownPendingRevisionID != loadedPendingRevision?.id {
            pendingAdoptionPresentation = nil
        }
        duration = loadedDuration
        jobs = loadedJobs
        contentObservation = observationBeforeLoad
        didLoad = true

        // A draft opens its inspector once per meeting, never more than once
        // per load cycle: `shouldOpen` remembers the meeting ID across the
        // repeated `load()` calls this view's diarization poll makes.
        var presentation = inspectorPresentation
        let shouldOpenInspector = presentation.shouldOpen(
            for: token.value,
            status: loadedPublication?.meeting.status,
            inspectorWasAlreadyPresented: inspectorWasAlreadyPresented
        )
        inspectorPresentation = presentation
        // On compact-width iPhone the adaptive inspector rebuilds this
        // navigation detail while it is appearing. Keep the draft readable
        // there and let the visible inspector button open notes explicitly.
        if shouldOpenInspector, sizeClass != .compact {
            shouldPresentDraftInspector = true
        }
    }

    private func observeMeeting() async {
        let token = identity.begin(meetingID)
        resetMeetingState()
        var publication = transcriptPublication
        publication.reset(for: token)
        transcriptPublication = publication
        await load(token)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled,
                  identity.accepts(token, currentValue: meetingID)
            else { return }
            let updatedObservation = await MeetingContentObservation.load(
                currentRevisionPointer: {
                    await app.currentRevisionPointer(for: token.value)
                },
                diarizationModelsReady: {
                    app.diarizationModels.isReady(for: app.language.locale)
                },
                diarizationState: {
                    await app.meetingDiarizationState(for: token.value)
                },
                jobs: { await app.meetingJobs(for: token.value) }
            )
            guard !Task.isCancelled,
                  identity.accepts(token, currentValue: meetingID)
            else { return }
            guard updatedObservation.requiresReload(after: contentObservation) else {
                continue
            }
            await load(token)
        }
    }

    private func resetMeetingState() {
        revision = nil
        speakerPresentationContext = .empty
        duration = nil
        jobs = []
        didLoad = false
        query = ""
        isShowingMeetingTransfer = false
        diarizationState = .unavailable
        isRequestingDiarization = false
        contentObservation = nil
        shouldPresentDraftInspector = false
        retranscribeTarget = nil
        deleteTarget = nil
        correctionSession = nil
        pendingRevision = nil
        isAdoptingPendingTranscript = false
        pendingAdoptionPresentation = nil
    }

    private func requestRetranscription(_ meeting: Meeting) {
        guard let token = identity.token(for: meeting.id) else { return }
        Task {
            do {
                try await app.requestRetranscription(meetingID: token.value)
                let loadedJobs = await app.meetingJobs(for: token.value)
                guard let acceptedJobs = MeetingJobSnapshotPublication.accepted(
                    loadedJobs,
                    for: token,
                    identity: identity,
                    currentMeetingID: meetingID
                ) else { return }
                updateObservedJobs(acceptedJobs)
            } catch {
                guard identity.accepts(token, currentValue: meetingID) else { return }
                router.meetingActionAlert = .retranscriptionFailure(error.localizedDescription)
            }
        }
    }

    private func deleteMeeting(_ meeting: Meeting) {
        guard let token = identity.token(for: meeting.id) else { return }
        Task {
            do {
                let outcome = try await app.deleteMeeting(token.value)
                router.applyMeetingDeletionCompletion(
                    meetingID: token.value,
                    cleanupWarning: outcome.cleanupWarning
                )
            } catch {
                router.applyMeetingDeletionFailure(error.localizedDescription)
            }
        }
    }

    private var retranscribeTargetIsPresented: Binding<Bool> {
        Binding(
            get: { retranscribeTarget != nil },
            set: { if !$0 { retranscribeTarget = nil } }
        )
    }

    private func updateObservedJobs(_ updatedJobs: [Job]) {
        jobs = updatedJobs
        // Do not advance the baseline from a partial publication. The next
        // poll must still perform a coherent full reload for this transition.
        contentObservation = nil
    }

    private func reloadAfterCorrectionConflict(
        _ currentRevision: TranscriptRevision?,
        session: TranscriptCorrectionSession
    ) async {
        guard transcriptPublication.acceptsSheetCallback(
            session.saveToken,
            identity: identity,
            currentMeetingID: meetingID
        ),
        currentRevision.map({ $0.meetingID == meetingID }) ?? true,
        let token = identity.token(for: meetingID)
        else { return }
        if currentRevision?.meetingID == meetingID {
            revision = currentRevision
        }
        contentObservation = nil
        await load(token)
    }

    private func presentCorrection(
        revision: TranscriptRevision,
        turnIndex: Int
    ) {
        guard let target = TranscriptCorrectionTarget(
            meetingID: meetingID,
            revision: revision,
            turnIndex: turnIndex
        ),
        let viewIdentity = identity.token(for: meetingID),
        let saveToken = transcriptPublication.sheetSaveToken(
            for: target,
            viewIdentity: viewIdentity
        ) else { return }
        correctionSession = TranscriptCorrectionSession(
            target: target,
            saveToken: saveToken
        )
    }

    private func publishSavedCorrection(
        _ updatedRevision: TranscriptRevision,
        session: TranscriptCorrectionSession
    ) {
        var publication = transcriptPublication
        guard publication.acceptsSavedRevision(
            updatedRevision,
            for: session.saveToken,
            identity: identity,
            currentMeetingID: meetingID
        ) else { return }
        transcriptPublication = publication
        revision = updatedRevision
        contentObservation = nil
    }

    private func adoptPendingTranscript(
        _ presentation: PendingTranscriptPresentation
    ) {
        guard !isAdoptingPendingTranscript,
              correctionAvailability.isAvailable,
              let token = identity.token(for: meetingID)
        else { return }
        isAdoptingPendingTranscript = true
        pendingAdoptionPresentation = nil
        Task {
            let result = await app.adoptPendingTranscript(
                meetingID: token.value,
                expectedCurrentRevisionID:
                    presentation.expectedCurrentRevisionID,
                expectedCandidateID: presentation.expectedCandidateID
            )
            guard identity.accepts(token, currentValue: meetingID) else { return }
            contentObservation = nil
            await load(token)
            guard identity.accepts(token, currentValue: meetingID) else { return }
            pendingAdoptionPresentation =
                PendingTranscriptAdoptionPresentation.make(result)
            isAdoptingPendingTranscript = false
        }
    }

    private var deleteTargetIsPresented: Binding<Bool> {
        Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )
    }

    private func requestDiarization() {
        guard !isRequestingDiarization,
              let token = identity.token(for: meetingID)
        else { return }
        isRequestingDiarization = true
        Task {
            let updated = await app.requestMeetingDiarization(for: token.value)
            guard identity.accepts(token, currentValue: meetingID) else { return }
            diarizationState = updated
            await load(token)
            guard identity.accepts(token, currentValue: meetingID) else { return }
            isRequestingDiarization = false
        }
    }

    private func adoptPendingDiarization() {
        guard !isRequestingDiarization,
              let expectedCurrentRevisionID = revision?.id,
              let token = identity.token(for: meetingID)
        else { return }
        isRequestingDiarization = true
        Task {
            let updated = await app.adoptPendingMeetingDiarization(
                for: token.value,
                expectedCurrentRevisionID: expectedCurrentRevisionID
            )
            guard identity.accepts(token, currentValue: meetingID) else { return }
            diarizationState = updated
            await load(token)
            guard identity.accepts(token, currentValue: meetingID) else { return }
            isRequestingDiarization = false
        }
    }

    private func diarizationStatus(
        _ presentation: MeetingDiarizationPresentation
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(presentation.title, systemImage: "person.2.wave.2")
                .font(.subheadline.weight(.semibold))
            Text(presentation.message)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let action = presentation.action {
                Button(presentation.actionTitle) {
                    switch action {
                    case .openAudioReadiness:
                        showAudioReadiness()
                    case .request:
                        requestDiarization()
                    case .adoptPending:
                        adoptPendingDiarization()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRequestingDiarization)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.thinMaterial)
    }

    private func jobStatus(_ presentation: MeetingJobPresentation) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ProgressView()
            VStack(alignment: .leading, spacing: 4) {
                Text(presentation.title)
                    .font(.subheadline.weight(.semibold))
                Text(presentation.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.thinMaterial)
    }

    private func importedMeetingSummary(
        _ presentation: MeetingTransferDetailPresentation
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(presentation.originLabel, systemImage: "airdrop")
                .font(.subheadline.weight(.semibold))
            Text("Contents: \(presentation.contentLabel)")
            Text("Source language: \(presentation.sourceLanguageLabel)")
            Label(presentation.externalFileWarning, systemImage: "folder")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.thinMaterial)
    }
}

private struct MeetingActionsMenu: View {
    let movePolicy: IOSSidebarMeetingActionPolicy
    let canRetranscribe: Bool
    let canDelete: Bool
    let move: (FolderID?) -> Void
    let retranscribe: () -> Void
    let delete: () -> Void

    var body: some View {
        Menu {
            Menu("Move to Folder", systemImage: "folder") {
                IOSMeetingMoveActions(policy: movePolicy, move: move)
            }

            Divider()

            Button {
                retranscribe()
            } label: {
                Label("Transcribe Again...", systemImage: "waveform")
            }
            .disabled(!canRetranscribe)

            Divider()

            Button(role: .destructive) {
                delete()
            } label: {
                Label("Move to Trash...", systemImage: "trash")
            }
            .disabled(!canDelete)
        } label: {
            Image(systemName: "ellipsis.circle")
                .accessibilityLabel("Meeting actions")
        }
    }
}

/// Loads the status before the transcript. Once a job reports completed, its
/// exact revision pointer has therefore already been observed by the shared
/// status boundary and the following transcript read cannot return the older
/// pre-commit revision from the same pipeline transition.
@MainActor
struct MeetingDiarizationSnapshot<Revision> {
    let state: MeetingDiarizationJobState
    let revision: Revision

    static func load(
        status: () async -> MeetingDiarizationJobState,
        revision: () async -> Revision
    ) async -> Self {
        let state = await status()
        let revision = await revision()
        return Self(state: state, revision: revision)
    }
}

/// The inexpensive identity of content that can change while a detail view
/// remains open. It reads only the revision pointer, in-memory model readiness,
/// job documents, and the derived speaker-separation status. Full transcript
/// decoding remains in `load(_:)`, which runs only after one of these
/// identities changes. Every transcription, diarization, and speaker-matching
/// job remains in the fingerprint through its terminal state, so a short job
/// that starts and finishes between two polls is still observable.
///
/// The derived status must be part of this identity: `.unavailable`,
/// `.ready`, and `.modelsRequired` also depend on inputs the pointer, the
/// readiness flag, and the job fingerprint do not capture (the revision's
/// final-ASR provenance chain, the finished run metadata, and the meeting's
/// processing generation). Without it, a status that flips from
/// `.unavailable` to `.ready` or `.modelsRequired` while pointer and jobs
/// stay unchanged would never trigger a reload.
struct MeetingContentObservation: Equatable {
    struct JobFingerprint: Equatable {
        let id: JobID
        let kind: Job.Kind
        let status: Job.Status
        let transcriptionProviderID: TranscriptionProviderID?
        let createdAt: Date
        let errorMessage: String?
    }

    let currentRevisionPointer: CurrentRevisionPointer?
    let diarizationModelsReady: Bool?
    let diarizationState: MeetingDiarizationJobState
    let jobFingerprint: [JobFingerprint]

    init(
        currentRevisionPointer: CurrentRevisionPointer?,
        diarizationModelsReady: Bool?,
        jobs: [Job],
        diarizationState: MeetingDiarizationJobState = .unavailable
    ) {
        self.currentRevisionPointer = currentRevisionPointer
        self.diarizationModelsReady = diarizationModelsReady
        self.diarizationState = diarizationState
        jobFingerprint = jobs
            .filter {
                $0.kind == .finalASR
                    || $0.kind == .diarization
                    || $0.kind == .identitySuggestion
            }
            .map {
                JobFingerprint(
                    id: $0.id,
                    kind: $0.kind,
                    status: $0.status,
                    transcriptionProviderID: $0.transcriptionProviderID,
                    createdAt: $0.createdAt,
                    errorMessage: $0.errorMessage
                )
            }
            .sorted { $0.id < $1.id }
    }

    @MainActor
    static func load(
        currentRevisionPointer: () async -> CurrentRevisionPointer?,
        diarizationModelsReady: () async -> Bool?,
        diarizationState: () async -> MeetingDiarizationJobState,
        jobs: () async -> [Job]
    ) async -> Self {
        let revisionPointer = await currentRevisionPointer()
        let modelsReady = await diarizationModelsReady()
        let state = await diarizationState()
        let jobs = await jobs()
        return Self(
            currentRevisionPointer: revisionPointer,
            diarizationModelsReady: modelsReady,
            jobs: jobs,
            diarizationState: state
        )
    }

    func requiresReload(after previous: Self?) -> Bool {
        self != previous
    }
}

struct MeetingEmptyState: Equatable {
    let title: LocalizedStringResource
    let systemImage: String
    let description: LocalizedStringResource
}

enum MeetingActionPolicy {
    static func canRetranscribe(status: Meeting.Status?) -> Bool {
        guard let status else { return false }
        return status != .recording
    }

    static func canDelete(status: Meeting.Status?) -> Bool {
        guard let status else { return false }
        return status != .recording
    }
}

enum MeetingActionCopy {
    static let retranscriptionMessage = LocalizedStringResource(
        "meeting.retranscription.message",
        defaultValue: "Steno adds a new transcript revision and keeps the current transcript and corrections as earlier revisions.\nSpeaker separation runs again with new cluster identifiers, so speakers must be confirmed again.\nYour corrections are never silently overwritten."
    )
    static let deletionMessage = LocalizedStringResource(
        "meeting.deletion.message",
        defaultValue: "The entire meeting folder, including its original recording, transcript revisions, notes, and reports, moves to the system Trash. Use Undo to restore it while Steno remains open, if the system provides a recoverable Trash location."
    )
    static let deletionConfirmationLabel: LocalizedStringResource = "Move to Trash"
    static let retranscriptionFailureTitle: LocalizedStringResource =
        "Transcription could not be started"
    static let deletionFailureTitle: LocalizedStringResource =
        "Meeting could not be moved to Trash"
    static let cleanupWarningTitle: LocalizedStringResource = "Meeting moved to Trash"

    static func retranscriptionTitle(
        meetingTitle: String
    ) -> LocalizedStringResource {
        "Transcribe “\(meetingTitle)” again?"
    }

    static func deletionTitle(meetingTitle: String) -> LocalizedStringResource {
        "Move “\(meetingTitle)” to the Trash?"
    }
}

enum MeetingActionAlert {
    case retranscriptionFailure(String)
    case deletionFailure(String)
    case cleanupWarning(String)

    var title: LocalizedStringResource {
        switch self {
        case .retranscriptionFailure:
            MeetingActionCopy.retranscriptionFailureTitle
        case .deletionFailure:
            MeetingActionCopy.deletionFailureTitle
        case .cleanupWarning:
            MeetingActionCopy.cleanupWarningTitle
        }
    }

    var message: String {
        switch self {
        case .retranscriptionFailure(let message),
             .deletionFailure(let message),
             .cleanupWarning(let message):
            message
        }
    }
}

struct MeetingJobPresentation: Equatable {
    let title: LocalizedStringResource
    let message: LocalizedStringResource

    static func make(_ jobs: [Job]) -> MeetingJobPresentation? {
        for status in [Job.Status.running, .queued] {
            for kind in [Job.Kind.finalASR, .diarization, .identitySuggestion]
            where jobs.contains(where: { $0.kind == kind && $0.status == status }) {
                return presentation(kind: kind, status: status)
            }
        }
        return nil
    }

    private static func presentation(
        kind: Job.Kind,
        status: Job.Status
    ) -> MeetingJobPresentation? {
        switch (kind, status) {
        case (.finalASR, .queued):
            MeetingJobPresentation(
                title: "Transcription queued",
                message: "Step 1 of 3. Steno will transcribe the original audio on this device."
            )
        case (.finalASR, .running):
            MeetingJobPresentation(
                title: "Transcribing on this device",
                message: "Step 1 of 3. Steno is creating a new transcript from the original audio."
            )
        case (.diarization, .queued):
            MeetingJobPresentation(
                title: "Speaker separation queued",
                message: "Step 2 of 3. Steno will create new speaker clusters for this transcript."
            )
        case (.diarization, .running):
            MeetingJobPresentation(
                title: "Separating speakers",
                message: "Step 2 of 3. Steno is creating new speaker clusters on this device."
            )
        case (.identitySuggestion, .queued):
            MeetingJobPresentation(
                title: "Speaker matching queued",
                message: "Step 3 of 3. Steno will compare the new speaker clusters with confirmed voices."
            )
        case (.identitySuggestion, .running):
            MeetingJobPresentation(
                title: "Matching speakers",
                message: "Step 3 of 3. Steno is comparing speaker clusters with confirmed voices on this device."
            )
        case (.finalASR, .finished), (.finalASR, .failed), (.finalASR, .cancelled),
             (.diarization, .finished), (.diarization, .failed), (.diarization, .cancelled),
             (.identitySuggestion, .finished), (.identitySuggestion, .failed),
             (.identitySuggestion, .cancelled), (.templateRender, _), (.export, _):
            nil
        }
    }
}

enum MeetingJobSnapshotPublication {
    static func accepted(
        _ jobs: [Job],
        for token: ViewIdentityGeneration<MeetingID>.Token,
        identity: ViewIdentityGeneration<MeetingID>,
        currentMeetingID: MeetingID
    ) -> [Job]? {
        guard identity.accepts(token, currentValue: currentMeetingID) else {
            return nil
        }
        return jobs
    }
}

enum MeetingPresentation {
    static func canEditNotes(status: Meeting.Status?) -> Bool {
        guard let status else { return false }
        return status != .recording
    }

    static func canShareMeeting(status: Meeting.Status?) -> Bool {
        guard let status else { return false }
        return status != .recording && status != .interrupted
    }

    static func emptyState(
        status: Meeting.Status?,
        hasAudio: Bool
    ) -> MeetingEmptyState {
        if status == .draft {
            return MeetingEmptyState(
                title: "Draft",
                systemImage: "square.and.pencil",
                description: "This meeting holds a note and no recording yet."
            )
        }
        if hasAudio {
            return MeetingEmptyState(
                title: "No transcript yet",
                systemImage: "text.quote",
                description: "Audio saved. No transcript yet. If the speech model is missing, install it under Audio readiness. Steno retries automatically."
            )
        }
        return MeetingEmptyState(
            title: "No transcript yet",
            systemImage: "text.quote",
            description: "This meeting has no saved audio or transcript yet."
        )
    }
}

struct MeetingDiarizationPresentation: Equatable {
    enum Action: Equatable {
        case openAudioReadiness
        case request
        case adoptPending
    }

    let title: LocalizedStringResource
    let message: LocalizedStringResource
    let action: Action?

    var actionTitle: LocalizedStringResource {
        switch action {
        case .adoptPending:
            "Use speaker labels"
        case .openAudioReadiness, .request, nil:
            "Separate speakers"
        }
    }

    static func make(
        _ state: MeetingDiarizationJobState
    ) -> MeetingDiarizationPresentation? {
        switch state {
        case .unavailable:
            nil
        case .modelsRequired:
            MeetingDiarizationPresentation(
                title: "Separate speakers",
                message: "Install the optional speaker separation models under Audio readiness first.",
                action: .openAudioReadiness
            )
        case .ready:
            MeetingDiarizationPresentation(
                title: "Separate speakers",
                message: "Create speaker labels for this transcript. This does not identify people by name.",
                action: .request
            )
        case .queued:
            MeetingDiarizationPresentation(
                title: "Speaker separation queued",
                message: "Steno will create speaker labels for this transcript.",
                action: nil
            )
        case .running:
            MeetingDiarizationPresentation(
                title: "Separating speakers",
                message: "Steno is creating speaker labels on this device.",
                action: nil
            )
        case .resultsPending:
            MeetingDiarizationPresentation(
                title: "Speaker labels ready",
                message: "Your edited transcript is still shown. Use the speaker labels to switch to the separated version; your edit remains saved as an earlier revision.",
                action: .adoptPending
            )
        case .completed:
            MeetingDiarizationPresentation(
                title: "Speaker separation completed",
                message: "Speaker labels are available in the transcript.",
                action: nil
            )
        case .failed:
            MeetingDiarizationPresentation(
                title: "Speaker separation failed",
                message: "The speaker labels could not be created.",
                action: nil
            )
        }
    }
}

struct SpeakerDisplayDetails: Equatable {
    let label: String?
    let marker: SpeakerMarker?
    let originCue: String?

    init(
        presentation: SpeakerPresentation,
        locale: Locale = .autoupdatingCurrent
    ) {
        label = SpeakerDisplayLocalization.label(presentation, locale: locale)
        marker = presentation.marker
        originCue = SpeakerDisplayLocalization.originCue(
            presentation,
            locale: locale
        )
    }
}

/// One turn: timestamp, speaker, text.
struct TranscriptTurnRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let turn: TranscriptTurn
    let turnIndex: Int
    let review: MeetingReviewData?
    var presentationContext: SpeakerPresentationContext = .empty
    var query: String = ""
    var correctionAvailability: TranscriptCorrectionAvailability = .available
    var correct: (() -> Void)?

    var body: some View {
        let presentation = SpeakerPresentationResolver.presentation(
            for: turn.speaker,
            review: review,
            context: presentationContext
        )
        let speaker = SpeakerDisplayDetails(presentation: presentation)
        IOSTranscriptRowLayout(
            axis: IOSAdaptiveStackAxis.axis(for: dynamicTypeSize)
        ) {
            Text(timestamp(turn.start))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        } content: {
            HStack(alignment: .top, spacing: Steno.Space.s) {
                VStack(alignment: .leading, spacing: 2) {
                    if let label = speaker.label {
                        HStack(spacing: 5) {
                            // The marker is an addition to the name, never its
                            // replacement: colour carries no information alone.
                            if let color = Steno.Colors.speaker(speaker.marker) {
                                Circle()
                                    .fill(color)
                                    .frame(width: 7, height: 7)
                                    .accessibilityHidden(true)
                            }
                            Text(label)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let originCue = speaker.originCue {
                        Text(originCue)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(highlighted)
                        .font(Steno.readingBody)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let correct {
                    Button {
                        correct()
                    } label: {
                        Image(systemName: "pencil")
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(!correctionAvailability.isAvailable)
                    .accessibilityLabel(TranscriptCorrectionCopy.actionLabel)
                    .accessibilityHint(correctionAccessibilityHint)
                    .accessibilityIdentifier(
                        "transcript-correction-\(turnIndex)"
                    )
                }
            }
        }
        .padding(.vertical, 6)
    }

    /// Marks the search term inside the line instead of only filtering to it,
    /// so a hit is findable in a long turn.
    private var highlighted: AttributedString {
        var text = AttributedString(Self.text(of: turn))
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return text }
        var search = text.startIndex..<text.endIndex
        while let found = text[search].range(
            of: needle,
            options: .caseInsensitive
        ) {
            text[found].backgroundColor = .yellow.opacity(0.35)
            guard found.upperBound < text.endIndex else { break }
            search = found.upperBound..<text.endIndex
        }
        return text
    }

    static func text(of turn: TranscriptTurn) -> String {
        TranscriptTurnPresentation.text(of: turn)
    }

    private var correctionAccessibilityHint: LocalizedStringResource {
        correctionAvailability.blockReason?.message
            ?? TranscriptCorrectionCopy.actionHint
    }

    private func timestamp(_ seconds: TimeInterval) -> String {
        // Past an hour "1:12:45" is readable, "72:45" is not.
        let total = Int(seconds.rounded())
        let (hours, minutes, secs) = (total / 3600, (total % 3600) / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }
}
