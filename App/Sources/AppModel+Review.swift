import AVFAudio
import Foundation
import StenoDomain
import StenoIdentity
import StenoLibrary
import StenoPipeline
import SwiftUI

enum SpeakerPlaybackAssetSelection {
    static func asset(
        from assets: [MediaAsset],
        channel: String
    ) -> MediaAsset? {
        if !channel.isEmpty {
            return assets.first { $0.kind.rawValue == channel }
        }
        guard assets.count == 1 else { return nil }
        return assets[0]
    }
}

enum TemporaryPlaybackFile {
    static func retainingOnSuccess<Result>(
        at url: URL,
        _ operation: () throws -> Result
    ) rethrows -> Result {
        do {
            return try operation()
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}

private enum AppModelReportPreflightError: LocalizedError {
    case runtimeUnavailable

    var errorDescription: String? {
        String(localized: "The library is not ready yet.")
    }
}

private struct DemoDataObservingNotesPersistence: MeetingNotesPersistence {
    let store: MeetingNotesStore
    let didPersist: @MainActor @Sendable (MeetingID) async -> Void

    func notes(_ meetingID: MeetingID) async throws -> String? {
        try await store.notes(meetingID)
    }

    func setNotes(_ meetingID: MeetingID, to notes: String?) async throws {
        try await store.setNotes(meetingID, to: notes)
        await didPersist(meetingID)
    }
}

extension AppModel {
    // MARK: - Sprecher-Review

    func loadReviewData(meetingID: MeetingID) async -> MeetingReviewData? {
        guard let runtime else { return nil }
        return try? await MeetingReviewAssembler.load(
            library: runtime.library,
            meetingID: meetingID
        )
    }

    // MARK: - Teilnehmer

    /// Alle bekannten Personen der Bibliothek, für die Teilnehmer-Auswahl.
    func allPersons() async -> [Person] {
        guard let runtime else { return [] }
        let layout = await runtime.library.layout
        let persons = (try? await IdentityStore(layout: layout).listPersons()) ?? []
        return persons.sorted { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }
    }

    /// Kontaktadresse pflegen. Leere Eingabe loescht sie; eine offensichtlich
    /// kaputte wird abgelehnt, statt sie zu speichern und beim Versand zu
    /// scheitern.
    @discardableResult
    func setPersonEmail(_ personID: PersonID, to email: String?) async -> Bool {
        guard let runtime else { return false }
        let layout = await runtime.library.layout
        do {
            try await IdentityStore(layout: layout).setPersonEmail(personID, to: email)
            return true
        } catch LibraryError.invalidPersonEmail {
            report("That is not a valid e-mail address.")
            return false
        } catch {
            report(AppModel.message("The e-mail address could not be saved.", error))
            return false
        }
    }

    @discardableResult
    func setPersonOrganization(_ personID: PersonID, to organization: String?) async -> Bool {
        guard let runtime else { return false }
        let layout = await runtime.library.layout
        do {
            try await IdentityStore(layout: layout)
                .setPersonOrganization(personID, to: organization)
            return true
        } catch {
            report(AppModel.message("The organization could not be saved.", error))
            return false
        }
    }

    func meeting(_ meetingID: MeetingID) async -> Meeting? {
        guard let runtime else { return nil }
        return try? await runtime.library.loadMeeting(meetingID)
    }

    // MARK: - Notizen

    func notesSession(for meetingID: MeetingID) async -> MeetingNotesEditingSession? {
        if let session = notesSessions[meetingID] {
            await session.load()
            return session
        }
        guard let runtime else { return nil }
        let store = DemoDataObservingNotesPersistence(
            store: MeetingNotesStore(layout: runtime.library.layout),
            didPersist: { [weak self] meetingID in
                await self?.demoDataMeetingContentDidChange(meetingID)
            }
        )
        let session = MeetingNotesEditingSession(meetingID: meetingID, store: store)
        notesSessions[meetingID] = session
        await session.load()
        return session
    }

    func notes(for meetingID: MeetingID) async -> String {
        await notesSession(for: meetingID)?.text ?? ""
    }

    /// Haelt die laufende Aufnahmezeit in der Notiz fest. Der haeufigste
    /// Impuls im Gespraech ist nicht "ich will etwas notieren", sondern "das
    /// eben war wichtig" - dafuer ist selbst ein Stichwort zu teuer.
    ///
    /// Bewusst in der Notizdatei statt in einem eigenen Datenmodell: So
    /// fliesst die Marke ohne Zutun in den Protokoll-Prompt, und sie
    /// ueberlebt jeden Neulauf der Erkennung.
    func markMoment() async {
        guard isRecording,
              let meetingID = recordingMeetingID,
              let start = recordingStartedAt
        else { return }
        guard let session = await notesSession(for: meetingID) else { return }
        await session.appendMarker(elapsed: Date().timeIntervalSince(start))
        if let error = session.errorMessage {
            report("The marker could not be saved. (\(error))")
        } else {
            report("Moment marked.", isError: false)
        }
    }

    /// Ein Meeting ohne Aufnahme, um vor dem Termin Notizen zu schreiben.
    /// Es zaehlt bewusst nicht als gestrandete Aufnahme.
    @discardableResult
    func createDraftMeeting() async -> MeetingID? {
        guard let runtime else { return nil }
        do {
            let meeting = try await runtime.library.createMeeting(
                title: Self.draftTitle(),
                status: .draft
            )
            await refreshMeetings()
            selectedMeetingID = meeting.id
            return meeting.id
        } catch {
            report(AppModel.message("The draft could not be created.", error))
            return nil
        }
    }

    private static func draftTitle() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return String(localized: "Notes \(formatter.string(from: Date()))")
    }

    /// Ergänzt eine Person als Anwesende ohne Redebeitrag. `name` legt bei
    /// Bedarf eine neue Person an, damit stille Teilnehmer nicht erst über
    /// die Sprecherprüfung entstehen müssen.
    func addAdditionalParticipant(
        _ personID: PersonID?,
        name: String?,
        meetingID: MeetingID
    ) async {
        guard let runtime else { return }
        do {
            reviewError = nil
            let layout = await runtime.library.layout
            let store = try IdentityStore(layout: layout)
            let resolvedID: PersonID
            if let personID {
                resolvedID = personID
            } else {
                let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                resolvedID = try await store.createPerson(displayName: trimmed).id
            }
            let meeting = try await runtime.library.loadMeeting(meetingID)
            guard !meeting.participantIDs.contains(resolvedID),
                  !meeting.additionalParticipantIDs.contains(resolvedID)
            else { return }
            try await runtime.library.updateAdditionalMeetingParticipants(
                meetingID,
                participantIDs: meeting.additionalParticipantIDs + [resolvedID]
            )
        } catch let LibraryError.duplicatePersonName(name) {
            reviewError = String(localized: "A person named \(name) already exists.")
        } catch {
            reviewError = AppModel.message("The participant could not be added.", error)
        }
    }

    func removeAdditionalParticipant(
        _ personID: PersonID,
        meetingID: MeetingID
    ) async {
        guard let runtime else { return }
        do {
            let meeting = try await runtime.library.loadMeeting(meetingID)
            try await runtime.library.updateAdditionalMeetingParticipants(
                meetingID,
                participantIDs: meeting.additionalParticipantIDs.filter { $0 != personID }
            )
        } catch {
            reviewError = AppModel.message("The participant could not be removed.", error)
        }
    }

    func performReview(
        _ action: MeetingReviewController.Action,
        on cluster: IdentityCluster,
        data: MeetingReviewData,
        meetingID: MeetingID
    ) async -> MeetingReviewData? {
        guard let runtime else { return nil }
        do {
            reviewError = nil
            let updated = try await MeetingReviewController(library: runtime.library)
                .perform(action, on: cluster, data: data, meetingID: meetingID)
            await demoDataDidPersistSpeakerReview(for: meetingID)
            return updated
        } catch MeetingReviewController.ReviewActionError.stale {
            reviewError = String(localized: "The review state changed. The view has been reloaded; please try again.")
            return await loadReviewData(meetingID: meetingID)
        } catch MeetingReviewController.ReviewActionError
            .demoMeetingCannotCreateVoiceEvidence {
            reviewError = Self.demoVoiceEvidenceRestrictionMessage
            return nil
        } catch let LibraryError.duplicatePersonName(name) {
            reviewError = String(localized: "A person named \(name) already exists.")
            return nil
        } catch let error as IdentityReviewError {
            reviewError = Self.reviewMessage(for: error)
            return nil
        } catch {
            reviewError = String(localized: "Assigning the speaker failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Rohe Fehlernamen gehören nicht in die Oberfläche.
    static func reviewMessage(for error: IdentityReviewError) -> String {
        switch error {
        case .clusterNotFound:
            String(localized: "This speaker belongs to a superseded run. Please reload the view.")
        case .ambiguousClusterAlias:
            String(localized: "This speaker cannot be changed because its cluster provenance is ambiguous.")
        case .personNotFound:
            String(localized: "The selected person no longer exists.")
        case .mixedClusterCannotBeNamed:
            String(localized: "This section is marked as \u{201C}multiple people\u{201D} and cannot be assigned to one person.")
        case .selfClusterCannotBeNamed:
            String(localized: "Your own microphone track is not named as a person.")
        case .noAssignmentToReassign:
            String(localized: "There is no assignment here that could be changed.")
        case .voiceEvidenceForbidden:
            demoVoiceEvidenceRestrictionMessage
        }
    }

    private static let demoVoiceEvidenceRestrictionMessage = String(localized: "Demo meetings cannot create or change real voice profiles.")

    // MARK: - Hörproben

    func resolvePlaybackAsset(
        from assets: [MediaAsset],
        channel: String
    ) -> MediaAsset? {
        guard let asset = SpeakerPlaybackAssetSelection.asset(
            from: assets,
            channel: channel
        ) else {
            report("No original track found for the voice sample.")
            return nil
        }
        return asset
    }

    /// Spielt einen Ausschnitt der Originalspur ab (Toggle). Text und Audio
    /// stammen aus demselben Turn. Das Original bleibt unveraendert; fuer die
    /// Wiedergabe entsteht eine kurzlebige Kopie im Temp-Verzeichnis.
    func toggleSample(_ sample: SpeakerSample, meetingID: MeetingID) async {
        if playingSampleID == sample.id {
            stopSamplePlayback()
            return
        }
        stopSamplePlayback()
        guard !isRecordingSoDoNotPlay else { return }
        guard let runtime else { return }
        do {
            let assets = try await runtime.library.listMediaAssets(meetingID: meetingID)
            guard let asset = resolvePlaybackAsset(
                from: assets,
                channel: sample.channel
            ) else { return }
            let url = await runtime.library.layout.mediaFile(
                meetingID,
                fileName: asset.fileName
            )
            // Der Ausschnitt wird herausgelesen und als eigene Datei
            // abgespielt. Zwei Gruende: AVAudioPlayer kann in Opus-in-CAF
            // nicht springen (gemessen), und AVAudioEngine fasst auf macOS die
            // Eingangsseite an, was eine Mikrofon-Abfrage ausloest - fuer
            // reines Abspielen inakzeptabel.
            let clipURL = try Self.extractClip(
                from: url,
                start: sample.clipStart,
                // Nulllange Turns (Altimporte) bekommen eine hoerbare Mindestlaenge.
                duration: max(0.5, sample.duration)
            )
            let player = try TemporaryPlaybackFile.retainingOnSuccess(
                at: clipURL
            ) {
                try AVAudioPlayer(contentsOf: clipURL)
            }
            guard player.play() else {
                try? FileManager.default.removeItem(at: clipURL)
                report("Playback could not be started.")
                return
            }
            samplePlayer = player
            sampleClipURL = clipURL
            setPlayingSample(sample.id)
            samplePlaybackTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(player.duration + 0.2))
                guard !Task.isCancelled else { return }
                self?.stopSamplePlayback()
            }
        } catch {
            report("Playback failed: \(error.localizedDescription)")
        }
    }

    /// Beendet jede laufende Hoerprobe, gleich aus welcher Ansicht sie
    /// gestartet wurde. Es gibt genau einen Abspieler.
    /// Waehrend einer Aufnahme wird nichts abgespielt.
    ///
    /// Der Systemaudio-Tap nimmt auf, was der Mac ausgibt - eine Hoerprobe
    /// landete also mitten in der laufenden Aufnahme, mit der Stimme eines
    /// anderen Meetings. Das faellt frueh niemandem auf und ist hinterher
    /// nicht mehr herauszurechnen. Seit die Aufnahme die App nicht mehr
    /// sperrt, ist das ein erreichbarer Zustand und muss hier zu bleiben.
    var isRecordingSoDoNotPlay: Bool {
        guard isRecording else { return false }
        report(
            "Playback is off while recording: it would be captured into the recording.",
            isError: false
        )
        return true
    }

    func stopSamplePlayback() {
        samplePlaybackTask?.cancel()
        samplePlaybackTask = nil
        samplePlayer?.stop()
        samplePlayer = nil
        if let sampleClipURL {
            try? FileManager.default.removeItem(at: sampleClipURL)
        }
        sampleClipURL = nil
        setPlayingSample(nil)
        setPlayingPersonSample(nil)
    }

    /// Liest den Bereich framegenau aus dem Original und schreibt ihn als
    /// unkomprimierte Kopie in den Temp-Ordner. Das Original bleibt
    /// unangetastet; die Kopie verschwindet mit dem Ende der Wiedergabe.
    nonisolated static func extractClip(
        from url: URL,
        start: TimeInterval,
        duration: TimeInterval
    ) throws -> URL {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let startFrame = AVAudioFramePosition(max(0, start) * format.sampleRate)
        guard startFrame < file.length else {
            throw SamplePlaybackError.clipBeyondEnd
        }
        let wanted = AVAudioFramePosition(duration * format.sampleRate)
        let frameCount = AVAudioFrameCount(min(wanted, file.length - startFrame))
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: frameCount
              )
        else {
            throw SamplePlaybackError.clipBeyondEnd
        }
        file.framePosition = startFrame
        try file.read(into: buffer, frameCount: frameCount)

        let clipURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("steno-sample-\(UUID().uuidString).caf")
        return try TemporaryPlaybackFile.retainingOnSuccess(at: clipURL) {
            let output = try AVAudioFile(
                forWriting: clipURL,
                settings: format.settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
            try output.write(from: buffer)
            return clipURL
        }
    }

    enum SamplePlaybackError: Error {
        case clipBeyondEnd
    }

    /// Stößt die Sprechererkennung nachträglich an (Meetings von vor der
    /// Diarisierungs-Pipeline oder erneuter Lauf nach Modellwechsel).
    func requestDiarization(meetingID: MeetingID) async -> Bool {
        guard let runtime else { return false }
        do {
            let meeting = try await runtime.library.loadMeeting(meetingID)
            let jobs = try await runtime.jobStore.list().filter {
                $0.meetingID == meetingID
            }
            guard !SpeakerProcessingJobSelection.hasActiveJob(
                in: jobs,
                processingGenerationID: meeting.processingGenerationID
            ) else {
                return false
            }
            if try await DiarizationRequest.enqueueMissingIdentitySuggestion(
                library: runtime.library,
                jobStore: runtime.jobStore,
                meetingID: meetingID
            ) {
                noteJobEnqueued(for: meetingID)
                return true
            }
            if try await DiarizationRequest.enqueue(
                library: runtime.library,
                jobStore: runtime.jobStore,
                meetingID: meetingID
            ) {
                noteJobEnqueued(for: meetingID)
                return true
            }
            if let retry = SpeakerProcessingJobSelection.retryJob(
                in: jobs,
                processingGenerationID: meeting.processingGenerationID
            ) {
                let enqueued = try await runtime.jobStore.enqueueIfNoEquivalentJob(
                    retry,
                    blockingStatuses: [.queued, .running]
                )
                if enqueued { noteJobEnqueued(for: meetingID) }
                return enqueued
            }
            // Importierte Alt-Meetings haben keinen eigenen ASR-Lauf: Ihr
            // Transkript stammt aus der alten App. Die Sprechererkennung
            // braucht aber einen Lauf mit Wortzeitstempeln als Grundlage,
            // deshalb wird hier zuerst neu transkribiert; die Kette
            // finalASR -> Diarisierung -> Vorschläge läuft dann von selbst.
            guard await hasPlayableAudio(meetingID),
                  try await !hasFinalASRRun(meetingID)
            else { return false }
            let enqueued = try await runtime.jobStore.enqueueIfNoEquivalentJob(
                Job.finalASR(for: meeting),
                blockingStatuses: [.queued, .running]
            )
            if enqueued { noteJobEnqueued(for: meetingID) }
            return enqueued
        } catch {
            reviewError = AppModel.message("Speaker recognition could not be started.", error)
            return false
        }
    }

    /// Transkribiert ein Meeting neu. Die Kette finalASR -> Diarisierung ->
    /// Vorschlaege laeuft danach von selbst.
    ///
    /// Das bisherige Transkript wird nicht ueberschrieben: jeder Lauf schreibt
    /// eine neue Revision, die alten bleiben stehen. Was der Lauf sehr wohl
    /// entwertet, ist die Sprecher-Zuordnung - eine neue Diarisierung vergibt
    /// die Cluster-Kennungen neu, und Bestaetigungen gegen den alten Lauf
    /// gelten danach nicht mehr. Deshalb sagt der Aufrufer das vorher.
    func requestRetranscription(meetingID: MeetingID) async -> Bool {
        guard let runtime else { return false }
        do {
            try await MeetingProcessingJobRequest.requireUnpinnedJobAllowed(
                library: runtime.library,
                meetingID: meetingID
            )
            guard await hasPlayableAudio(meetingID) else {
                report("This meeting has no original audio to transcribe again.")
                return false
            }
            let meeting = try await runtime.library.loadMeeting(meetingID)
            let pending = try await runtime.jobStore.list().contains {
                $0.meetingID == meetingID
                    && $0.kind == .finalASR
                    && $0.processingGenerationID == meeting.processingGenerationID
                    && ($0.status == .queued || $0.status == .running)
            }
            guard !pending else {
                report("A transcription for this meeting is already running.", isError: false)
                return false
            }
            try await runtime.jobStore.enqueue(
                Job.finalASR(for: meeting)
            )
            noteJobEnqueued(for: meetingID)
            report("Transcribing again. The previous transcript stays available.", isError: false)
            return true
        } catch {
            report(AppModel.message("Transcription could not be started.", error))
            return false
        }
    }

    /// Ein abgeschlossener finalASR-Lauf ist die Alignment-Grundlage der
    /// Diarisierung; ohne ihn muss zuerst transkribiert werden.
    func hasFinalASRRun(_ meetingID: MeetingID) async throws -> Bool {
        guard let runtime else { return false }
        let layout = await runtime.library.layout
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: layout.runsDirectory(meetingID),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        let decoder = JSONDecoder()
        for entry in entries {
            guard let data = try? Data(
                contentsOf: entry.appendingPathComponent("run.json")
            ),
                let run = try? decoder.decode(ProcessingRun.self, from: data)
            else { continue }
            if run.kind == .finalASR, run.status == .finished { return true }
        }
        return false
    }

    // MARK: - Protokolle

    func reportPreflight(
        for meetingID: MeetingID
    ) async throws -> TemplateRenderPreflight {
        guard let runtime else {
            throw AppModelReportPreflightError.runtimeUnavailable
        }
        return try await TemplateRenderInputAssembler.preflight(
            library: runtime.library,
            meetingID: meetingID
        )
    }

    func reports(for meetingID: MeetingID) async -> [StoredTemplateResult] {
        guard let runtime else { return [] }
        let layout = await runtime.library.layout
        do {
            let listing = try TemplateResultStore(layout: layout)
                .listWithRepairOutcome(meetingID: meetingID)
            if listing.didRepair {
                await demoDataMeetingContentDidChange(meetingID)
            }
            return listing.results
        } catch {
            // Das Quarantänisieren kann vor einem fehlgeschlagenen
            // Wiederherstellen bereits den Meeting-Baum verändert haben.
            await demoDataMeetingContentDidChange(meetingID)
            return []
        }
    }

    /// Liefert den eingereihten Render samt sichtbarem Endpunkt-Snapshot,
    /// damit die UI Erfolg, Fehler und Offenlegung demselben Lauf zuordnet.
    func requestMeetingMinutes(
        meetingID: MeetingID,
        templateID: String? = nil,
        textModelEndpointID: String? = nil,
        textModelEndpointSnapshot: TextModelEndpointSnapshot? = nil,
        nativeGemmaModelSnapshot: NativeGemmaModelSnapshot? = nil,
        preflight: TemplateRenderPreflight
    ) async throws -> Job {
        guard let runtime else {
            throw AppModelReportPreflightError.runtimeUnavailable
        }
        // Explicit picker choice wins; otherwise this meeting's pinned
        // template (recording-time choice), then the default-template
        // setting, then Meeting Minutes. A pin pointing at a deleted
        // template falls through instead of failing the run.
        let pinnedTemplateID = (try? await runtime.library.loadMeeting(meetingID))?
            .metadata?.pinnedTemplateID
        let resolvedTemplateID = TemplateRenderRequest.resolveReportTemplateID(
            explicit: templateID,
            pinned: pinnedTemplateID
        )
        let job = try await TemplateRenderRequest.enqueue(
            library: runtime.library,
            jobStore: runtime.jobStore,
            meetingID: meetingID,
            templateID: resolvedTemplateID,
            textModelEndpointID: textModelEndpointID,
            textModelEndpointSnapshot: textModelEndpointSnapshot,
            nativeGemmaModelSnapshot: nativeGemmaModelSnapshot,
            preflight: preflight
        )
        return job
    }

    /// Bricht einen eingereihten oder laufenden Job ab. In der Commit-Phase
    /// lehnt die Pipeline das bewusst ab: Ein halb geschriebenes Ergebnis
    /// waere schlimmer als ein Lauf, der noch zu Ende geht.
    func cancelJob(_ jobID: JobID) async {
        guard let runtime else { return }
        do {
            try await runtime.coordinator.cancel(jobID: jobID)
        } catch PipelineError.cancellationTooLate {
            report(
                "The run is already saving its result and can no longer be cancelled.",
                isError: false
            )
        } catch {
            report(AppModel.message("The run could not be cancelled.", error))
        }
    }

    // MARK: - Meeting verwalten

    func deleteMeeting(_ meetingID: MeetingID) async {
        await deleteMeetings([meetingID])
    }

    func deleteMeetings(_ meetingIDs: [MeetingID]) async {
        guard let runtime else { return }
        var seen: Set<MeetingID> = []
        let targets = meetingIDs.filter { seen.insert($0).inserted }
        guard !targets.isEmpty else { return }

        let selectedMeetings = meetings.filter { targets.contains($0.id) }
        guard !isRecording,
              !isStartingRecording,
              !selectedMeetings.contains(where: { $0.status == .recording }) else {
            report(targets.count == 1
                ? "The meeting cannot be moved to the Trash while recording."
                : "Meetings cannot be moved to the Trash while recording.")
            return
        }
        guard beginMovingMeetingsToTrash() else { return }
        defer { finishMovingMeetingsToTrash() }

        let titles = Dictionary(uniqueKeysWithValues: meetings.map {
            ($0.id, $0.title)
        })
        var trashedItems: [UndoDeleteToastItem] = []
        var lastTrashError: Error?
        var lastCleanupError: Error?

        for meetingID in targets {
            do {
                let jobs = try await runtime.jobStore.list().filter {
                    $0.meetingID == meetingID
                }
                for job in jobs
                where job.status == .queued || job.status == .running {
                    try await runtime.coordinator.cancel(jobID: job.id)
                }
                let trashedURL = try await meetingTrasher(
                    runtime.library,
                    meetingID
                )
                trashedItems.append(UndoDeleteToastItem(
                    meetingID: meetingID,
                    title: titles[meetingID] ?? meetingID.description,
                    trashedURL: trashedURL
                ))
                do {
                    try await runtime.jobStore.removeJobs(meetingID: meetingID)
                } catch {
                    lastCleanupError = error
                }
            } catch {
                lastTrashError = error
            }
        }

        if !trashedItems.isEmpty {
            beginTrashUndoWindow(items: trashedItems)
            selectedMeetingIDs.subtract(Set(trashedItems.map(\.meetingID)))
            await refreshMeetings()
        }

        let failedCount = targets.count - trashedItems.count
        guard failedCount > 0 else {
            if let lastCleanupError {
                let summary = targets.count == 1
                    ? "The meeting was moved to the Trash, but its processing records could not be cleaned up."
                    : "The meetings were moved to the Trash, but some processing records could not be cleaned up."
                report(AppModel.message(summary, lastCleanupError))
            }
            return
        }
        var summary: String
        if targets.count == 1 {
            summary = "The meeting could not be moved to the Trash."
        } else if trashedItems.isEmpty {
            summary = "The meetings could not be moved to the Trash."
        } else {
            summary = "\(trashedItems.count) of \(targets.count) meetings were moved to the Trash. \(failedCount) could not be moved."
        }
        if lastCleanupError != nil {
            summary += " Some processing records for moved meetings could not be cleaned up."
        }
        if let error = lastTrashError ?? lastCleanupError {
            report(AppModel.message(summary, error))
        } else {
            report(summary)
        }
    }

    func renameMeeting(_ meetingID: MeetingID, to title: String) async {
        guard let runtime else { return }
        do {
            _ = try await runtime.library.renameMeeting(meetingID, to: title)
            await refreshMeetings()
        } catch LibraryError.invalidMeetingTitle {
            report("The title must not be empty.")
        } catch {
            report(AppModel.message("Renaming failed.", error))
        }
    }
}
