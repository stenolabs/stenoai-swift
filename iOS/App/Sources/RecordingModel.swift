import Foundation
import StenoAudioCore
import StenoDomain
import StenoLibrary
import StenoPipeline
import StenoTranscription
import StenoiOSAudio

struct RecordingInterruptionLatch {
    enum Action: Equatable {
        case ignore
        case deferUntilStarted
        case stop(String)
    }

    private var pendingReason: String?

    mutating func receive(
        _ reason: String,
        while state: RecordingModel.State
    ) -> Action {
        switch state {
        case .preparing:
            if pendingReason == nil {
                pendingReason = reason
            }
            return .deferUntilStarted
        case .recording:
            return .stop(reason)
        case .idle, .interrupted, .failed:
            return .ignore
        }
    }

    mutating func takePendingReason() -> String? {
        defer { pendingReason = nil }
        return pendingReason
    }

    mutating func reset() {
        pendingReason = nil
    }
}

/// State of a running recording.
///
/// Since approval F2 this writes through the shared `RecordingSession` from
/// `StenoAudioCore`, the same one the Mac uses. That is the point of the
/// split: the track writer, the disk-space guard and the crash recovery are
/// the parts that make a recording trustworthy, and having a second iOS
/// implementation of them would mean two chances to get them subtly wrong.
@MainActor
@Observable
final class RecordingModel {
    enum State: Equatable {
        case idle
        case preparing
        case recording
        /// The system took the session away, most often an incoming call.
        case interrupted(reason: String, at: TimeInterval)
        case failed(String)
    }

    private(set) var state: State = .idle
    /// Laeuft ein Stop, teilen sich alle weiteren Aufrufer diesen Task.
    private var stopTask: Task<Void, Never>?
    /// Fehler beim Schliessen der Spur, von `tearDown` gesetzt.
    private var stopFailure: String?
    private(set) var level: AudioLevel = .silence
    private(set) var elapsed: TimeInterval = 0
    private(set) var silentSeconds: TimeInterval = 0
    private(set) var isSilenceAlarming = false
    private(set) var microphonePermission: RecordPermissionStatus

    /// Projects the cumulative snapshots into newest-first rows. The volatile
    /// row stays marked as such, so nobody quotes a guess.
    private var liveTranscriptFeed = LiveTranscriptFeed()
    private(set) var liveTranscriptRows: [LiveTranscriptFeed.Row] = []

    /// Why there is no live transcript, when the audio is fine.
    ///
    /// Transcription is the extra, audio is the point. A device without the
    /// speech model, or without the network to fetch it, must still record;
    /// otherwise the one irreplaceable artefact is lost over a convenience.
    private(set) var transcriptionFailure: String?

    /// The meeting being recorded into, so the rest of the app can follow it.
    private(set) var meetingID: MeetingID?

    /// Set when the session ended itself rather than being asked to.
    ///
    /// Replaces the old dropped-buffer counter: the shared session does not
    /// quietly discard audio, it stops and says why. A recording that ended
    /// for lack of disk space must not look like one the user ended.
    private(set) var involuntaryStop: RecordingStopReason?

    /// Timestamps the user marked as important. One tap, no text: the common
    /// impulse is "that mattered", not "I want to write something".
    private(set) var markers: [TimeInterval] = []

    /// Free-form notes. The note carries the why, the transcript only the what.
    var notes: String { notesSession?.text ?? "" }
    var isSavingAnnotations: Bool { notesSession?.isSaving ?? false }
    var annotationFailure: String? { notesSession?.errorMessage }
    var canEditAnnotations: Bool { notesSession != nil }

    private let audioSession: AudioSessionController
    private var stoppedRecordingDuration: TimeInterval?
    private let finalizer: RecordingFinalizer
    private let microphonePermissionStatus: @MainActor () -> RecordPermissionStatus
    private let microphonePermissionRequest: @MainActor () async -> RecordPermissionStatus
    /// Als Quelle statt als Wert: der Nutzer kann den Live-Adapter in den
    /// Einstellungen freischalten, und das soll beim naechsten Aufnahmestart
    /// wirken, nicht erst beim naechsten App-Start.
    private let transcriptionRegistrySource: @MainActor () -> TranscriptionProviderRegistry
    private var runtime: PipelineRuntime?
    private var notesSessions: MeetingNotesSessionPool?
    private var session: RecordingSession?
    private var micSource: MicrophoneCapture?
    private var audioSessionLease: AudioSessionController.RecordingLease?
    private var notesSession: MeetingNotesEditingSession?
    private var startedAt: Date?
    private var silence = SilenceMonitor()
    private var interruptionLatch = RecordingInterruptionLatch()
    var didBecomeIdle: (@MainActor @Sendable () -> Void)?

    private var liveTask: Task<TranscriptOutput?, Never>?
    private var tickTask: Task<Void, Never>?
    private var sessionEventTask: Task<Void, Never>?

    init(
        session: AudioSessionController,
        finalizer: RecordingFinalizer = RecordingFinalizer(),
        transcriptionRegistry: @escaping @MainActor () -> TranscriptionProviderRegistry = { .appleOnly },
        microphonePermissionStatus: @escaping @MainActor () -> RecordPermissionStatus = {
            RecordPermission.status()
        },
        microphonePermissionRequest: @escaping @MainActor () async -> RecordPermissionStatus = {
            await RecordPermission.request()
        }
    ) {
        audioSession = session
        self.finalizer = finalizer
        transcriptionRegistrySource = transcriptionRegistry
        self.microphonePermissionStatus = microphonePermissionStatus
        self.microphonePermissionRequest = microphonePermissionRequest
        microphonePermission = microphonePermissionStatus()
    }

    /// Handed over once the library is open. Without it there is nowhere to
    /// write, and the record button stays inert rather than pretending.
    func attach(
        runtime: PipelineRuntime,
        notesSessions: MeetingNotesSessionPool
    ) {
        self.runtime = runtime
        self.notesSessions = notesSessions
    }

    /// Removes recording access to a pipeline that is about to be replaced.
    ///
    /// This must stay synchronous on the main actor: after the active-state
    /// check no other task may start a recording before the old runtime is
    /// detached. A running or preparing recording keeps its runtime until its
    /// normal stop path has preserved the original audio.
    @discardableResult
    func detachRuntimeIfIdle() -> Bool {
        guard !isActive else { return false }
        runtime = nil
        return true
    }

    var canRecord: Bool { runtime != nil }

    var isActive: Bool {
        switch state {
        case .recording, .preparing: true
        case .idle, .interrupted, .failed: false
        }
    }

    // MARK: - Lifecycle

    /// Starts capture, then attaches transcription to it.
    ///
    /// The order is the point, and it follows the Mac
    /// (`steno-macos/App/Sources/AppModel.swift:305-355`): the recogniser
    /// lives in its own task, so an unavailable model, a missing download or
    /// an unsupported language costs the transcript and nothing else. Only a
    /// failure of the audio path itself fails the run.
    func start(
        locale: Locale,
        languageWasChosenExplicitly: Bool,
        plan: TranscriptionPlan = TranscriptionPlan(
            liveProviderID: .apple,
            finalProviderID: .apple
        )
    ) async {
        guard !isActive, let runtime, let notesSessions else { return }
        state = .preparing
        interruptionLatch.reset()

        // Die Freigabe gehoert in den Aufnahmeweg, nicht nur ins
        // Diagnosefenster. Der Aufnahmeknopf ist der erste Weg, den eine
        // frische Installation nimmt; ohne diese Pruefung legte er ein
        // Meeting an und scheiterte erst danach, oder schrieb eine Spur
        // ohne nutzbares Eingangssignal. `configure()` und `activate()`
        // ersetzen sie nicht: eine Sitzung laesst sich auch ohne erteilte
        // Freigabe aufsetzen.
        var permission = microphonePermissionStatus()
        microphonePermission = permission
        if permission == .notDetermined {
            permission = await microphonePermissionRequest()
            microphonePermission = permission
        }
        guard permission == .authorized else {
            state = .failed(Self.microphoneDeniedMessage)
            return
        }
        liveTranscriptFeed = LiveTranscriptFeed()
        liveTranscriptRows = []
        transcriptionFailure = nil
        involuntaryStop = nil
        markers = []
        notesSession = nil
        elapsed = 0

        do {
            let sessionEvents = await audioSession.events()
            observeSessionEvents(sessionEvents)
            audioSessionLease = try await audioSession.beginRecording()

            let meeting = try await createRecordingMeeting(
                in: runtime.library,
                locale: locale,
                languageWasChosenExplicitly: languageWasChosenExplicitly,
                transcriptionPlan: plan
            )
            // Capture directory inside the meeting folder, exactly as on the
            // Mac: after a crash the tracks sit in the library and are adopted
            // on the next launch instead of stranding in a temp directory.
            let captureDirectory = await runtime.library.layout
                .captureDirectory(meeting.id)

            let source = MicrophoneCapture()
            let session = RecordingSession(
                meetingID: meeting.id,
                library: runtime.library,
                outputDirectory: captureDirectory,
                // One track. There is no system audio on iOS, so every voice
                // in the room lands on the microphone and telling them apart
                // is the diarisation's job.
                sources: [.microphone: source],
                activityManager: ScreenAwakeManager()
            )
            try await session.start()

            self.session = session
            micSource = source
            meetingID = meeting.id

            let stream = try await session.liveAudioEvents(for: .microphone)
            do {
                let provider = try transcriptionRegistrySource().resolve(
                    plan.liveProviderID,
                    for: .micTrack
                )
                startTranscribing(from: stream, provider: provider, locale: locale)
            } catch {
                noteTranscriptionFailure(error)
            }

            let now = Date()
            startedAt = now
            silence = SilenceMonitor()
            silence.begin(at: now)
            startTicking()
            state = .recording
            if let pendingReason = interruptionLatch.takePendingReason() {
                await stopForInterruption(pendingReason)
                return
            }
            await prepareAnnotations(
                meetingID: meeting.id,
                sessions: notesSessions
            )
        } catch {
            state = .failed(error.localizedDescription)
            await tearDown()
            didBecomeIdle?()
        }
    }

    /// Reads the system value only. Returning from Settings must never
    /// reconfigure or deactivate an audio session that is recording.
    func refreshMicrophonePermission() {
        microphonePermission = microphonePermissionStatus()
        if microphonePermission == .authorized,
           state == .failed(Self.microphoneDeniedMessage)
        {
            state = .idle
        }
    }

    /// Creates the durable meeting record before capture starts.
    ///
    /// The effective recognizer locale is persisted only when it came from an
    /// explicit app language choice. A derived fallback remains useful for the
    /// live recognizer, but must not become a claimed user choice in exports.
    func createRecordingMeeting(
        in library: Library,
        locale: Locale,
        languageWasChosenExplicitly: Bool,
        transcriptionPlan: TranscriptionPlan = TranscriptionPlan(
            liveProviderID: .apple,
            finalProviderID: .apple
        )
    ) async throws -> Meeting {
        let sourceLocale: MeetingSourceLocale? = if languageWasChosenExplicitly {
            try MeetingSourceLocale(
                localeIdentifier: locale.identifier,
                origin: .explicit
            )
        } else {
            nil
        }
        return try await library.createMeeting(
            title: Self.defaultTitle(),
            status: .recording,
            sourceLocale: sourceLocale,
            transcriptionPlan: transcriptionPlan
        )
    }

    /// Stops, then saves what the live run understood.
    ///
    /// The provisional revision is marked `.liveProvisional` and a final ASR
    /// job is queued, same as the Mac: the live text is a catch-up aid and
    /// gets corrected by the proper run, but losing it entirely because the
    /// proper run has not happened yet would be worse.
    func stop() async {
        // Ein gemeinsamer Task statt eines Zustands: der Hauptaktor gibt an
        // jedem `await` ab, und es gibt jetzt zwei Aufrufer - den Knopf und
        // die Erkennung einer selbsttaetig beendeten Sitzung. Ohne das
        // haengten zwei Laeufe dieselbe Live-Ausgabe als eigene Revision an
        // und reihten je einen Final-ASR-Job ein. Der Zweite wartet hier auf
        // den Ersten und ist danach fertig.
        if let stopTask {
            await stopTask.value
            return
        }
        let task = Task { await performStop() }
        stopTask = task
        await task.value
        // Nur den eigenen, aus demselben Grund wie beim Sprachwechsel.
        if stopTask == task { stopTask = nil }
    }

    private func performStop() async {
        let recordedMeeting = meetingID
        stopFailure = nil
        let output = await tearDown()
        await finishAnnotations()
        if let stopFailure {
            state = .failed(stopFailure)
        }

        if let runtime, let recordedMeeting {
            do {
                if stopFailure != nil {
                    _ = try await runtime.library.updateMeetingStatus(recordedMeeting, to: .interrupted)
                    let recovery = try await CaptureRecovery.run(
                        library: runtime.library, jobStore: runtime.jobStore,
                        onlyMeetingID: recordedMeeting, scheduleJobs: false
                    )
                    if let failure = recovery.failures.first(where: { !($0.error is CaptureRecovery.AdoptionRefusal) }) {
                        throw failure.error
                    }
                }
                let meeting = try await runtime.library.loadMeeting(recordedMeeting)
                try await finalizer.finalize(
                    meeting: meeting,
                    output: output,
                    recordedDuration: stopFailure == nil && involuntaryStop == nil ? stoppedRecordingDuration : nil,
                    library: runtime.library,
                    jobStore: runtime.jobStore
                )
                try CaptureRecovery.completeFinalization(layout: runtime.library.layout, meetingID: recordedMeeting)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }

        if case .failed = state {} else { state = .idle }
        elapsed = 0
        startedAt = nil
        didBecomeIdle?()
    }

    /// Marks the current moment. One tap, and it must work while recording.
    func mark() async {
        guard case .recording = state, let startedAt else { return }
        await appendMarker(elapsed: Date().timeIntervalSince(startedAt))
    }

    func prepareAnnotations(
        meetingID: MeetingID,
        store: any MeetingNotesPersistence
    ) async {
        await prepareAnnotations(
            meetingID: meetingID,
            sessions: MeetingNotesSessionPool(store: store)
        )
    }

    func prepareAnnotations(
        meetingID: MeetingID,
        sessions: MeetingNotesSessionPool
    ) async {
        notesSession = await sessions.session(for: meetingID)
    }

    func updateNotes(_ value: String) {
        notesSession?.update(value)
    }

    func appendMarker(elapsed: TimeInterval) async {
        guard let notesSession else { return }
        markers.append(elapsed)
        await notesSession.appendMarker(elapsed: elapsed)
    }

    func finishAnnotations() async {
        await notesSession?.flush()
    }

    // MARK: - Transcription

    private func startTranscribing(
        from stream: LiveAudioEventStream,
        provider: any TranscriptionProvider,
        locale: Locale
    ) {
        // No progress handler any more: since the onboarding work the provider
        // does not install models, `ModelInstallationCoordinator` does, with
        // explicit consent and checksums. A missing model now arrives as a
        // transcription failure, which this screen already reports correctly
        // while the recording keeps running.

        // Detached, as on the Mac: a plain `Task` would inherit this model's
        // MainActor isolation and push every audio buffer through the main
        // thread, several times a second for the length of a meeting.
        liveTask = Task.detached { [weak self] in
            var live: (any LiveTranscriptionSession)?
            var eventTask: Task<Void, Never>?
            var unavailable = false
            var segmentOffset: TimeInterval = 0
            var outputs: [TranscriptOutput] = []

            for await audioEvent in stream.stream {
                switch audioEvent {
                case let .buffer(owned):
                    let buffer = owned.buffer
                    if live == nil, !unavailable {
                        do {
                            let created = try await provider.liveSession(
                                format: AudioFormat(buffer.format),
                                locale: locale
                            )
                            let offset = segmentOffset
                            live = created
                            eventTask = Task { [weak self] in
                                for await event in created.events {
                                    await self?.applyLiveEvent(event.shifted(by: offset))
                                }
                            }
                        } catch {
                            unavailable = true
                            await self?.noteTranscriptionFailure(error)
                        }
                    }
                    guard let live else { continue }
                    guard let buffer = try? AudioBuffer(copying: buffer) else { continue }
                    await live.append(buffer)
                case .gapStarted:
                    if let live, let output = try? await live.finish() {
                        await eventTask?.value
                        outputs.append(output.shifted(by: segmentOffset))
                    } else {
                        eventTask?.cancel()
                    }
                    live = nil
                    eventTask = nil
                    await self?.clearVolatileTranscript()
                case let .gapEnded(at):
                    segmentOffset = at
                }
            }

            if let live, let output = try? await live.finish() {
                await eventTask?.value
                outputs.append(output.shifted(by: segmentOffset))
            } else {
                eventTask?.cancel()
            }
            guard !outputs.isEmpty else { return nil }
            return TranscriptOutput(
                localeIdentifier: outputs[0].localeIdentifier,
                blocks: outputs.flatMap(\.blocks).sorted { $0.start < $1.start }
            )
        }
    }

    private func clearVolatileTranscript() {
        liveTranscriptFeed.clearVolatile(for: .microphone)
        liveTranscriptRows = liveTranscriptFeed.rows
    }

    private func noteTranscriptionFailure(_ error: Error) {
        transcriptionFailure = error.localizedDescription
    }

    func applyLiveEvent(_ event: TranscriptionEvent) {
        liveTranscriptFeed.apply(event, for: .microphone)
        liveTranscriptRows = liveTranscriptFeed.rows
    }

    // MARK: - Internals

    /// Stops everything and returns whatever the live run produced.
    @discardableResult
    private func tearDown() async -> TranscriptOutput? {
        tickTask?.cancel()
        tickTask = nil
        sessionEventTask?.cancel()
        sessionEventTask = nil

        // Stopping the session closes the live stream, which ends the
        // transcription task by itself. Cancelling it instead would throw away
        // the final text it is in the middle of producing.
        //
        // Scheitert das Schliessen, Registrieren oder Fortschreiben des
        // Meetings, muss der Fehler sichtbar werden: dann gibt es keine
        // registrierte Originalspur, der Final-ASR-Lauf scheitert spaeter -
        // und mit einem verschluckten Fehler saehe die Aufnahme genau so
        // aus, als waere sie gelungen.
        stoppedRecordingDuration = nil
        do {
            if let result = try await session?.stop() {
                if result.stopReason != .requested {
                    involuntaryStop = result.stopReason
                } else {
                    stoppedRecordingDuration = result.assets.values.compactMap(\.duration).max()
                }
            }
        } catch {
            // Nicht hier melden: `start()` raeumt ueber denselben Weg ab und
            // haette dann seine aussagekraeftigere Meldung ueberschrieben.
            // `performStop` entscheidet, was der Nutzer liest.
            stopFailure = error.localizedDescription
        }
        session = nil
        micSource = nil
        interruptionLatch.reset()

        let output = await liveTask?.value
        liveTask = nil

        if let audioSessionLease {
            self.audioSessionLease = nil
            try? await audioSession.endRecording(audioSessionLease)
        }
        level = .silence
        liveTranscriptFeed.clearVolatile(for: .microphone)
        liveTranscriptRows = liveTranscriptFeed.rows
        silence.stop()
        silentSeconds = 0
        isSilenceAlarming = false
        return output
    }

    private func startTicking() {
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                await self?.tick()
            }
        }
    }

    private func tick() async {
        let now = Date()
        // Zuerst der Endzustand, dann erst Pegel und Zeit. Die Sitzung
        // beendet sich selbst, wenn der Platz knapp wird, ein Writer
        // scheitert oder der Ringpuffer ueberlaeuft. Ohne diese Pruefung
        // liefen roter Punkt und Laufzeit weiter, und der Nutzer hielt die
        // folgenden Minuten fuer aufgenommen - der Fehler faellt erst beim
        // Abhoeren auf, wenn die Besprechung vorbei ist.
        if let session, await session.state.isTerminal {
            await finishAfterSelfStop()
            return
        }
        if let micSource, !(await micSource.running) {
            await handleInterruption(
                String(localized: "the microphone could not restart after its audio configuration changed")
            )
            return
        }
        if let startedAt {
            elapsed = now.timeIntervalSince(startedAt)
        }
        // The level comes from the session rather than a second tap: two taps
        // on one input node is how you get a silent recording.
        if let session {
            level = AudioLevel(await session.levels(for: .microphone))
            silence.update(level, at: now)
        }
        silentSeconds = silence.silentSeconds(at: now) ?? 0
        isSilenceAlarming = silence.isAlarming(at: now)
    }

    /// Die Sitzung hat von sich aus aufgehoert. Denselben Weg nehmen wie ein
    /// gewollter Stop, damit das bereits Aufgenommene und das Live-Transkript
    /// erhalten bleiben - nur ohne den Knopf.
    ///
    /// `stop()` setzt `involuntaryStop` aus dem `stopReason` der Sitzung, die
    /// Oberflaeche zeigt den Grund also von selbst.
    private func finishAfterSelfStop() async {
        guard isActive else { return }
        await stop()
    }

    /// An interruption ends the run rather than pretending to continue.
    ///
    /// The session is gone at this point; carrying on would produce a
    /// recording with a hole in it that nothing later can detect. What is
    /// already written stays written, which is why the message says so.
    private func observeSessionEvents(_ stream: AsyncStream<AudioSessionEvent>) {
        sessionEventTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event {
                case .interruptionBegan(let reason):
                    await self.handleInterruption(describing(reason))
                case .routeChanged(let reason) where reason.endsCurrentCapture:
                    await self.handleInterruption(String(localized: "input device changed"))
                case .mediaServicesWereReset:
                    await self.handleInterruption(String(localized: "audio services restarted"))
                case .routeChanged, .interruptionEnded:
                    continue
                }
            }
        }
    }

    private func handleInterruption(_ reason: String) async {
        switch interruptionLatch.receive(reason, while: state) {
        case .ignore, .deferUntilStarted:
            return
        case .stop(let reason):
            await stopForInterruption(reason)
        }
    }

    private func stopForInterruption(_ reason: String) async {
        let at = elapsed
        await stop()
        // Nur wenn der Stop durchkam. Scheiterte das Schliessen oder
        // Registrieren der Spur, hat `performStop` den Grund gesetzt, und
        // "Audio bis \(at) ist intakt" waere dann eine Zusicherung, fuer
        // die es womoeglich gar keine registrierte Originalspur gibt.
        if case .failed = state { return }
        state = .interrupted(reason: reason, at: at)
    }

    /// Sagt, was zu tun ist. "Zugriff verweigert" allein laesst den Nutzer
    /// auf dem Aufnahmebildschirm stehen, ohne den Ort zu kennen, an dem er
    /// es aendern kann.
    static let microphoneDeniedMessage = String(localized: "Steno may not use the microphone. Allow it in Settings under Privacy and Security, then Microphone.")

    private static func defaultTitle() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return String(localized: "Recording \(formatter.string(from: Date()))")
    }
}

private func describing(_ reason: AudioInterruptionReason) -> String {
    switch reason {
    case .builtInMicMuted: String(localized: "the microphone was muted")
    case .other: String(localized: "another app or a call took the microphone")
    }
}

/// Formats a duration as hh:mm:ss for a glance of under three seconds.
func durationText(_ interval: TimeInterval) -> String {
    let total = Int(interval)
    return String(
        format: "%02d:%02d:%02d",
        total / 3600,
        (total % 3600) / 60,
        total % 60
    )
}
