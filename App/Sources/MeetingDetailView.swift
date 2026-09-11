import StenoDomain
import StenoPipeline
import SwiftUI

struct MeetingDetailObservationState {
    struct Key: Hashable {
        let meetingID: MeetingID
        let generation: UInt64
        let jobActivity: UInt64
    }

    private var generation: UInt64 = 0

    /// `jobActivity` traegt AppModel.meetingJobActivity[meetingID] herein:
    /// steigt er, weil irgendwo im Programm ein Job fuer dieses Meeting
    /// eingereiht wurde, aendert sich der Key genauso wie nach einem
    /// manuellen Klick, und SwiftUI startet .task(id:) neu.
    func key(for meetingID: MeetingID, jobActivity: UInt64 = 0) -> Key {
        Key(meetingID: meetingID, generation: generation, jobActivity: jobActivity)
    }

    mutating func restartAfterManualProcessingRequest() {
        generation &+= 1
    }
}

enum MeetingDetailObservationPolicy {
    static func shouldContinue(
        hasRevision: Bool,
        jobs: [Job],
        transferStatus: MeetingTransferDetailPresentation.ProcessingStatus?
    ) -> Bool {
        if jobs.contains(where: { $0.status == .queued || $0.status == .running }) {
            return true
        }
        if let transferStatus {
            return transferStatus == .processing
        }
        return !hasRevision
    }
}

struct MeetingDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openWindow) private var openWindow
    let meetingID: MeetingID

    @State private var revision: TranscriptRevision?
    @State private var jobs: [StenoDomain.Job] = []
    @State private var review: MeetingReviewData?
    /// Importierte Alt-Meetings bringen ein Transkript ohne Wortzeitstempel
    /// mit; die Sprechererkennung transkribiert dann zuerst neu.
    @State private var needsTranscriptionFirst = false
    @State private var meeting: Meeting?
    @State private var duration: TimeInterval?
    @State private var speakerPresentationContext = SpeakerPresentationContext.empty
    /// Der Inspector oeffnet sich von selbst, solange Sprecherarbeit ansteht,
    /// und bleibt danach zu - er ist Werkzeug, nicht Daueranzeige.
    @State private var showInspector = false
    @State private var didDecideInspector = false
    /// Genau eine Zeile ist bearbeitbar. Mehrere offene Felder auf demselben
    /// Stand wuerden beim zweiten Speichern an der Elternpruefung scheitern -
    /// zu Recht, aber ohne dass jemand versteht, warum.
    @State private var editingTurn: Int?
    @State private var transcriptQuery = ""
    @State private var showFind = false
    @FocusState private var findFocused: Bool
    @State private var pending: TranscriptRevision?
    /// Sofortiges UI-Gate: gespeicherte Jobs werden erst nach dem ersten
    /// await sichtbar. Bis dahin darf ein zweiter Klick nicht durchkommen.
    @State private var isStartingSpeakerProcessing = false
    @State private var transferDetail: MeetingTransferDetailPresentation?
    @State private var transferLocaleIdentifier = ""
    @State private var transferLanguageConfirmed = false
    @State private var isWorkingOnTransfer = false
    @State private var observationState = MeetingDetailObservationState()
    @State private var showMeetingTransferExport = false
    @State private var showContinueRecordingConfirmation = false
    /// Kurzer Bestaetigungsblitz nach dem Kopieren der Notizen: das Icon im
    /// Werkzeugkasten zeigt fuer einen Moment den Haken statt der Aktion.
    @State private var showsCopyNotesFlash = false
    /// Turn a citation button jumped to; highlighted briefly, then cleared.
    @State private var citedTurnIndex: Int?

    var body: some View {
        Group {
            if let revision, !revision.turns.isEmpty {
                transcriptList(revision)
            } else {
                ContentUnavailableView(
                    meeting?.status == .draft ? "Draft" : "No transcript yet",
                    systemImage: meeting?.status == .draft
                        ? "square.and.pencil"
                        : "text.quote",
                    description: Text(pendingDescription)
                )
            }
        }
        .safeAreaInset(edge: .top) {
            VStack(spacing: 0) {
                if meeting?.isDemo == true {
                    HStack {
                        DemoBadge()
                        Spacer()
                    }
                    .padding(.horizontal, Steno.Space.m)
                    .padding(.vertical, Steno.Space.xs)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background)
                    Divider()
                }
                meetingTransferTopStatus
                pendingBanner
                legacyUpgradeTopStatus
                jobStatusBar
                findBar
            }
            .animation(statusAnimation, value: pipelineStatus.state)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let meeting, meeting.status != .recording {
                meetingAskDock
            }
        }
        .navigationTitle(meeting?.title ?? "")
        .navigationSubtitle(subtitle)
        .inspector(isPresented: $showInspector) { inspectorContent }
        .toolbar(id: MacToolbarID.meetingDetail.rawValue) {
            ToolbarItem(
                id: MacToolbarItemID.findTranscript.rawValue,
                placement: .primaryAction
            ) {
                Button {
                    showFind = true
                    findFocused = true
                } label: {
                    Label("Find in transcript", systemImage: "magnifyingglass")
                }
                .help("Find in this transcript (Cmd-F)")
                .disabled(revision == nil)
            }
            .defaultCustomization(
                MacToolbarPresentation.defaultCustomization(
                    for: .findTranscript,
                    in: .meetingDetail
                )
            )
            ToolbarItem(
                id: MacToolbarItemID.inspector.rawValue,
                placement: .primaryAction
            ) {
                Toggle(isOn: $showInspector) {
                    Label("Details", systemImage: "sidebar.right")
                }
                .help("Show notes, participants and speaker assignment")
            }
            .defaultCustomization(
                MacToolbarPresentation.defaultCustomization(
                    for: .inspector,
                    in: .meetingDetail
                )
            )
            ToolbarItem(
                id: MacToolbarItemID.shareMeeting.rawValue,
                placement: .primaryAction
            ) {
                Menu {
                    Button("Copy Notes") {
                        Task {
                            if await model.copyNotesToPasteboard(for: meetingID) != nil {
                                showsCopyNotesFlash = true
                            }
                        }
                    }
                    .disabled(meeting == nil)
                    Button("Share as PDF…") {
                        Task { await model.shareNotesAsPDF(for: meetingID) }
                    }
                    .disabled(meeting == nil)
                    Divider()
                    Button("Export Meeting as Markdown…") {
                        let action = MacFocusedAsyncAction(target: meetingID) {
                            await model.exportMeetingToFile($0)
                        }
                        Task { await action() }
                    }
                    Button("Export to Obsidian Vault") {
                        Task { await model.exportMeetingToObsidianVault(meetingID) }
                    }
                } label: {
                    Label(
                        "Share Notes",
                        systemImage: showsCopyNotesFlash ? "checkmark" : "square.and.arrow.up"
                    )
                }
                .help("Copy the notes, share them as a PDF or export the meeting")
            }
            .defaultCustomization(
                MacToolbarPresentation.defaultCustomization(
                    for: .shareMeeting,
                    in: .meetingDetail
                )
            )
            if showsContinueRecording {
                ToolbarItem(
                    id: MacToolbarItemID.continueRecording.rawValue,
                    placement: .primaryAction
                ) {
                    Button {
                        showContinueRecordingConfirmation = true
                    } label: {
                        Label(
                            meeting?.status == .draft ? "Record into this note" : "Continue Recording",
                            systemImage: meeting?.status == .draft ? "mic" : "record.circle"
                        )
                    }
                    .help("Record additional audio into this meeting")
                }
                .defaultCustomization(
                    MacToolbarPresentation.defaultCustomization(
                        for: .continueRecording,
                        in: .meetingDetail
                    )
                )
            }
        }
        .sheet(isPresented: $showMeetingTransferExport) {
            MeetingTransferExportView(meetingID: meetingID)
                .environment(model)
        }
        .focusedSceneValue(
            \.stenoMeetingDetailCommandContext,
            detailCommandContext
        )
        .task(id: observationState.key(
            for: meetingID,
            jobActivity: model.meetingJobActivity[meetingID] ?? 0
        )) { await refreshLoop() }
        // Eine offene Bearbeitung ueberlebt weder einen Filterwechsel noch
        // einen neuen Transkriptstand: im ersten Fall verschwindet die Zeile
        // unter dem offenen Feld, im zweiten zeigt der Index auf einen anderen
        // Turn. Das Speichern faenge das ueber die Elternpruefung ab, aber der
        // Benutzer haette bis dahin in ein totes Feld getippt.
        .onChange(of: transcriptQuery) { editingTurn = nil }
        .onChange(of: revision?.id) { editingTurn = nil }
        // Citation buttons in the minutes post this; scroll the cited turn
        // into view and let the highlight decay below.
        .onReceive(
            NotificationCenter.default.publisher(
                for: TranscriptCitations.citeTranscriptLineNotification
            )
        ) { note in
            guard let index = TranscriptCitations.citedLineIndex(from: note),
                  let revision,
                  revision.turns.indices.contains(index)
            else { return }
            citedTurnIndex = index
        }
        .task(id: citedTurnIndex) {
            guard citedTurnIndex != nil else { return }
            try? await Task.sleep(for: .seconds(2.5))
            citedTurnIndex = nil
        }
        // Der Kopierblitz loescht sich selbst: kurz sichtbar, dann zurueck
        // zum Aktions-Icon, ohne dass ein zweiter Timer irgendwo laeuft.
        .task(id: showsCopyNotesFlash) {
            guard showsCopyNotesFlash else { return }
            try? await Task.sleep(for: .seconds(1.6))
            showsCopyNotesFlash = false
        }
        .confirmationDialog(
            continueRecordingTitle,
            isPresented: $showContinueRecordingConfirmation,
            titleVisibility: .visible
        ) {
            Button(meeting?.status == .draft ? "Record into this note" : "Continue Recording") {
                Task { await model.continueRecording(in: meetingID) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if meeting?.status == .draft {
                Text("Audio will be recorded and transcribed into this note.")
            } else {
                Text("New audio is appended after the existing recordings and transcribed into the same meeting.")
            }
        }
    }

    /// Der Anhang-Knopf gehoert zu ruhenden Meetings: versteckt, solange
    /// irgendeine Aufnahme laeuft oder startet, waehrend ein Meeting in der
    /// Pipeline verarbeitet wird, und im Demo-Bestand ganz. Ein Entwurf ist
    /// ebenfalls ein Ziel - dort landet die erste Aufnahme im bestehenden
    /// Meeting statt in einem neuen.
    var showsContinueRecording: Bool {
        guard !model.isRecording,
              !model.isStartingRecording,
              meeting?.isDemo != true,
              let status = meeting?.status else { return false }
        return status != .recording && status != .processing
    }

    var continueRecordingTitle: String {
        if meeting?.status == .draft { return String(localized: "Record into this note?") }
        return "Continue recording in \u{201C}\(meeting?.title ?? "")\u{201D}?"
    }

    private var detailCommandContext: MacMeetingDetailCommandContext {
        let capturedMeetingID = meetingID
        return MacMeetingDetailCommandContext(
            meetingID: capturedMeetingID,
            availability: MacMeetingDetailCommandAvailability(
                hasTranscript: revision != nil,
                meetingStatus: meeting?.status
            ),
            findTranscript: {
                showFind = true
                findFocused = true
            },
            toggleInspector: {
                showInspector.toggle()
            },
            share: {
                guard capturedMeetingID == meetingID else { return }
                showMeetingTransferExport = true
            }
        )
    }

    @ViewBuilder
    private var meetingTransferTopStatus: some View {
        if let transferDetail {
            VStack(alignment: .leading, spacing: Steno.Space.s) {
                HStack(alignment: .firstTextBaseline) {
                    Label("Imported via AirDrop", systemImage: "airplayaudio")
                        .font(.headline)
                    Spacer()
                    Text(transferDetail.receipt.importedAt.formatted(
                        date: .abbreviated,
                        time: .shortened
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Text(
                    transferDetail.hasAudio
                        ? "Audio included in the received meeting."
                        : "No audio was included in the received meeting."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                meetingTransferProcessingStatus(transferDetail)
            }
            .padding(.horizontal, Steno.Space.m)
            .padding(.vertical, Steno.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background)
            Divider()
        }
    }

    @ViewBuilder
    private func meetingTransferProcessingStatus(
        _ detail: MeetingTransferDetailPresentation
    ) -> some View {
        switch detail.processingStatus {
        case .ready:
            Label("Ready", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
            if detail.actions.contains(.process) {
                meetingTransferLanguageAction(
                    detail,
                    title: "Process recording"
                )
            }
        case .completed:
            Label("Ready - processing completed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
        case .confirmLanguage:
            Label("Confirm language", systemImage: "character.bubble")
                .foregroundStyle(.secondary)
            if detail.actions.contains(.confirmLanguage) {
                meetingTransferLanguageAction(
                    detail,
                    title: "Confirm language and process"
                )
            }
        case .modelMissing(let localeIdentifier):
            let installation = MacMeetingTransferModelInstallationPresentation.make(
                canInstall: detail.actions.contains(.installModelAndProcess),
                isInstallingAny: model.isInstallingModels,
                isInstallingBaseline: model.isInstallingBaselineModels,
                showsCancellationAction: model.showsModelInstallationCancellationAction,
                cancellationState: model.modelInstallationCancellationState,
                progress: model.modelInstallProgress
            )
            VStack(alignment: .leading, spacing: Steno.Space.xs) {
                Label(
                    "Model missing for \(languageName(localeIdentifier))",
                    systemImage: "arrow.down.circle"
                )
                .foregroundStyle(.secondary)
                Text("No download or processing job starts automatically. Installation downloads speech assets from Apple and speaker separation from huggingface.co.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let progress = installation.progress {
                    meetingTransferModelInstallProgress(progress)
                }
                if let action = installation.action {
                    meetingTransferModelInstallAction(
                        action,
                        localeIdentifier: localeIdentifier
                    )
                }
                if let error = model.modelError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Steno.Colors.error)
                        .textSelection(.enabled)
                }
            }
        case .processing:
            HStack(spacing: Steno.Space.xs) {
                ProgressView().controlSize(.small)
                Text("Processing")
            }
            .foregroundStyle(.secondary)
        case .failed(let localeIdentifier, let reason):
            VStack(alignment: .leading, spacing: Steno.Space.xs) {
                Label(
                    "Processing failed for \(languageName(localeIdentifier)): \(reason)",
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(Steno.Colors.error)
                if detail.actions.contains(.retry) {
                    meetingTransferLanguageAction(
                        detail,
                        title: "Retry"
                    )
                }
            }
        case .recoveryRequired:
            Label(
                "Retry the import after recovery. No processing job was created.",
                systemImage: "arrow.clockwise.circle"
            )
            .foregroundStyle(Steno.Colors.error)
        }
    }

    private func meetingTransferLanguageAction(
        _ detail: MeetingTransferDetailPresentation,
        title: String
    ) -> some View {
        VStack(alignment: .leading, spacing: Steno.Space.xs) {
            Picker("Spoken language", selection: $transferLocaleIdentifier) {
                Text("Choose a language").tag("")
                ForEach(model.availableLocales, id: \.identifier) { locale in
                    Text(model.localizedLanguageName(locale)).tag(locale.identifier)
                }
            }
            .onChange(of: transferLocaleIdentifier) {
                transferLanguageConfirmed = false
            }
            Toggle(
                "I confirm this is the language spoken in the recording.",
                isOn: $transferLanguageConfirmed
            )
            .disabled(transferLocaleIdentifier.isEmpty)
            Button(title) {
                requestTransferProcessing(detail)
            }
            .controlSize(.small)
            .disabled(
                isWorkingOnTransfer
                    || transferLocaleIdentifier.isEmpty
                    || !transferLanguageConfirmed
            )
        }
    }

    @ViewBuilder
    private func meetingTransferModelInstallProgress(
        _ progress: MacModelInstallProgressPresentation
    ) -> some View {
        switch progress {
        case .indeterminate(let title):
            ProgressView {
                Text(title)
            }
        case .determinate(let title, let fraction):
            ProgressView(value: fraction, total: 1) {
                Text(title)
            } currentValueLabel: {
                Text("\(Int((fraction * 100).rounded())) %")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    @ViewBuilder
    private func meetingTransferModelInstallAction(
        _ action: MacModelInstallActionPresentation,
        localeIdentifier: String
    ) -> some View {
        switch action {
        case .install(let title):
            Button {
                installTransferModelAndProcess(localeIdentifier)
            } label: {
                Text(title)
            }
            .controlSize(.small)
            .disabled(isWorkingOnTransfer)
        case .cancel(let title):
            Button {
                Task { await model.cancelModelInstallation() }
            } label: {
                Text(title)
            }
            .controlSize(.small)
        case .cancelling(let title):
            Button {} label: {
                Text(title)
            }
            .controlSize(.small)
            .disabled(true)
        }
    }

    private func requestTransferProcessing(
        _ detail: MeetingTransferDetailPresentation
    ) {
        guard detail.hasAudio,
              !transferLocaleIdentifier.isEmpty,
              transferLanguageConfirmed,
              !isWorkingOnTransfer else { return }
        isWorkingOnTransfer = true
        Task {
            defer { isWorkingOnTransfer = false }
            let ready = await model.meetingTransferModelsReady(
                for: transferLocaleIdentifier
            )
            guard await model.retryImportedMeetingProcessing(
                meetingID: meetingID,
                localeIdentifier: transferLocaleIdentifier,
                modelsReady: ready
            ) else { return }
            transferLanguageConfirmed = false
            updateTransferDetail(
                await model.loadMeetingTransferDetail(meetingID: meetingID)
            )
            jobs = await model.jobs(for: meetingID)
            observationState.restartAfterManualProcessingRequest()
        }
    }

    private func installTransferModelAndProcess(_ localeIdentifier: String) {
        guard !isWorkingOnTransfer else { return }
        isWorkingOnTransfer = true
        Task {
            defer { isWorkingOnTransfer = false }
            guard await model.installMeetingTransferModels(
                for: localeIdentifier
            ) else { return }
            guard await model.retryImportedMeetingProcessing(
                meetingID: meetingID,
                localeIdentifier: localeIdentifier,
                modelsReady: true
            ) else { return }
            updateTransferDetail(
                await model.loadMeetingTransferDetail(meetingID: meetingID)
            )
            jobs = await model.jobs(for: meetingID)
            observationState.restartAfterManualProcessingRequest()
        }
    }

    private func languageName(_ localeIdentifier: String) -> String {
        model.meetingTransferLocale(identifier: localeIdentifier)
            .map(model.localizedLanguageName)
            ?? localeIdentifier
    }

    /// Sprecherarbeit steht neben dem Transkript, nicht darueber: Wer eine
    /// Hoerprobe prueft, will den Kontext im Transkript sehen, ohne zwischen
    /// zwei Enden derselben Liste zu springen.
    @ViewBuilder
    private var inspectorContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Steno.Space.xl) {
                NotesSection(meetingID: meetingID)
                Divider()
                ParticipantsSection(meetingID: meetingID, review: review)
                if review != nil {
                    Divider()
                    SpeakerReviewSection(
                        meetingID: meetingID,
                        revision: revision,
                        review: $review,
                        isDemo: meeting?.isDemo ?? false
                    )
                } else if !isSpeakerProcessing,
                          model.meetingsWithAudio.contains(meetingID) {
                    Divider()
                    diarizationStart
                }
            }
            .padding(Steno.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .inspectorColumnWidth(min: 300, ideal: 360, max: 460)
    }

    /// Diarisierung und Anhören setzen die Originalspur voraus; ohne Audio
    /// (Altimport, geloeschte Spur) gibt es beides nicht.
    private var diarizationStart: some View {
        VStack(alignment: .leading, spacing: Steno.Space.xs) {
            Button {
                startSpeakerProcessing()
            } label: {
                Label(
                    needsTranscriptionFirst
                        ? "Re-transcribe and detect speakers"
                        : "Detect speakers",
                    systemImage: "person.2.wave.2"
                )
            }
            .help("Compute diarization and speaker suggestions for this meeting")
            .disabled(isSpeakerProcessing || isStartingSpeakerProcessing)
            if needsTranscriptionFirst {
                Text("This imported meeting has no word-level timestamps. Steno re-transcribes the recording for them; the existing transcript is kept as an earlier version.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func transcriptList(_ revision: TranscriptRevision) -> some View {
        // Die Suche filtert, gibt aber die **echten** Turn-Indizes weiter.
        // Mit den Positionen der Trefferliste zu arbeiten hiesse, eine
        // Korrektur an Treffer 2 an Turn 2 des Transkripts zu schreiben.
        let hits = TranscriptSearch.matchingTurnIndices(
            in: revision,
            query: transcriptQuery
        )
        var seenSpeakers: Set<SpeakerReference?> = []
        let originCueIndices = Set(hits.filter { seenSpeakers.insert(revision.turns[$0].speaker).inserted })
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Steno.Space.m) {
                    if let meeting {
                        MeetingEditorialHeader(
                            meeting: meeting,
                            duration: duration
                        )
                    }
                    originNote(revision.origin)
                    if let meeting {
                        TitleSuggestionSection(
                            meetingID: meetingID,
                            revision: revision,
                            meeting: meeting
                        )
                    }
                    ReportsSection(meetingID: meetingID, review: review, unrecordedTracks: meeting?.unrecordedTracks ?? [])
                    Divider()
                    if isSearchingTranscript {
                        Text(hits.isEmpty
                            ? "No line contains \u{201C}\(transcriptQuery)\u{201D}."
                            : "\(hits.count) of \(revision.turns.count) lines")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(hits, id: \.self) { index in
                        let turn = revision.turns[index]
                        TranscriptTurnRow(
                            turn: turn,
                            review: review,
                            presentationContext: speakerPresentationContext,
                            showsOriginCue: originCueIndices.contains(index),
                            meetingID: meetingID,
                            isEditing: editingTurn == index,
                            beginEditing: { editingTurn = index },
                            cancelEditing: { editingTurn = nil },
                            endEditing: { text in
                                await save(text, at: index, in: revision)
                            }
                        )
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(
                                    citedTurnIndex == index
                                        ? Color.accentColor.opacity(0.16)
                                        : .clear
                                )
                        )
                        .id(index)
                    }
                }
                .padding(.horizontal, 36)
                .padding(.vertical, 28)
                .frame(maxWidth: Steno.Layout.readingWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Steno.Surfaces.paper(colorScheme))
            // The jump target exists only after a citation button fires.
            .onChange(of: citedTurnIndex) { _, newIndex in
                guard let newIndex else { return }
                proxy.scrollTo(newIndex, anchor: .top)
            }
        }
    }

    private var meetingAskDock: some View {
        HStack {
            Spacer()
            Button {
                LibraryChatModel.queueIntent(LibraryChatModel.Intent(
                    presetDraft: nil,
                    meetingIDs: [meetingID]
                ))
                openWindow(id: "library-chat")
            } label: {
                HStack(spacing: Steno.Space.s) {
                    Image(systemName: "sparkle.magnifyingglass")
                    Text("Ask this meeting")
                    Image(systemName: "arrow.up.right")
                        .font(.caption2)
                        .foregroundStyle(Steno.Surfaces.quietInk(colorScheme))
                }
                .font(.callout.weight(.medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(
                    Steno.Surfaces.paper(colorScheme),
                    in: Capsule()
                )
                .overlay {
                    Capsule()
                        .strokeBorder(Steno.Surfaces.border(colorScheme))
                }
            }
            .buttonStyle(.plain)
            .help("Open Library Chat scoped to this meeting")
            Spacer()
        }
        .padding(.horizontal, Steno.Space.l)
        .padding(.vertical, Steno.Space.s)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    /// Eigene Leiste statt `.searchable`: Die Seitenleiste belegt den
    /// Suchplatz des Fensters bereits, und zwei `.searchable` im selben
    /// NavigationSplitView streiten sich um dasselbe Feld.
    @ViewBuilder
    private var findBar: some View {
        if showFind {
            HStack(spacing: Steno.Space.s) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Find in transcript", text: $transcriptQuery)
                    .textFieldStyle(.plain)
                    .focused($findFocused)
                    .onExitCommand { closeFind() }
                Button {
                    closeFind()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Close the search")
            }
            .padding(.horizontal, Steno.Space.m)
            .padding(.vertical, Steno.Space.s)
            .background(.background.secondary)
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    private func closeFind() {
        transcriptQuery = ""
        showFind = false
    }

    private var isSearchingTranscript: Bool {
        !transcriptQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Speichert eine Korrektur und uebernimmt den neuen Stand sofort in die
    /// Ansicht - sonst zeigt sie bis zum naechsten Schleifendurchlauf den
    /// alten Text und der Benutzer tippt ihn ein zweites Mal.
    private func save(
        _ text: String,
        at index: Int,
        in revision: TranscriptRevision
    ) async {
        if let updated = await model.saveTranscriptEdit(
            meetingID: meetingID,
            revision: revision,
            turnIndex: index,
            text: text
        ) {
            self.revision = updated
        }
        editingTurn = nil
    }

    /// Der Neulauf, der wegen einer eigenen Korrektur wartet. Ohne diesen
    /// Hinweis wartet er fuer immer: die Bibliothek parkt ihn, damit er die
    /// Korrektur nicht ueberschreibt, und niemand haette ihn je gesehen.
    @ViewBuilder
    private var pendingBanner: some View {
        if let pending {
            HStack(alignment: .firstTextBaseline, spacing: Steno.Space.s) {
                Label(
                    "A newer transcription is ready. Your correction is shown instead.",
                    systemImage: "clock.arrow.circlepath"
                )
                .font(.callout)
                Spacer()
                Button("Use the new one") {
                    Task {
                        guard let displayed = revision else { return }
                        _ = await model.adoptPendingTranscript(
                            for: meetingID,
                            expectedCurrentRevisionID: displayed.id,
                            expectedCandidateID: pending.id
                        )
                        revision = await model.transcript(for: meetingID)
                        self.pending = await model.pendingTranscript(for: meetingID)
                        review = await model.loadReviewData(meetingID: meetingID, revision: revision)
                    }
                }
                .controlSize(.small)
                .help("Your correction stays stored as an earlier version")
            }
            .padding(Steno.Space.s)
            .background(.background.secondary)
        }
    }

    /// Datum, Dauer und Zustand in einer Zeile - bei mehreren gleich
    /// benannten Aufnahmen war bisher nicht erkennbar, worin man arbeitet.
    private var subtitle: String {
        guard let meeting else { return "" }
        var parts = [
            meeting.createdAt.formatted(
                .dateTime.day().month().year().hour().minute()
            ),
        ]
        if let duration {
            parts.append(Self.durationText(duration))
        }
        if meeting.status != .ready {
            parts.append(statusWord(meeting.status))
        }
        if let missing = MeetingCompleteness.missingTracksWord(
            meeting.unrecordedTracks
        ) {
            parts.append(missing)
        }
        return parts.joined(separator: "  ·  ")
    }

    private func statusWord(_ status: Meeting.Status) -> String {
        switch status {
        case .draft: String(localized: "Draft")
        case .recording: String(localized: "Recording")
        case .interrupted: String(localized: "Interrupted")
        case .processing: String(localized: "Processing")
        case .ready: String(localized: "Ready")
        }
    }

    static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let (hours, minutes, secs) = (total / 3600, (total % 3600) / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d min", minutes, secs)
    }

    private var legacyUpgradeState: LegacyUpgradePresentation {
        LegacyUpgradePresentation.state(
            meeting: meeting,
            revision: revision,
            reviewRunID: review?.runID,
            jobs: jobs,
            hasAudio: model.meetingsWithAudio.contains(meetingID),
            needsTranscriptionFirst: needsTranscriptionFirst
        )
    }

    @ViewBuilder
    private var legacyUpgradeTopStatus: some View {
        if legacyUpgradeState != .hidden {
            legacyUpgradeBanner
                .padding(.horizontal, Steno.Space.m)
                .padding(.vertical, Steno.Space.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background)
            Divider()
        }
    }

    @ViewBuilder
    private var legacyUpgradeBanner: some View {
        switch legacyUpgradeState {
        case .hidden:
            EmptyView()
        case .unavailable:
            legacyUpgradeExplanation
        case .ready(let actionTitle):
            VStack(alignment: .leading, spacing: Steno.Space.xs) {
                legacyUpgradeExplanation
                legacyUpgradeButton(actionTitle)
            }
        case .running(let job):
            VStack(alignment: .leading, spacing: Steno.Space.xs) {
                legacyUpgradeExplanation
                HStack(spacing: Steno.Space.xs) {
                    ProgressView()
                        .controlSize(.small)
                    Text(LegacyUpgradePresentation.stepTitle(for: job.kind))
                    Text(LegacyUpgradePresentation.modelTitle(for: job))
                        .foregroundStyle(.secondary)
                    Text("for \(Text(job.createdAt, style: .relative))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .font(.callout)
            }
        case .failed(let message, let actionTitle):
            VStack(alignment: .leading, spacing: Steno.Space.xs) {
                legacyUpgradeExplanation
                Label(
                    "Processing failed: \(message)",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.callout)
                .foregroundStyle(Steno.Colors.error)
                if let actionTitle {
                    legacyUpgradeButton(actionTitle)
                }
            }
        }
    }

    private var legacyUpgradeExplanation: some View {
        Label(
            "Taken over from the legacy Steno app: the timestamps are imprecise and the speaker assignment comes from the old recognition.",
            systemImage: "clock.badge.exclamationmark"
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func legacyUpgradeButton(_ title: String) -> some View {
        Button {
            startSpeakerProcessing()
        } label: {
            Label(title, systemImage: "person.2.wave.2")
        }
        .controlSize(.small)
        .help("Compute precise timestamps, diarization and speaker suggestions")
        .disabled(isSpeakerProcessing || isStartingSpeakerProcessing)
    }

    private func startSpeakerProcessing() {
        guard !isStartingSpeakerProcessing else { return }
        isStartingSpeakerProcessing = true
        Task {
            defer { isStartingSpeakerProcessing = false }
            let started = await model.requestDiarization(meetingID: meetingID)
            jobs = await model.jobs(for: meetingID)
            guard started else { return }
            await refreshLoop()
        }
    }

    @ViewBuilder
    private func originNote(_ origin: TranscriptOrigin) -> some View {
        switch origin {
        case .liveProvisional:
            Label(
                "Provisional live transcript; the final run replaces it.",
                systemImage: "hourglass"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        case .legacyImport, .demo:
            EmptyView()
        case .finalRun, .userEdit, .meetingTransfer:
            EmptyView()
        }
    }

    /// Die Statusleiste gehört der Transkriptions-Kette (finalASR,
    /// Diarisierung, Identität). Protokoll-Jobs melden Fortschritt und
    /// Fehler im Protokoll-Bereich, dem konkreten Lauf zugeordnet; ein
    /// alter Protokoll-Fehlschlag darf hier nicht dauerhaft leuchten.
    private var transcriptionJobs: [Job] {
        jobs.filter { $0.kind != .templateRender && $0.kind != .export }
    }

    private var isSpeakerProcessing: Bool {
        transcriptionJobs.contains {
            $0.status == .queued || $0.status == .running
        }
    }

    private var pipelineStatus: MeetingPipelineStatusPresentation {
        MeetingPipelineStatusPresentation.make(
            jobs: jobs,
            isSuppressed: legacyUpgradeOwnsProcessingStatus
                || MeetingPipelineStatusPresentation.transferOwnsStatus(
                    transferDetail?.processingStatus
                )
        )
    }

    @ViewBuilder
    private var jobStatusBar: some View {
        switch pipelineStatus.state {
        case .hidden:
            EmptyView()
        case .active(let job):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                if let title = pipelineStatus.activeTitle {
                    Text(title)
                        .font(.callout)
                }
                // Die Kette liefert keinen Fortschrittswert. Die verstrichene
                // Zeit ist das Ehrlichste, was sich anzeigen lässt, und sie
                // unterscheidet "rechnet noch" von "hängt".
                Text("for \(Text(job.createdAt, style: .relative))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
            }
            .padding(8)
            .background(.background.secondary)
            .transition(statusTransition)
        case .failed(let failed):
            VStack(alignment: .leading, spacing: Steno.Space.xs) {
                HStack {
                    Label {
                        Text(MeetingPipelineStatusPresentation.failureTitle)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                        .font(.callout)
                        .foregroundStyle(Steno.Colors.error)
                    Spacer()
                    // Ausdrueckliches Angebot, kein stiller Rueckfall: der
                    // Nutzer entscheidet, nicht das Programm (Falle 3).
                    if failed.kind == .finalASR,
                       failed.transcriptionProviderID == .parakeetTDTv3 {
                        Button("Run with Apple") {
                            Task {
                                await model.retryFinalASRWithApple(failed)
                                jobs = await model.jobs(for: meetingID)
                            }
                        }
                    }
                }
                if let detail = failed.errorMessage, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.background.secondary)
            .transition(statusTransition)
        }
    }

    private var statusMotionPolicy: MacStatusMotionPolicy {
        MacStatusMotionPolicy(reduceMotion: accessibilityReduceMotion)
    }

    private var statusAnimation: Animation? {
        statusMotionPolicy == .reduced ? nil : .default
    }

    private var statusTransition: AnyTransition {
        guard statusMotionPolicy.usesPositionalMovement else { return .opacity }
        return .move(edge: .top).combined(with: .opacity)
    }

    private var legacyUpgradeOwnsProcessingStatus: Bool {
        switch legacyUpgradeState {
        case .running, .failed: true
        case .hidden, .unavailable, .ready: false
        }
    }

    private var pendingDescription: LocalizedStringResource {
        if meeting?.status == .draft {
            "Write your notes on the right. Start a recording when the meeting begins."
        } else if jobs.contains(where: { $0.status == .running || $0.status == .queued }) {
            "The final transcription is still running."
        } else {
            "There is no transcript for this meeting."
        }
    }

    /// Aktualisiert Transkript und Jobstatus, solange die Ansicht sichtbar
    /// ist; endet, sobald kein Job mehr offen ist und ein Transkript da ist.
    private func refreshLoop() async {
        while !Task.isCancelled {
            speakerPresentationContext = await model.speakerPresentationContext(
                for: meetingID
            )
            revision = await model.transcript(for: meetingID)
            jobs = await model.jobs(for: meetingID)
            review = await model.loadReviewData(meetingID: meetingID, revision: revision)
            meeting = await model.meeting(meetingID)
            updateTransferDetail(
                await model.loadMeetingTransferDetail(meetingID: meetingID)
            )
            duration = await model.duration(for: meetingID)
            // Verhindert veraltete Audio-Zusagen: sonst blieben Abspiel- und
            // Diarisierungs-Knöpfe nach einer Spurlöschung klickbar.
            await model.refreshAudioAvailability(meetingID)
            needsTranscriptionFirst = ((try? await model.hasFinalASRRun(meetingID)) ?? true) == false
            pending = await model.pendingTranscript(for: meetingID)
            decideInspectorOnce()
            if !MeetingDetailObservationPolicy.shouldContinue(
                hasRevision: revision != nil,
                jobs: jobs,
                transferStatus: transferDetail?.processingStatus
            ) {
                break
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func updateTransferDetail(
        _ detail: MeetingTransferDetailPresentation?
    ) {
        let previousGeneration = transferDetail?.receipt.importGenerationID
        let previousStatus = transferDetail?.processingStatus
        transferDetail = detail
        guard let detail else {
            transferLocaleIdentifier = ""
            transferLanguageConfirmed = false
            return
        }
        let generationChanged = previousGeneration
            != detail.receipt.importGenerationID
        let statusChanged = previousStatus != detail.processingStatus
        guard generationChanged || statusChanged || transferLocaleIdentifier.isEmpty else {
            return
        }
        let suggestedIdentifier: String? = switch detail.processingStatus {
        case .modelMissing(let localeIdentifier),
             .failed(let localeIdentifier, _):
            localeIdentifier
        case .ready, .completed, .confirmLanguage, .processing, .recoveryRequired:
            detail.receipt.sourceLocaleOrigin == .absent
                ? nil
                : detail.receipt.sourceLocaleIdentifier
        }
        if let suggestedIdentifier,
           let locale = model.meetingTransferLocale(identifier: suggestedIdentifier) {
            transferLocaleIdentifier = locale.identifier
        } else if generationChanged {
            transferLocaleIdentifier = ""
        }
        if generationChanged || statusChanged {
            transferLanguageConfirmed = false
        }
    }

    /// Einmal je Meeting entscheiden, nicht bei jedem Schleifendurchlauf:
    /// Sonst risse der Inspector dem Benutzer nach jeder Bestaetigung die
    /// Ansicht unter den Haenden weg.
    private func decideInspectorOnce() {
        // Ein Entwurf besteht aus nichts als seiner Notiz - dort ist der
        // Inspector nicht Werkzeug, sondern der ganze Inhalt.
        if !didDecideInspector, meeting?.status == .draft {
            didDecideInspector = true
            showInspector = true
            return
        }
        guard !didDecideInspector, let review else { return }
        didDecideInspector = true
        showInspector = review.clusters.contains { cluster in
            guard !cluster.isSelf, !cluster.containsMultipleSpeakers else {
                return false
            }
            if case .confirmed = cluster.reviewState { return false }
            return true
        }
    }

    private func timestamp(_ seconds: TimeInterval) -> String {
        // Ab einer Stunde ist "1:12:45" lesbar, "72:45" nicht mehr.
        let total = Int(seconds.rounded())
        let (hours, minutes, secs) = (total / 3600, (total % 3600) / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }
}

private struct MeetingEditorialHeader: View {
    @Environment(\.colorScheme) private var colorScheme

    let meeting: Meeting
    let duration: TimeInterval?

    var body: some View {
        VStack(alignment: .leading, spacing: Steno.Space.m) {
            Text(meeting.title)
                .font(Steno.Typography.meetingTitle)
                .foregroundStyle(Steno.Surfaces.ink(colorScheme))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Steno.Space.s) {
                metadataChip(
                    meeting.createdAt.formatted(
                        .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()
                    ),
                    systemImage: "calendar"
                )
                if let duration {
                    metadataChip(
                        MeetingDetailView.durationText(duration),
                        systemImage: "clock"
                    )
                }
                if meeting.status != .ready {
                    metadataChip(statusLabel, systemImage: "circle.dotted")
                }
                if meeting.isDemo {
                    DemoBadge()
                }
            }
        }
        .padding(.bottom, Steno.Space.s)
    }

    private func metadataChip(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.monospacedDigit())
            .foregroundStyle(Steno.Surfaces.quietInk(colorScheme))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                Steno.Surfaces.sunkenPaper(colorScheme),
                in: Capsule()
            )
    }

    private var statusLabel: String {
        switch meeting.status {
        case .draft: String(localized: "Draft")
        case .recording: String(localized: "Recording")
        case .interrupted: String(localized: "Interrupted")
        case .processing: String(localized: "Processing")
        case .ready: String(localized: "Ready")
        }
    }
}

/// Ein Transkript-Turn mit Anhören-per-Klick: Play am Zeitstempel spielt
/// genau diesen Turn aus der Originalspur, zur Verifikation des Gehörten.
struct TranscriptTurnRow: View {
    @Environment(AppModel.self) private var model
    let turn: TranscriptTurn
    let review: MeetingReviewData?
    var presentationContext: SpeakerPresentationContext = .empty
    var showsOriginCue = true
    let meetingID: MeetingID
    var isEditing = false
    var beginEditing: (() -> Void)?
    var cancelEditing: (() -> Void)?
    var endEditing: ((String) async -> Void)?

    @State private var hovering = false
    @State private var draft = ""
    @State private var isSaving = false

    var body: some View {
        let presentation = SpeakerPresentationResolver.presentation(
            for: turn.speaker,
            review: review,
            context: presentationContext
        )
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(timestamp(turn.start))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                if model.meetingsWithAudio.contains(meetingID) {
                    Button {
                        Task {
                            await model.toggleSample(
                                playbackSample(channel: playbackChannel(for: presentation)),
                                meetingID: meetingID
                            )
                        }
                    } label: {
                        Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle")
                            .foregroundStyle(isPlaying ? AnyShapeStyle(Steno.Colors.recording) : AnyShapeStyle(.secondary))
                            .opacity(isPlaying ? 1 : (hovering ? 1 : 0.3))
                    }
                    .buttonStyle(.plain)
                    // Abspielen liefe in die laufende Aufnahme hinein.
                    .disabled(model.isRecording)
                    .help(model.isRecording
                        ? "Not while recording - it would be captured into the recording"
                        : "Play this section")
                    .accessibilityLabel(isPlaying ? "Stop playback" : "Play this section")
                }
            }
            .frame(width: 52, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                if let label = SpeakerDisplayLocalization.label(presentation) {
                    HStack(spacing: 5) {
                        // Der Marker ist eine Zugabe zum Namen, nie sein
                        // Ersatz: Farbe traegt hier keine Information allein.
                        if let color = Steno.Colors.speaker(presentation.marker) {
                            Circle()
                                .fill(color)
                                .frame(width: 7, height: 7)
                                .accessibilityHidden(true)
                        }
                        Text(label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    if let cue = SpeakerDisplayLocalization.originCue(presentation) {
                        if showsOriginCue {
                            Label(cue, systemImage: "text.badge.checkmark")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel(cue)
                        } else {
                            Image(systemName: "text.badge.checkmark")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .help(Text(cue))
                                .accessibilityLabel(cue)
                        }
                    }
                }
                if isEditing {
                    editor
                } else {
                    Text(Self.turnText(turn))
                        .textSelection(.enabled)
                        .font(Steno.readingBody)
                        .lineSpacing(3)
                }
            }
            if !isEditing, beginEditing != nil {
                Spacer(minLength: Steno.Space.s)
                Button {
                    draft = Self.turnText(turn)
                    beginEditing?()
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                // Erscheint erst beim Darueberfahren: Korrigieren ist die
                // Ausnahme, Lesen der Normalfall, und ein Stift an jeder Zeile
                // machte aus dem Transkript ein Formular.
                .opacity(hovering ? 1 : 0)
                .help("Correct this line")
                .accessibilityLabel("Correct this line")
            }
        }
        .onHover { hovering = $0 }
    }

    /// Korrigieren heisst tippen, nicht neu diktieren: das Feld startet mit
    /// dem erkannten Text. Escape verwirft, Cmd-Return speichert - Return
    /// allein bleibt ein Zeilenumbruch, weil eine Wortmeldung ueber mehrere
    /// Zeilen laufen kann.
    private var editor: some View {
        VStack(alignment: .leading, spacing: Steno.Space.xs) {
            TextEditor(text: $draft)
                .font(Steno.readingBody)
                .frame(minHeight: 60)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.tertiary)
                }
                .onExitCommand { cancelEditing?() }
            HStack(spacing: Steno.Space.s) {
                Text("The recognised text stays available as an earlier version.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                // Abbrechen darf nicht ueber den Speicherweg laufen. `turnText`
                // streicht ein fuehrendes Satzzeichen kosmetisch weg - der
                // "unveraenderte" Text waere also veraendert und haette beim
                // Abbrechen eine echte Korrektur angelegt.
                Button("Cancel") { cancelEditing?() }
                .controlSize(.small)
                Button("Save") { submit() }
                    .controlSize(.small)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(isSaving)
            }
        }
    }

    private func submit() {
        guard !isSaving else { return }
        isSaving = true
        Task {
            await endEditing?(draft)
            isSaving = false
        }
    }

    /// Der ganze Turn als abspielbarer Bereich, ohne 20-s-Deckel: hier geht
    /// es um Verifikation des Inhalts, nicht um eine Hörprobe.
    private func playbackSample(channel: String) -> SpeakerSample {
        SpeakerSample(
            turnStart: turn.start,
            clipStart: turn.start,
            clipEnd: max(turn.end, turn.start + 0.5),
            text: "",
            channel: channel
        )
    }

    private func playbackChannel(for presentation: SpeakerPresentation) -> String {
        switch turn.speaker {
        case .cluster:
            return presentation.channel ?? ""
        case .channel(let label):
            // Kanal-Labels der Live-/Finalläufe: "Ich" = Mikrofonspur.
            return label == "Ich"
                ? MediaAsset.Kind.micTrack.rawValue
                : MediaAsset.Kind.systemTrack.rawValue
        case .person, .importedTextLabel, .none:
            return ""
        }
    }

    private var isPlaying: Bool { model.playingSampleID == turn.start }

    /// Laeuft ein Satz ueber die Blockgrenze, beginnt der naechste Turn mit
    /// dem Satzzeichen des vorigen (". Und dann ..."). Rein kosmetisch: Der
    /// gespeicherte Text bleibt unveraendert, damit Zeitmarken und
    /// Wortbezuege weiter stimmen.
    static func turnText(_ turn: TranscriptTurn) -> String {
        let joined = turn.segments.map(\.text).joined(separator: " ")
        let trimmed = joined.drop { $0.isWhitespace || $0.isPunctuation }
        return trimmed.isEmpty ? joined : String(trimmed)
    }

    private func timestamp(_ seconds: TimeInterval) -> String {
        // Ab einer Stunde ist "1:12:45" lesbar, "72:45" nicht mehr.
        let total = Int(seconds.rounded())
        let (hours, minutes, secs) = (total / 3600, (total % 3600) / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }
}
