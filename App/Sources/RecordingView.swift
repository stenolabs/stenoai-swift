import StenoAudioCore
import StenoDomain
import StenoMacAudio
import SwiftUI

struct RecordingTrackPresentation: Equatable {
    let actionTitle: LocalizedStringResource?
    let actionIcon: String?
    let warning: LocalizedStringResource?
    let isPaused: Bool

    init(status: RecordingTrackStatus?) {
        let status = status ?? RecordingTrackStatus()
        let name = status.deviceName ?? String(localized: "Microphone")
        if !status.deviceAvailable {
            actionTitle = nil
            actionIcon = nil
            warning = "\(name) disconnected. The microphone track is paused; system audio continues."
            isPaused = true
        } else if status.sourceStalled {
            actionTitle = nil
            actionIcon = nil
            warning = "\(name) is not responding. The microphone track is paused; system audio continues."
            isPaused = true
        } else if status.userPaused {
            actionTitle = "Resume microphone"
            actionIcon = "play.circle"
            warning = "Microphone paused. System audio continues."
            isPaused = true
        } else {
            actionTitle = "Pause microphone"
            actionIcon = "pause.circle"
            warning = nil
            isPaused = false
        }
    }
}

struct RecordingView: View {
    @Environment(AppModel.self) private var model
    /// Mitschreiben ist der Hauptfall, also steht das Feld von selbst offen.
    /// Die Entscheidung des Benutzers ueberlebt aber den Neustart: Wer es
    /// zuklappt, schreibt nicht mit und soll nicht jedesmal neu zuklappen.
    @AppStorage("steno.recording.notesOpen") private var showNotes = true
    /// Ask bar visibility. The orchestrator wires Cmd+Shift+A to the same
    /// AppStorage key; like the notes inspector, the choice survives restart.
    @AppStorage(AskBarView.visibilityDefaultsKey) private var isAskBarVisible = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
        }
        // Mitschreiben waehrend der Aufnahme ist der Hauptfall fuer Notizen,
        // nicht die Ausnahme.
        .frame(minWidth: 560)
        .preference(key: MainDetailMinimumWidthKey.self, value: showNotes ? 560 + 260 + 1 : 560)
        .inspector(isPresented: $showNotes) {
            Group {
                if let meetingID = model.recordingMeetingID {
                    ScrollView {
                        NotesSection(meetingID: meetingID)
                            .padding(Steno.Space.l)
                    }
                }
            }
            .inspectorColumnWidth(min: 260, ideal: 320, max: 420)
        }
        // The ask bar floats above the transcript, near the bottom edge -
        // parity with the predecessor's floating bar above the dock band.
        .overlay(alignment: .bottom) {
            AskBarView(isVisible: $isAskBarVisible)
        }
        .toolbar(id: MacToolbarID.recording.rawValue) {
            ToolbarItem(
                id: MacToolbarItemID.recordingNotes.rawValue,
                placement: .primaryAction
            ) {
                Toggle(isOn: $showNotes) {
                    Label("Notes", systemImage: "square.and.pencil")
                }
                .help("Take notes while recording")
            }
            .defaultCustomization(
                MacToolbarPresentation.defaultCustomization(
                    for: .recordingNotes,
                    in: .recording
                )
            )
        }
    }

    private var header: some View {
        let microphone = RecordingTrackPresentation(
            status: model.microphoneStatus
        )
        return VStack(alignment: .leading, spacing: 10) {
            // Timer and levels live in the persistent recording strip.
            if let title = microphone.actionTitle,
               let icon = microphone.actionIcon {
                Button {
                    Task {
                        await model.setMicrophonePaused(!microphone.isPaused)
                    }
                } label: {
                    Label(title, systemImage: icon)
                }
                .buttonStyle(.borderless)
                .help(title)
            }
            if let warning = microphone.warning {
                Label(warning, systemImage: "mic.slash")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if !model.transcriptionLanguageSelection
                .effectiveLocaleWasChosenExplicitly,
               !model.availableLocales.isEmpty {
                Label(
                    "Transcription language is guessed as \(model.selectedTranscriptionLanguageName). Confirm it in Settings before you rely on a transcript.",
                    systemImage: "questionmark.circle"
                )
                .font(.callout)
                .foregroundStyle(.orange)
            }
        }
        .padding()
        .background(.background.secondary)
    }

    private var transcript: some View {
        // Neueste zuerst: der Feed liefert die laufende Zeile oben, darunter
        // die fertigen in absteigender Zeit. Ein Autoscroll erübrigt sich
        // damit, und er kämpfte ohnehin gegen jeden Griff zum Scrollbalken.
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(model.liveTranscriptRows) { row in
                    TranscriptLineView(
                        speaker: ChannelLabel.speakerLabel(
                            row.block.channel.speakerLabel
                        ),
                        text: row.block.text,
                        isVolatile: row.kind == .volatile
                    )
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay {
            if model.liveTranscriptRows.isEmpty {
                ContentUnavailableView(
                    "Waiting for speech",
                    systemImage: "waveform.badge.magnifyingglass",
                    description: Text("The live transcript appears here as soon as someone speaks.")
                )
            }
        }
        // Aufnahmefehler laufen in die zentrale Meldungsleiste am Fenster.
        // Hier zu melden half nur, solange eine Aufnahme lief - also gerade
        // nicht in den Faellen, die zaehlen (Start scheitert, Mikro
        // verweigert, Aufnahme beendet).
    }
}

struct TranscriptLineView: View {
    let speaker: String
    let text: String
    let isVolatile: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(speaker)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .foregroundStyle(isVolatile ? .secondary : .primary)
                .italic(isVolatile)
                .textSelection(.enabled)
        }
    }
}

struct LevelMeter: View {
    let label: LocalizedStringResource
    let level: AudioLevels?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.quaternary)
                    Capsule()
                        .fill(Steno.Colors.brand)
                        .frame(width: geometry.size.width * CGFloat(normalized))
                }
            }
            .frame(width: 120, height: 6)
        }
        // "Kommt ueberhaupt Signal an" ist die kritischste Information zu
        // Aufnahmebeginn und war fuer VoiceOver bisher unsichtbar.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(String(localized: label)) level"))
        .accessibilityValue("\(Int(normalized * 100)) percent")
    }

    /// RMS grob auf 0...1 abgebildet; -50 dB gilt als Stille.
    private var normalized: Float {
        guard let level, level.rms > 0 else { return 0 }
        let db = 20 * log10(level.rms)
        return max(0, min(1, (db + 50) / 50))
    }
}
