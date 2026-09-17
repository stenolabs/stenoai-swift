import Observation
import StenoDomain
import StenoIntelligence
import StenoLibrary
import StenoPipeline
import SwiftUI

extension Notification.Name {
    static let libraryChatIntentQueued = Notification.Name(
        "org.steno.library-chat.intent-queued"
    )
}

/// Loads and stores the session list. A missing key yields an empty list;
/// undecodable data is treated as absent rather than fatal - the window then
/// starts fresh instead of blocking the whole app on one bad blob. Content
/// is never logged anywhere.
struct LibraryChatSessionStore {
    static let defaultsKey = "steno.chat.sessions"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [LibraryChatSession] {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return [] }
        guard let sessions = try? JSONDecoder().decode([LibraryChatSession].self, from: data) else {
            return []
        }
        return sessions
    }

    func save(_ sessions: [LibraryChatSession]) {
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

/// State container behind the Library Chat window: owns the persisted
/// sessions and drives the single-in-flight chat service.
@MainActor
@Observable
final class LibraryChatModel {
    private let store: LibraryChatSessionStore
    let service: LibraryChatService

    private(set) var sessions: [LibraryChatSession] = []
    var selectedSessionID: UUID?

    /// Pending handoff for other surfaces (e.g. the People Directory's
    /// "Ask about <name>"): consumed once by LibraryChatWindow when it
    /// creates its chat model.
    struct Intent: Sendable {
        var presetDraft: String?
        var meetingIDs: [MeetingID]
    }

    @MainActor private static var pendingIntent: Intent?

    @MainActor
    static func queueIntent(_ intent: Intent) {
        pendingIntent = intent
        NotificationCenter.default.post(name: .libraryChatIntentQueued, object: nil)
    }

    @MainActor
    static func takePendingIntent() -> Intent? {
        defer { pendingIntent = nil }
        return pendingIntent
    }

    init(
        store: LibraryChatSessionStore = LibraryChatSessionStore(),
        makeAnswerer: @escaping @MainActor () throws -> any LiveQueryAnswering
    ) {
        self.store = store
        self.service = LibraryChatService(makeAnswerer: makeAnswerer)
        sessions = store.load()
        selectedSessionID = sessions.first?.id
    }

    var selectedSession: LibraryChatSession? {
        sessions.first { $0.id == selectedSessionID }
    }

    func createSession() {
        let untitledCount = sessions.filter { $0.title.hasPrefix("Chat ") }.count
        let session = LibraryChatSession(title: "Chat \(untitledCount + 1)")
        sessions.insert(session, at: 0)
        selectedSessionID = session.id
        store.save(sessions)
    }

    func deleteSession(_ id: UUID) {
        sessions.removeAll { $0.id == id }
        if selectedSessionID == id {
            selectedSessionID = sessions.first?.id
        }
        store.save(sessions)
    }

    func renameSession(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = sessions.firstIndex(where: { $0.id == id }) else {
            return
        }
        sessions[index].title = trimmed
        store.save(sessions)
    }

    func appendUserMessage(_ text: String, to sessionID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].messages.append(LibraryChatMessage(role: .user, text: text))
        store.save(sessions)
    }

    private func appendAssistantMessage(_ text: String, to sessionID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].messages.append(LibraryChatMessage(role: .assistant, text: text))
        store.save(sessions)
    }

    /// Sends the current draft about the whole library. The user message is
    /// committed immediately; the assistant answer lands through
    /// `onFinish`, so cancelled runs leave no dangling entry.
    func send(draft: String, sources: [LibraryChatMeetingSource]) {
        guard let sessionID = selectedSessionID, service.canSend else { return }
        let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        appendUserMessage(message, to: sessionID)
        service.onFinish = { [weak self] answer in
            guard let self, let answer else { return }
            self.appendAssistantMessage(answer, to: sessionID)
        }
        service.ask(message: message, sources: sources)
    }

    func cancel() {
        service.cancel()
    }

    /// Persists the active session's ask scope.
    func setScope(_ scope: LibraryChatScope, appModel: AppModel) {
        guard let index = sessions.firstIndex(where: { $0.id == selectedSessionID }) else { return }
        sessions[index].scope = scope
        store.save(sessions)
    }

    /// The session's scope with dead folder/meeting references healed away;
    /// the healed value is persisted so the chip stops lying about what is
    /// actually in range.
    func healedScope(appModel: AppModel) -> LibraryChatScope {
        guard let index = sessions.firstIndex(where: { $0.id == selectedSessionID }) else { return .all }
        let healed = LibraryChatScope.healed(
            sessions[index].scope, folders: appModel.folders, meetings: appModel.meetings
        )
        if healed != sessions[index].scope {
            sessions[index].scope = healed
            store.save(sessions)
        }
        return healed
    }

    /// Applies a cross-surface handoff: scopes the active session to the
    /// given meetings and persists it.
    func applyIntent(_ intent: Intent, appModel: AppModel? = nil) {
        guard !intent.meetingIDs.isEmpty else { return }
        if selectedSessionID == nil {
            createSession()
        }
        if let appModel {
            setScope(.meetings(intent.meetingIDs), appModel: appModel)
        } else if let index = sessions.firstIndex(where: { $0.id == selectedSessionID }) {
            sessions[index].scope = .meetings(intent.meetingIDs)
            store.save(sessions)
        }
    }

    /// Snapshots each in-scope meeting's latest report markdown plus its
    /// user note, title and date. Live meetings are never included: their
    /// transcripts are still moving. `model.meetings` is already reverse-
    /// chronological; the builder re-sorts deterministically regardless.
    func collectSources(appModel: AppModel, scope: LibraryChatScope) async -> [LibraryChatMeetingSource] {
        guard let runtime = appModel.runtime else { return [] }
        return (try? await LibraryChatSourceCollector.collect(
            library: runtime.library, meetings: appModel.meetings, scope: scope, requiresCompleteSources: false
        )) ?? []
    }
}
/// Provider resolution mirrors the live Ask bar exactly: Apple Foundation
/// Models by default, the configured external endpoint otherwise. The first
/// external send shows the shared outbound-disclosure confirmation; Apple
/// Foundation Models stays silent. Size caps all live in
/// `LibraryChatLimits`; this window adds none of its own.
struct LibraryChatWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(TextModelSettings.self) private var textModelSettings
    @Environment(\.dismiss) private var dismiss

    @State private var chat: LibraryChatModel?
    @State private var draft = ""
    /// One confirmation per app session before the first external send,
    /// mirroring the live Ask bar.
    @State private var externalConsent = ExternalSendConsent()
    @State private var pendingExternalNotice: LocalizedExternalModelNotice?
    @State private var renamingSession: LibraryChatSession?
    @State private var renameDraft = ""
    /// Shared '/'-recipe support; the menu only opens on an empty composer.
    @State private var recipeController = ChatRecipeController()
    @State private var showRecipeSaveSheet = false
    /// Multi-select sheet for the "specific notes" scope.
    @State private var showMeetingScopePicker = false

    var body: some View {
        Group {
            if let chat {
                content(chat)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            if chat == nil {
                chat = LibraryChatModel(makeAnswerer: makeAnswerer)
            }
            consumePendingIntent()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .libraryChatIntentQueued)
        ) { _ in
            consumePendingIntent()
        }
        .onDisappear {
            // Owner-bound cancellation on window close.
            chat?.cancel()
        }
    }

    private func consumePendingIntent() {
        guard let chat, let intent = LibraryChatModel.takePendingIntent() else { return }
        draft = intent.presetDraft ?? ""
        chat.applyIntent(intent, appModel: model)
    }

    private func content(_ chat: LibraryChatModel) -> some View {
        NavigationSplitView {
            List(selection: Binding(
                get: { chat.selectedSessionID },
                set: { chat.selectedSessionID = $0 }
            )) {
                ForEach(chat.sessions) { session in
                    Text(session.title)
                        .tag(session.id)
                        .contextMenu {
                            Button("Rename…") {
                                renamingSession = session
                                renameDraft = session.title
                            }
                            Button("Delete", role: .destructive) {
                                chat.deleteSession(session.id)
                            }
                        }
                }
            }
            .listStyle(.sidebar)
            .toolbar {
                Button {
                    chat.createSession()
                } label: {
                    Label("New Chat", systemImage: "plus")
                }
            }
        } detail: {
            conversationPane(chat)
        }
        .alert(
            "Rename Chat",
            isPresented: Binding(
                get: { renamingSession != nil },
                set: { if !$0 { renamingSession = nil } }
            )
        ) {
            TextField("Name", text: $renameDraft)
            Button("Cancel", role: .cancel) {
                renamingSession = nil
            }
            Button("Rename") {
                if let renamingSession {
                    chat.renameSession(renamingSession.id, to: renameDraft)
                }
                renamingSession = nil
            }
        }
        .overlay {
            if let pendingExternalNotice {
                externalConfirmation(chat, notice: pendingExternalNotice)
            }
        }
    }

    @ViewBuilder
    private func conversationPane(_ chat: LibraryChatModel) -> some View {
        if let session = chat.selectedSession {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: Steno.Space.m) {
                            ForEach(session.messages) { message in
                                MessageRow(message: message)
                                    .id(message.id)
                            }
                            streamingRow(chat)
                        }
                        .padding(Steno.Space.l)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: chat.service.phase) { _, _ in
                        if let last = session.messages.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: Steno.Space.s) {
                    HStack(spacing: Steno.Space.s) {
                        LibraryChatScopePicker(
                            scope: Binding(
                                get: { chat.selectedSession?.scope ?? .all },
                                set: { chat.setScope($0, appModel: model) }
                            ),
                            folders: model.folders,
                            meetings: model.meetings,
                            showMeetingPicker: $showMeetingScopePicker
                        )
                        Spacer()
                        if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Button("Save Recipe") {
                                showRecipeSaveSheet = true
                            }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("save-recipe-button")
                            .help("Save this text as a reusable recipe")
                        }
                    }
                    HStack(spacing: Steno.Space.s) {
                    TextField(
                        "Ask across all meetings…",
                        text: $draft,
                        axis: .vertical
                    )
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onChange(of: draft) { _, newValue in
                        recipeController.composerChanged(newValue)
                    }
                    .chatRecipeKeyboard(recipeController)
                    .onSubmit(submit)
                    .disabled(!chat.service.canSend)
                    Button("Send", systemImage: "arrow.up.circle.fill") {
                        submit()
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !chat.service.canSend)
                    if chat.service.isActive {
                        Button("Stop", systemImage: "stop.circle") {
                            chat.cancel()
                        }
                    }
                    }
                }
                .padding(Steno.Space.m)
                .overlay(alignment: .bottom) {
                    if recipeController.menuVisible {
                        ChatRecipeMenu(controller: recipeController) { recipe in
                            draft = recipe.prompt
                        }
                        .offset(y: -52)
                    }
                }
                .sheet(isPresented: $showRecipeSaveSheet) {
                    ChatRecipeSaveSheet(controller: recipeController, composerText: draft)
                }
                .sheet(isPresented: $showMeetingScopePicker) {
                    LibraryChatMeetingScopePicker(
                        meetings: model.meetings,
                        selected: Binding(
                            get: {
                                if case .meetings(let ids) = chat.selectedSession?.scope { return ids }
                                return []
                            },
                            set: { ids in
                                chat.setScope(ids.isEmpty ? .all : .meetings(ids), appModel: model)
                            }
                        )
                    )
                }
            }
        } else {
            ContentUnavailableView(
                "Library Chat",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("Create a chat to ask across every meeting's reports and notes.")
            )
        }
    }

    /// The in-flight answer, streamed into the conversation until the turn
    /// commits (or disappears on cancel/failure). Stable placeholder identity
    /// keeps one provisional row while the answer streams; the real message
    /// lands via `onFinish`.
    private static let pendingAnswerID = UUID(uuidString: "00000000-0000-0000-0000-00000000C0FF")!

    @ViewBuilder
    private func streamingRow(_ chat: LibraryChatModel) -> some View {
        Group {
                        switch chat.service.phase {
                        case .asking:
                            MessageRow(message: LibraryChatMessage(
                                id: Self.pendingAnswerID,
                                role: .assistant,
                                text: ""
                            ))
                        case .answering(let text) where chat.selectedSession?.messages.last?.role != .assistant:
                            MessageRow(message: LibraryChatMessage(
                                id: Self.pendingAnswerID,
                                role: .assistant,
                                text: text
                            ))
                        default:
                            EmptyView()
                        }
                    }
                }

    private func submit() {
        guard let chat, chat.service.canSend else { return }
        // Enter with the '/'-menu open selects the highlighted recipe
        // instead of sending.
        if let prompt = recipeController.selectCurrent() {
            draft = prompt
            return
        }
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Re-resolve the scope on every turn without ever broadening a stale
        // selection to the whole library.
        let scope = chat.healedScope(appModel: model)
        guard !scope.requiresExplicitSelection else {
            showMeetingScopePicker = true
            return
        }
        // Outbound disclosure before the first external send per session,
        // mirroring the live Ask bar. Apple Foundation Models stays silent.
        let endpoint = textModelSettings.selectedEndpoint
        if !externalConsent.permits(endpoint) {
            Task {
                let sources = await chat.collectSources(appModel: model, scope: scope)
                guard textModelSettings.selectedEndpoint == endpoint else { submit(); return }
                externalConsent.prepare(endpoint)
                pendingExternalNotice = makeExternalNotice(sources: sources)
            }
            return
        }
        Task {
            let sources = await chat.collectSources(appModel: model, scope: scope)
            guard textModelSettings.selectedEndpoint == endpoint,
                  externalConsent.permits(endpoint) else { submit(); return }
            chat.send(draft: trimmed, sources: sources)
            draft = ""
        }
    }



    /// Provider resolution identical to the live Ask bar: Foundation Models
    /// locally unless an external endpoint is selected.
    private func makeAnswerer() throws -> any LiveQueryAnswering {
        if let endpoint = textModelSettings.selectedEndpoint {
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
        }
        return FoundationModelsLiveQueryStreamer()
    }

    /// Reuses the shared outbound disclosure unchanged. The closest data
    /// classes map the actual payload: latest report markdown derives from
    /// transcripts (with speaker names), so any report maps onto the
    /// transcript class; user notes map onto their own class. Only the
    /// class presence is consumed - no content enters the notice.
    private func makeExternalNotice(sources: [LibraryChatMeetingSource]) -> LocalizedExternalModelNotice? {
        guard let endpoint = textModelSettings.selectedEndpoint else { return nil }
        let hasReports = sources.contains { $0.reportMarkdown != nil }
        let hasNotes = sources.contains { $0.userNotes != nil }
        let revision = TranscriptRevision(
            meetingID: MeetingID(),
            origin: .liveProvisional,
            turns: hasReports
                ? [
                    TranscriptTurn(
                        speaker: .channel("report"),
                        start: 0,
                        end: 0,
                        segments: [
                            TranscriptSegment(text: "report", start: 0, end: 0, words: []),
                        ]
                    ),
                ]
                : []
        )
        return try? LocalizedExternalModelNotice.make(
            endpoint: endpoint,
            disclosure: OutboundDisclosure(
                transcript: revision,
                context: RenderContext(userNotes: hasNotes ? "notes" : nil, participants: [])
            ),
            localDeviceDescription: "this Mac"
        )
    }

    private func externalConfirmation(_ chat: LibraryChatModel, notice: LocalizedExternalModelNotice) -> some View {
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
                    submit()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Steno.Space.l)
        .frame(width: 420)
        .background(.regularMaterial)
    }
}

private struct MessageRow: View {
    let message: LibraryChatMessage

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 48)
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(Steno.Space.m)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.accentColor.opacity(0.15))
                    )
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text("Steno")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(message.text.isEmpty ? "…" : message.text)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
