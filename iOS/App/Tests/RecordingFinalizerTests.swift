import Foundation
import StenoDomain
import StenoLibrary
import StenoTranscription
import StenoiOSAudio
import Testing
@testable import Steno

@Suite("iOS recording finalization")
struct RecordingFinalizerTests {
    @Test("short recordings persist confirmation without a processing job", arguments: [3.0, 5.0, 10.0, 14.999, 15.0])
    func shortRecordingConfirmation(duration: TimeInterval) async throws {
        try await withFixture { library, store, meeting in
            try await RecordingFinalizer().finalize(
                meeting: meeting, output: nil, recordedDuration: duration,
                library: library, jobStore: store
            )
            let decision = try ShortRecordingDecisionStore(layout: library.layout).load(meeting.id)
            #expect((decision != nil) == (duration < 15))
            #expect(try await store.list().count == (duration < 15 ? 0 : 1))
            if let decision {
                #expect(decision.job.localeIdentifier == Job.finalASR(for: meeting).localeIdentifier)
                #expect(decision.job.processingGenerationID == meeting.processingGenerationID)
            }
        }
    }

    @Test("post-recording editor joins the recording notes session")
    @MainActor
    func postRecordingEditorJoinsRecordingSession() async throws {
        try await withMainActorFixture { library, _, meeting in
            let model = RecordingModel(session: AudioSessionController())
            let sessions = MeetingNotesSessionPool(
                store: MeetingNotesStore(layout: library.layout)
            )

            await model.prepareAnnotations(
                meetingID: meeting.id,
                sessions: sessions
            )
            model.updateNotes("Gemeinsamer Stand")
            let editorSession = try #require(await sessions.session(for: meeting.id))

            #expect(editorSession.text == "Gemeinsamer Stand")
            #expect(model.notes == editorSession.text)
        }
    }

    @Test("a short recording does not publish provisional live text before confirmation")
    func defersShortLiveOutput() async throws {
        try await withFixture { library, store, meeting in
            let output = TranscriptOutput(localeIdentifier: "de-DE", blocks: [
                TranscriptionBlock(channel: .microphone, text: "Synthetic live text",
                                   start: 0, end: 3, words: [])
            ])
            try await RecordingFinalizer().finalize(
                meeting: meeting, output: output, recordedDuration: 3,
                library: library, jobStore: store
            )
            #expect(!FileManager.default.fileExists(atPath: library.layout.currentRevision(meeting.id).path))
            #expect(try await store.list().isEmpty)
            #expect(try ShortRecordingDecisionStore(layout: library.layout).load(meeting.id) != nil)
        }
    }

    @Test("live output becomes one provisional revision and one final ASR job")
    func persistsLiveOutput() async throws {
        try await withFixture { library, store, meeting in
            let finalizer = RecordingFinalizer()
            let output = TranscriptOutput(
                localeIdentifier: "de-DE",
                blocks: [
                    TranscriptionBlock(
                        channel: .microphone,
                        text: "Hallo Welt",
                        start: 0,
                        end: 1,
                        words: [
                            TranscriptionWord(text: "Hallo", start: 0, end: 0.4),
                            TranscriptionWord(text: "Welt", start: 0.5, end: 1),
                        ]
                    ),
                ]
            )

            try await finalizer.finalize(
                meeting: meeting,
                output: output,
                library: library,
                jobStore: store
            )

            let revision = try #require(
                try await library.loadCurrentRevision(meetingID: meeting.id)
            )
            let jobs = try await store.list()
            #expect(revision.origin == .liveProvisional)
            #expect(revision.turns.flatMap(\.segments).map(\.text) == ["Hallo Welt"])
            #expect(jobs.count == 1)
            #expect(jobs.first?.kind == .finalASR)
            #expect(jobs.first?.meetingID == meeting.id)
        }
    }

    @Test("missing live output still queues exactly one final ASR job")
    func missingOutputStillQueuesFinal() async throws {
        try await withFixture { library, store, meeting in
            let finalizer = RecordingFinalizer()

            try await finalizer.finalize(
                meeting: meeting,
                output: nil,
                library: library,
                jobStore: store
            )

            let revision = try? await library.loadCurrentRevision(meetingID: meeting.id)
            #expect(revision == nil)
            #expect(try await store.list().count == 1)
        }
    }

    @Test("recording model persists only an explicitly chosen source locale")
    @MainActor
    func recordingModelPersistsExplicitSourceLocale() async throws {
        try await withMainActorFixture { library, _, _ in
            let model = RecordingModel(session: AudioSessionController())

            let explicit = try await model.createRecordingMeeting(
                in: library,
                locale: Locale(identifier: "de-DE"),
                languageWasChosenExplicitly: true
            )
            let equivalentSelection = TranscriptionLanguageSelection(
                selectedIdentifier: "de-DE",
                wasChosenExplicitly: true,
                resolvedFallback: Locale(identifier: "de_DE")
            )
            let equivalent = try await model.createRecordingMeeting(
                in: library,
                locale: equivalentSelection.locale,
                languageWasChosenExplicitly: equivalentSelection
                    .effectiveLocaleWasChosenExplicitly
            )
            let differentFallbackSelection = TranscriptionLanguageSelection(
                selectedIdentifier: "de-DE",
                wasChosenExplicitly: true,
                resolvedFallback: Locale(identifier: "de_AT")
            )
            let derived = try await model.createRecordingMeeting(
                in: library,
                locale: differentFallbackSelection.locale,
                languageWasChosenExplicitly: differentFallbackSelection
                    .effectiveLocaleWasChosenExplicitly
            )

            #expect(try await library.loadMeeting(explicit.id).sourceLocale
                == MeetingSourceLocale(localeIdentifier: "de-DE", origin: .explicit))
            #expect(try await library.loadMeeting(equivalent.id).sourceLocale
                == MeetingSourceLocale(localeIdentifier: "de_DE", origin: .explicit))
            #expect(try await library.loadMeeting(derived.id).sourceLocale == nil)
        }
    }

    @Test("recording model pins the chosen transcription plan on the meeting")
    @MainActor
    func recordingModelPinsTranscriptionPlan() async throws {
        try await withMainActorFixture { library, _, _ in
            let model = RecordingModel(session: AudioSessionController())
            let plan = TranscriptionPlan(
                liveProviderID: .apple,
                finalProviderID: .parakeetTDTv3
            )

            let meeting = try await model.createRecordingMeeting(
                in: library,
                locale: Locale(identifier: "de-DE"),
                languageWasChosenExplicitly: true,
                transcriptionPlan: plan
            )
            let persisted = try await library.loadMeeting(meeting.id)

            #expect(persisted.transcriptionPlan == plan)
            // Die Job-Erstellung liest den gepinnten Plan wieder aus - ohne
            // eigenes Zutun waere die Wahl in den Einstellungen wirkungslos.
            #expect(Job.finalASR(for: persisted).transcriptionProviderID == .parakeetTDTv3)
        }
    }

    @Test("concurrent and later duplicate calls persist nothing twice")
    func duplicateCallsAreIdempotent() async throws {
        try await withFixture { library, store, meeting in
            let finalizer = RecordingFinalizer()
            let output = TranscriptOutput(localeIdentifier: "de-DE", blocks: [])

            async let first: Void = finalizer.finalize(
                meeting: meeting,
                output: output,
                library: library,
                jobStore: store
            )
            async let second: Void = finalizer.finalize(
                meeting: meeting,
                output: output,
                library: library,
                jobStore: store
            )
            _ = try await (first, second)
            try await finalizer.finalize(
                meeting: meeting,
                output: output,
                library: library,
                jobStore: store
            )

            #expect(try await store.list().count == 1)
        }
    }

    @Test("recording annotations survive finalization")
    @MainActor
    func recordingAnnotationsSurviveFinalization() async throws {
        try await withMainActorFixture { library, store, meeting in
            let model = RecordingModel(session: AudioSessionController())
            let notesStore = MeetingNotesStore(layout: library.layout)
            await model.prepareAnnotations(meetingID: meeting.id, store: notesStore)
            model.updateNotes("Budgetfreigabe")
            await model.appendMarker(elapsed: 65)
            await model.finishAnnotations()

            try await RecordingFinalizer().finalize(
                meeting: meeting,
                output: nil,
                library: library,
                jobStore: store
            )

            let reopened = MeetingNotesStore(layout: library.layout)
            #expect(try await reopened.notes(meeting.id) == "Budgetfreigabe\n[00:01:05] ")
            #expect(try await store.list().count == 1)
        }
    }

    @Test("an annotation failure does not prevent final ASR")
    @MainActor
    func annotationFailureDoesNotPreventFinalASR() async throws {
        try await withMainActorFixture { library, store, meeting in
            let model = RecordingModel(session: AudioSessionController())
            await model.prepareAnnotations(
                meetingID: meeting.id,
                store: FailingNotesPersistence()
            )
            model.updateNotes("Ungespeichert, aber sichtbar")
            await model.appendMarker(elapsed: 4)
            await model.finishAnnotations()

            try await RecordingFinalizer().finalize(
                meeting: meeting,
                output: nil,
                library: library,
                jobStore: store
            )

            #expect(model.annotationFailure != nil)
            #expect(model.notes == "Ungespeichert, aber sichtbar\n[00:00:04] ")
            #expect(try await store.list().count == 1)
        }
    }
}

private enum AnnotationWriteFailure: Error {
    case refused
}

private actor FailingNotesPersistence: MeetingNotesPersistence {
    func notes(_ meetingID: MeetingID) async throws -> String? {
        nil
    }

    func setNotes(_ meetingID: MeetingID, to notes: String?) async throws {
        throw AnnotationWriteFailure.refused
    }
}

private func withFixture(
    _ body: (Library, JobStore, Meeting) async throws -> Void
) async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("StenoTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try Library.open(at: root)
    let meeting = try await library.createMeeting(title: "Meeting", status: .ready)
    let store = try JobStore(layout: library.layout)
    try await body(library, store, meeting)
}

@MainActor
private func withMainActorFixture(
    _ body: (Library, JobStore, Meeting) async throws -> Void
) async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("StenoAnnotationTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try Library.open(at: root)
    let meeting = try await library.createMeeting(title: "Meeting", status: .ready)
    let store = try JobStore(layout: library.layout)
    try await body(library, store, meeting)
}
