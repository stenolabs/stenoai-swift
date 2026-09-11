import AVFoundation
import Foundation
import StenoDomain
import StenoLibrary
import StenoPipeline

/// Personenverwaltung: alles, was der Einstellungen-Tab braucht.
///
/// Der Bereich ist die einzige Stelle, an der eine Person umbenannt, mit einer
/// anderen zusammengefuehrt oder geloescht werden kann - und die einzige, an
/// der eine falsche Stimmprobe oder ein falsches Hard Negative ueberhaupt
/// gefunden wird.
@MainActor
extension AppModel {
    /// Eine Person mit allem, was ueber ihre Stimme gespeichert ist.
    struct PersonEntry: Identifiable, Equatable {
        let person: Person
        let samples: [PersonVoiceSample]

        var id: PersonID { person.id }

        var prototypes: [PersonVoiceSample] {
            samples.filter { $0.kind == .prototype }
        }

        var hardNegatives: [PersonVoiceSample] {
            samples.filter { $0.kind == .hardNegative }
        }

        var activePrototypeCount: Int {
            prototypes.count { !$0.isExcluded }
        }

        var supersededPrototypeCount: Int {
            prototypes.count { $0.isSuperseded }
        }
    }

    func loadPeople() async -> [PersonEntry] {
        guard let runtime else { return [] }
        do {
            let store = try IdentityStore(layout: await runtime.library.layout)
            let persons = try await store.listPersons().sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
            var entries: [PersonEntry] = []
            for person in persons {
                entries.append(PersonEntry(
                    person: person,
                    samples: await PersonVoiceSamples.resolve(
                        library: runtime.library,
                        person: person
                    )
                ))
            }
            return entries
        } catch {
            peopleError = AppModel.message("People could not be loaded.", error)
            return []
        }
    }

    func renamePerson(_ personID: PersonID, to name: String) async -> Bool {
        await withStore("This person could not be renamed.") { store in
            _ = try await store.renamePerson(personID, to: name)
        }
    }

    /// Nimmt eine Stimmprobe von der Erkennung aus oder wieder auf. Die Probe
    /// bleibt gespeichert; das ist der ganze Punkt dieser Aktion.
    func setSampleExcluded(_ sample: PersonVoiceSample, excluded: Bool) async -> Bool {
        await withStore("This voice sample could not be updated.") { store in
            switch sample.kind {
            case .prototype:
                _ = try await store.setPrototypeExcluded(
                    sample.id,
                    of: sample.personID,
                    excluded: excluded
                )
            case .hardNegative:
                _ = try await store.setHardNegativeExcluded(
                    sample.id,
                    of: sample.personID,
                    excluded: excluded
                )
            }
        }
    }

    /// Loescht eine Person und gibt zurueck, was dafuer verschwunden ist.
    /// Nur mit diesem Schnappschuss ist die Ruecknahme verlustfrei.
    func deletePerson(_ personID: PersonID) async -> DeletedPerson? {
        guard let runtime else { return nil }
        stopSamplePlayback()
        do {
            let store = try IdentityStore(layout: await runtime.library.layout)
            guard let snapshot = try await store.deletePerson(personID) else {
                peopleError = "This person no longer exists."
                return nil
            }
            return snapshot
        } catch {
            peopleError = AppModel.message("This person could not be deleted.", error)
            return nil
        }
    }

    func restorePerson(_ snapshot: DeletedPerson) async -> Bool {
        await withStore("This person could not be restored.") { store in
            _ = try await store.restorePerson(snapshot)
        }
    }

    /// Fuehrt zwei Profile zusammen und zieht die Teilnehmerlisten nach.
    /// Anwesenheit ist meetingbezogen: wer in einem Meeting gesprochen hat,
    /// hat dort gesprochen, egal unter welchem der beiden Profile.
    func mergePerson(_ sourceID: PersonID, into targetID: PersonID) async -> Bool {
        guard let runtime else { return false }
        stopSamplePlayback()
        do {
            let store = try IdentityStore(layout: await runtime.library.layout)
            // Die Teilnehmerlisten liegen in je eigenen Dateien, das Profil in
            // einer weiteren: es gibt keine Transaktion darueber. Deshalb in
            // dieser Reihenfolge, damit ein Abbruch an keiner Stelle Anwesenheit
            // verliert - der schlimmste Zwischenstand ist eine Person, die
            // doppelt gefuehrt wird, und die zweite Kennung loest nach dem
            // Merge auf niemanden mehr auf und ist damit unsichtbar.
            try await addAlongside(sourceID, targetID)
            _ = try await store.mergePersons(sourceID, into: targetID)
            await dropMergedID(sourceID)
            await refreshMeetings()
            return true
        } catch {
            peopleError = AppModel.message("These people could not be merged.", error)
            return false
        }
    }

    /// Spielt genau den Ausschnitt, an dem die Probe haengt (Toggle). Ist die
    /// Probe nicht aufloesbar, gibt es hier gar keinen Knopf - geraten wird
    /// nichts.
    func togglePersonSample(_ sample: PersonVoiceSample) async {
        if playingPersonSampleID == sample.id {
            stopSamplePlayback()
            return
        }
        stopSamplePlayback()
        guard !isRecordingSoDoNotPlay else { return }
        guard let runtime, let playback = sample.playback else { return }
        do {
            let assets = try await runtime.library.listMediaAssets(
                meetingID: playback.meetingID
            )
            // Genau die Spur, die der Lauf diarisiert hat. Eine andere Spur
            // derselben Art waere nicht dieselbe Aufnahme, und die
            // Segmentzeiten wuerden dort auf eine fremde Stimme zeigen.
            guard let asset = assets.first(where: { $0.id == playback.assetID }) else {
                peopleError = "The original track for this sample is gone."
                return
            }
            let url = await runtime.library.layout.mediaFile(
                playback.meetingID,
                fileName: asset.fileName
            )
            let clipURL = try AppModel.extractClip(
                from: url,
                start: playback.start,
                duration: max(0.5, playback.duration)
            )
            let player = try TemporaryPlaybackFile.retainingOnSuccess(
                at: clipURL
            ) {
                try AVAudioPlayer(contentsOf: clipURL)
            }
            guard player.play() else {
                try? FileManager.default.removeItem(at: clipURL)
                peopleError = "Playback could not be started."
                return
            }
            samplePlayer = player
            sampleClipURL = clipURL
            setPlayingPersonSample(sample.id)
            samplePlaybackTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(player.duration + 0.2))
                guard !Task.isCancelled else { return }
                self?.stopSamplePlayback()
            }
        } catch {
            peopleError = AppModel.message("Playback failed.", error)
        }
    }

    private func withStore(
        _ summary: String.LocalizationValue,
        _ work: (IdentityStore) async throws -> Void
    ) async -> Bool {
        guard let runtime else { return false }
        do {
            try await work(IdentityStore(layout: await runtime.library.layout))
            return true
        } catch {
            peopleError = AppModel.message(summary, error)
            return false
        }
    }

    /// Schritt eins: Wo die Quelle steht, steht danach auch das Ziel. Rein
    /// additiv, damit ein Abbruch keine Anwesenheit kostet - "war in diesem
    /// Meeting" bleibt wahr, egal welches Profil es traegt.
    ///
    /// Schlaegt das fehl, wird der ganze Merge abgebrochen, bevor er die
    /// Profile anfasst.
    private func addAlongside(
        _ sourceID: PersonID,
        _ targetID: PersonID
    ) async throws {
        guard let runtime else { return }
        for meeting in try await runtime.library.listMeetings() {
            if meeting.participantIDs.contains(sourceID),
               !meeting.participantIDs.contains(targetID) {
                _ = try await runtime.library.updateMeetingParticipants(
                    meeting.id,
                    participantIDs: meeting.participantIDs + [targetID]
                )
            }
            if meeting.additionalParticipantIDs.contains(sourceID),
               !meeting.additionalParticipantIDs.contains(targetID) {
                _ = try await runtime.library.updateAdditionalMeetingParticipants(
                    meeting.id,
                    participantIDs: meeting.additionalParticipantIDs + [targetID]
                )
            }
        }
    }

    /// Schritt zwei: die aufgeloeste Kennung aus beiden Listen nehmen. Ab hier
    /// zeigt sie ohnehin auf niemanden mehr; ein Fehlschlag hinterlaesst
    /// deshalb keinen sichtbaren Schaden und wird nicht als Fehler gemeldet.
    ///
    /// Beide Listen werden geschrieben, sobald eine von beiden betroffen ist:
    /// steht die Zielperson als stille Teilnehmerin drin und die Quelle als
    /// Sprecherin, stuende sie sonst danach in beiden Listen.
    private func dropMergedID(_ sourceID: PersonID) async {
        guard let runtime else { return }
        let meetings = (try? await runtime.library.listMeetings()) ?? []
        for meeting in meetings {
            let speaking = meeting.participantIDs
            let silent = meeting.additionalParticipantIDs
            guard speaking.contains(sourceID) || silent.contains(sourceID) else {
                continue
            }
            _ = try? await runtime.library.updateMeetingParticipants(
                meeting.id,
                participantIDs: speaking.filter { $0 != sourceID }
            )
            // Die Bibliothek streicht hier von selbst jeden, der schon in der
            // Sprecherliste steht - deshalb muss dieser Aufruf auch dann
            // erfolgen, wenn die stille Liste die Quelle gar nicht enthaelt.
            _ = try? await runtime.library.updateAdditionalMeetingParticipants(
                meeting.id,
                participantIDs: silent.filter { $0 != sourceID }
            )
        }
    }
}
