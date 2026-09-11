import Foundation
import StenoDomain
import StenoLibrary
import StenoPipeline

/// Benutzerkorrekturen am Transkript.
///
/// Eine Korrektur ueberschreibt nichts: sie haengt eine neue Revision an, die
/// auf ihren Vorgaenger zeigt. Was die Erkennung geliefert hat, bleibt lesbar -
/// und ein spaeterer Neulauf wirft die Korrektur nicht weg, sondern wartet.
@MainActor
extension AppModel {
    func shortRecordingDecision(for meetingID: MeetingID) async -> ShortRecordingDecision? {
        guard let runtime else { return nil }
        do {
            let result = try await ShortRecordingDecisionStore(layout: runtime.library.layout).pending(meetingID, jobStore: runtime.jobStore)
            shortRecordingReadFailures.remove(meetingID)
            return result
        }
        catch {
            if shortRecordingReadFailures.insert(meetingID).inserted {
                report("The saved recording decision could not be read.")
            }
            return nil
        }
    }

    func transcribeShortRecording(_ decision: ShortRecordingDecision) async -> Bool {
        guard let runtime, !isRecording, !isStartingRecording, !isMovingMeetingsToTrash else { return false }
        let store = ShortRecordingDecisionStore(layout: runtime.library.layout)
        do {
            guard try await store.pending(decision.job.meetingID, jobStore: runtime.jobStore)?.job.id == decision.job.id else { return false }
            let meeting = try await runtime.library.loadMeeting(decision.job.meetingID)
            guard meeting.processingGenerationID == decision.job.processingGenerationID else {
                try store.remove(meeting.id, expectedJobID: decision.job.id)
                report("The recording decision changed. Please reopen the meeting.")
                return false
            }
            guard meeting.status != .recording,
                  try store.load(meeting.id)?.job.id == decision.job.id,
                  !isRecording, !isStartingRecording, !isMovingMeetingsToTrash else { return false }
            _ = try await runtime.jobStore.ensureEnqueued(decision.job)
            try store.remove(meeting.id, expectedJobID: decision.job.id)
            noteJobEnqueued(for: meeting.id)
            return true
        } catch {
            report(verbatim: Self.message("Transcription could not be scheduled.", error))
            return false
        }
    }

    /// Speichert den korrigierten Text eines Turns.
    ///
    /// `revision` ist der Stand, den der Benutzer vor sich hatte. Passt er
    /// nicht mehr zum gespeicherten, lehnt die Bibliothek ab - und das ist
    /// richtig so: es hiesse, dass inzwischen ein Lauf durchgelaufen ist und
    /// die Korrektur auf einen Text zielt, der so nicht mehr dasteht.
    func saveTranscriptEdit(
        meetingID: MeetingID,
        revision: TranscriptRevision,
        turnIndex: Int,
        text: String
    ) async -> TranscriptRevision? {
        guard let runtime else { return nil }
        // Der Anhaengepfad richtet sich nach `revision.meetingID`. Passte das
        // Paar nicht zusammen, landete die Korrektur im gleich indizierten Turn
        // eines anderen Meetings - ohne dass irgendetwas fehlschlaegt.
        guard revision.meetingID == meetingID else {
            report("This correction did not belong to the open meeting and was not saved.")
            return nil
        }
        do {
            let edited = try TranscriptEdit.replacingText(
                in: revision,
                turnIndex: turnIndex,
                with: text
            )
            _ = try await runtime.library.appendRevision(edited)
            await demoDataMeetingContentDidChange(meetingID)
            return edited
        } catch TranscriptEdit.Failure.unchanged {
            // Kein Fehler und keine Meldung: nichts zu tun ist nichts zu tun.
            return nil
        } catch TranscriptEdit.Failure.turnOutOfRange {
            // Erreichbar, wenn der angezeigte Stand nicht mehr der gespeicherte
            // ist - etwa nach einem Lauf, der waehrend des Tippens fertig wurde.
            report("This line no longer exists. Reopen the meeting and try again.")
            return nil
        } catch TranscriptEdit.Failure.emptyText {
            report("A line cannot be emptied. Delete the meeting instead, or leave the text as it is.")
            return nil
        } catch LibraryError.invalidRevisionParent {
            report("This transcript changed while you were editing. Reopen the meeting and try again.")
            return nil
        } catch {
            report(verbatim: AppModel.message("The correction could not be saved.", error))
            return nil
        }
    }

    /// Der geparkte Neulauf, falls einer wartet.
    func pendingTranscript(for meetingID: MeetingID) async -> TranscriptRevision? {
        guard let runtime else { return nil }
        return try? await runtime.library.pendingRevision(meetingID: meetingID)
    }

    /// Nimmt den geparkten Neulauf als aktuellen Stand. Die eigene Korrektur
    /// bleibt als Revision erhalten, sie ist nur nicht mehr die angezeigte.
    @discardableResult
    func adoptPendingTranscript(for meetingID: MeetingID, expectedCurrentRevisionID: RevisionID, expectedCandidateID: RevisionID) async -> Bool {
        guard let runtime else { return false }
        do {
            guard try await runtime.library.adoptPendingRevision(
                meetingID: meetingID,
                expectedCurrentRevisionID: expectedCurrentRevisionID,
                expectedCandidateID: expectedCandidateID
            ) != nil else { return false }
            await demoDataMeetingContentDidChange(meetingID)
            report("Switched to the new transcription.", isError: false)
            return true
        } catch {
            report(verbatim: AppModel.message("The new transcription could not be taken over.", error))
            return false
        }
    }
}
