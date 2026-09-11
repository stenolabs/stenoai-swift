import StenoDomain
import StenoIntelligence
import StenoTranscription
import SwiftUI

/// Floating Ask bar above the recording controls (parity: legacy AskBar).
///
/// Answers questions over the finalized live transcript only. The visibility
/// binding is owned by the embedding view so the orchestrator can wire the
/// Cmd+Shift+A shortcut to the same `AppStorage` key without touching this
/// file.
struct AskBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(TextModelSettings.self) private var textModelSettings

    /// AppStorage key for bar visibility. StenoCommands toggles the same key
    /// for Cmd+Shift+A; the value survives restarts like the notes inspector.
    static let visibilityDefaultsKey = "steno.recording.askVisible"

    @Binding var isVisible: Bool

    @State private var service: LiveQueryService?
    @State private var draft = ""
    /// One confirmation per app session before the first external send.
    @State private var externalConsent = ExternalSendConsent()
    @State private var pendingExternalNotice: LocalizedExternalModelNotice?
    @State private var showRecipeSaveSheet = false
    /// Shared '/'-recipe support; the menu only opens on an empty composer.
    @State private var recipeController = ChatRecipeController()
    @FocusState private var fieldIsFocused: Bool

    var body: some View {
        if isVisible {
            bar
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var hasFinalizedContent: Bool {
        LiveQueryContext(
            rows: model.liveTranscriptRows,
            meetingTitle: nil,
            participantNames: []
        ).hasFinalizedContent
    }

    private var canSubmit: Bool {
        guard hasFinalizedContent, let service else { return false }
        return service.canAsk && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var bar: some View {
        VStack(alignment: .leading, spacing: Steno.Space.s) {
            if recipeController.menuVisible {
                ChatRecipeMenu(controller: recipeController) { recipe in
                    draft = recipe.prompt
                    fieldIsFocused = true
                }
            }
            answerArea
            HStack(spacing: Steno.Space.s) {
                TextField(
                    "Ask about this recording…",
                    text: $draft,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .lineLimit(1...3)
                .focused($fieldIsFocused)
                .disabled(!hasFinalizedContent)
                .onChange(of: draft) { _, newValue in
                    recipeController.composerChanged(newValue)
                }
                .chatRecipeKeyboard(recipeController)
                .onSubmit(submit)

                if let service, service.isActive {
                    Button {
                        service.cancel()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Stop answering")
                } else {
                    Button {
                        submit()
                    } label: {
                        Label("Ask", systemImage: "paperplane")
                    }
                    .buttonStyle(.borderless)
                    .disabled(!canSubmit)
                    .help("Ask about the finalized transcript")
                }

                Button {
                    close()
                } label: {
                    Label("Close", systemImage: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Close the ask bar")

                if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button("Save Recipe") {
                        showRecipeSaveSheet = true
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("save-recipe-button")
                    .help("Save this text as a reusable recipe")
                }
            }
            if !hasFinalizedContent {
                Text("The ask bar answers once the transcript has finalized text.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(Steno.Space.m)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.separator)
        )
        .padding([.horizontal, .bottom], Steno.Space.l)
        .task {
            if service == nil { service = makeService() }
        }
        // Owner-bound cancellation: leaving the recording screen or stopping
        // the recording tears the query down with the bar.
        .onDisappear {
            service?.cancel()
        }
        .sheet(item: $pendingExternalNotice) { notice in
            externalConfirmation(notice)
        }
        .sheet(isPresented: $showRecipeSaveSheet) {
            ChatRecipeSaveSheet(controller: recipeController, composerText: draft)
        }
    }

    @ViewBuilder
    private var answerArea: some View {
        if let service {
            switch service.phase {
            case .idle:
                EmptyView()
            case .asking:
                Label("Asking…", systemImage: "ellipsis")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .answering(let text):
                ScrollView {
                    Text(text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(Steno.Colors.uncertain)
            }
        }

    }
    private func submit() {
        // Enter with the '/'-menu open selects the highlighted recipe
        // instead of sending.
        if let prompt = recipeController.selectCurrent() {
            draft = prompt
            fieldIsFocused = true
            return
        }
        guard let service, canSubmit else { return }
        // Outbound disclosure before the first external send per session,
        // mirroring the reports flow. Apple Foundation Models stays silent.
        if !externalConsent.permits(textModelSettings.selectedEndpoint) {
            externalConsent.prepare(textModelSettings.selectedEndpoint)
            pendingExternalNotice = makeExternalNotice()
            return
        }
        service.ask(question: draft)
        draft = ""
    }

    private func makeService() -> LiveQueryService {
        LiveQueryService(
            makeAnswerer: { [weak textModelSettings] in
                guard let settings = textModelSettings,
                      let endpoint = settings.selectedEndpoint
                else {
                    return FoundationModelsLiveQueryStreamer()
                }
                return ExternalChatCompletionsLiveQueryStreamer(
                    endpoint: endpoint,
                    resolvingSecret: { endpointID in
                        try SystemTextModelSecretStore.shared.value(
                            for: TextModelSecretSlot(
                                endpointID: endpointID,
                                configurationRevision: endpoint.configurationRevision
                            )
                        )
                    }
                )
            },
            contextProvider: { [weak model] in
                guard let model else {
                    return LiveQueryContext(rows: [], meetingTitle: nil, participantNames: [])
                }
                return LiveQueryContext(
                    rows: model.liveTranscriptRows,
                    meetingTitle: model.meetings.first { $0.id == model.recordingMeetingID }?.title,
                    participantNames: []
                )
            }
        )
    }

    private func makeExternalNotice() -> LocalizedExternalModelNotice? {
        guard let endpoint = textModelSettings.selectedEndpoint else { return nil }
        let context = LiveQueryContext(
            rows: model.liveTranscriptRows,
            meetingTitle: model.meetings.first { $0.id == model.recordingMeetingID }?.title,
            participantNames: []
        )
        let revision = TranscriptRevision(
            meetingID: model.recordingMeetingID ?? MeetingID(),
            origin: .liveProvisional,
            turns: context.finalizedSegments.map { segment in
                TranscriptTurn(
                    speaker: .channel(segment.speaker),
                    start: segment.start ?? 0,
                    end: segment.end ?? 0,
                    segments: [
                        TranscriptSegment(
                            text: segment.text,
                            start: segment.start ?? 0,
                            end: segment.end ?? 0,
                            words: []
                        ),
                    ]
                )
            }
        )
        return try? LocalizedExternalModelNotice.make(
            endpoint: endpoint,
            disclosure: OutboundDisclosure(
                transcript: revision,
                context: RenderContext(participants: context.participantNames)
            ),
            localDeviceDescription: "this Mac"
        )
    }

    private func externalConfirmation(_ notice: LocalizedExternalModelNotice) -> some View {
        VStack(alignment: .leading, spacing: Steno.Space.m) {
            Label("Send to an external model?", systemImage: "arrow.up.forward.circle")
                .font(.headline)
            Text(notice.text)
                .font(.callout)
            HStack {
                Spacer()
                Button("Cancel") {
                    pendingExternalNotice = nil
                }
                .keyboardShortcut(.cancelAction)
                Button("Send once, then keep asking") {
                    let accepted = externalConsent.accept(current: textModelSettings.selectedEndpoint)
                    pendingExternalNotice = nil
                    guard accepted else { submit(); return }
                    if let service, canSubmit {
                        service.ask(question: draft)
                        draft = ""
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Steno.Space.l)
        .frame(width: 420)
    }

    private func close() {
        service?.cancel()
        draft = ""
        isVisible = false
    }
}

extension LocalizedExternalModelNotice: Identifiable {
    var id: String { text }
}
