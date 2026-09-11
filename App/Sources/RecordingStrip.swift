import SwiftUI

/// Der schmale Streifen, der waehrend einer Aufnahme immer oben steht -
/// unabhaengig davon, welches Meeting gerade geoeffnet ist.
///
/// Er ist die Gegenleistung dafuer, dass die Aufnahme die App nicht mehr
/// sperrt: wer waehrend eines Gespraechs etwas nachschlaegt, muss trotzdem
/// jederzeit sehen, dass aufgenommen wird, worin aufgenommen wird und wie
/// lange schon - und mit einem Klick zurueckfinden.
struct RecordingStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Steno.Space.m) {
            HStack(spacing: Steno.Space.s) {
                Circle()
                    .fill(Steno.Colors.recording)
                    .frame(width: 9, height: 9)
                    .accessibilityHidden(true)
                if let start = model.recordingStartedAt {
                    Text(start, style: .timer)
                        .font(.callout.monospacedDigit())
                        .accessibilityLabel("Recording time")
                }
            }

            if isElsewhere {
                // Nur wenn man woanders steht. Im Aufnahme-Meeting selbst waere
                // ein Knopf, der zum aktuellen Ort fuehrt, blosses Rauschen.
                Button {
                    model.selectedMeetingID = model.recordingMeetingID
                } label: {
                    Label(recordingTitle, systemImage: "record.circle")
                        .lineLimit(1)
                }
                .buttonStyle(.link)
                .help("Back to the recording")
            } else {
                Text(recordingTitle)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }


            // Per-recording template pinning: the dock shows the active
            // template by name (global default until a choice is made)
            // and allows a MID-RECORDING switch, which re-pins the created
            // meeting live. The choice is one-shot and resets after stop;
            // continue/append recordings never override an existing pin.
            Menu {
                Picker("Report Template", selection: templateSelection) {
                    ForEach(
                        model.recordingTemplateOptions,
                        id: \.template.id
                    ) { entry in
                        Text(entry.template.name)
                            .tag(Optional(entry.template.id))
                    }
                }
            } label: {
                Label(
                    model.recordingActiveTemplateName,
                    systemImage: "doc.text"
                )
            }
            .disabled(model.recordingContinuesExistingMeeting)
            .fixedSize()
            .help(
                model.recordingContinuesExistingMeeting
                    ? "Continued recordings keep this note's template"
                    : "Choose the report template for this recording"
            )

            LevelMeter(label: "Microphone", level: RecordingTrackPresentation(status: model.microphoneStatus).isPaused ? .silence : model.levels[.microphone])
            LevelMeter(label: "System", level: model.levels[.system])

            // F11: mid-recording language switch. The pick becomes the live
            // lanes' desired locale and pins the final ASR language; rows
            // already finalized keep their original language.
            Menu {
                Picker("Transcription Language", selection: languageSelection) {
                    ForEach(model.availableLocales, id: \.identifier) { locale in
                        Text(model.localizedLanguageName(locale))
                            .tag(locale.identifier)
                    }
                }
            } label: {
                Label(
                    model.recordingLanguagePickerTitle,
                    systemImage: "globe"
                )
            }
            .disabled(!model.canChangeRecordingLanguage)
            .fixedSize()

            .help("Switch the transcription language for the rest of this recording")

            Button("Stop") {
                Task { await model.stopRecording() }
            }
            .controlSize(.small)
            .help("Stop recording (Cmd-.)")
        }
        .padding(.horizontal, Steno.Space.m)
        .padding(.vertical, Steno.Space.s)
        .background(.background.secondary)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// Selection binding for the template menu. The menu offers no
    /// explicit "default" row: the pinned id is nil until a choice is
    /// made, and stopping the recording resets it (one-shot).
    private var templateSelection: Binding<String?> {
        Binding(
            get: { model.recordingPinnedTemplateID },
            set: { id in
                Task { await model.selectRecordingTemplate(id) }
            }
        )
    }

    /// Selection binding for the mid-recording language menu: reads the
    /// model's current decision, writes through the manual-switch path.
    private var languageSelection: Binding<String> {
        Binding(
            get: { model.recordingLanguageSelectionID },
            set: { model.selectRecordingLanguage($0) }
        )
    }

    private var isElsewhere: Bool {
        model.selectedMeetingID != model.recordingMeetingID
    }

    private var recordingTitle: String {
        model.meetings.first { $0.id == model.recordingMeetingID }?.title
            ?? "Recording"
    }
}
