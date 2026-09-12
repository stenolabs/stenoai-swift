import StenoDomain
import StenoIntelligence
import StenoLibrary
import StenoPipeline
import SwiftUI

struct LibraryChatView: View {
    @Environment(AppModel.self) private var app
    @Environment(TextModelSettings.self) private var settings
    @Environment(\.scenePhase) private var scenePhase
    @State private var service: LibraryChatService?
    @State private var session = LibraryChatSession(title: "Chat")
    @State private var savedSession: LibraryChatSession?
    @State private var sessions: [LibraryChatSession] = []
    @State private var draft = ""
    @State private var consent = ExternalSendConsent()
    @State private var notice: LocalizedExternalModelNotice?
    @State private var isPreparing = false
    @State private var preparationGeneration: UInt64 = 0
    @State private var submission: Task<Void, Never>?
    @State private var showHistory = false
    @State private var showMeetings = false
    @State private var scopedMeetingIDs: Set<MeetingID> = []
    @State private var errorMessage: String?
    @State private var storage: IOSChatSessionStore?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if session.messages.isEmpty {
                    ContentUnavailableView("Ask your meetings", systemImage: "bubble.left.and.bubble.right",
                        description: Text("Ask questions about your notes and meeting reports."))
                }
                ForEach(session.messages) { message in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(message.role == .user ? String(localized: "You") : "Steno").font(.caption.bold()).foregroundStyle(.secondary)
                        Text(message.text).textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let service, service.isActive {
                    switch service.phase {
                    case .asking: ProgressView()
                    case .answering(let text): Text(text).textSelection(.enabled)
                    default: EmptyView()
                    }
                } else if case .failed(let message) = service?.phase {
                    Text(LocalizedStringKey(message)).foregroundStyle(.red)
                }
            }
            .padding()
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Chat")
        .safeAreaInset(edge: .bottom) { composer }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Chat history", systemImage: "clock") { reloadHistory(); showHistory = true }
                    .disabled(isBusy)
                Button("New Chat", systemImage: "square.and.pencil") {
                    session = LibraryChatSession(title: String(localized: "Chat"))
                    savedSession = nil
                }.disabled(isBusy)
            }
        }
        .task(id: app.runtimeSnapshot()?.generation) {
            cancel()
            service = LibraryChatService(makeAnswerer: makeAnswerer)
            service?.onFinish = { answer in
                if let answer {
                    session.messages.append(LibraryChatMessage(role: .assistant, text: answer))
                    persist()
                }
            }
            storage = app.runtime.map { IOSChatSessionStore(layout: $0.library.layout) }
            session = LibraryChatSession(title: String(localized: "Chat"))
            savedSession = nil
            reloadHistory()
        }
        .onDisappear { cancel() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { cancel() }
        }
        .sheet(isPresented: $showHistory) { history }
        .sheet(isPresented: $showMeetings) { meetingPicker }
        .alert("External model", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("Cancel", role: .cancel) { notice = nil }
            Button("Continue") {
                notice = nil
                if consent.accept(current: settings.selectedEndpoint) { submit() }
                else { errorMessage = String(localized: "The model destination changed. Please try again.") }
            }
        } message: { Text(notice?.text ?? "") }
        .alert("Chat", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private var isBusy: Bool { isPreparing || service?.isActive == true }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Menu {
                Button("All meetings") { session.scope = .all }
                ForEach(app.folders, id: \.id) { folder in
                    Button(folder.name) { session.scope = .folder(folder.id) }
                }
                Button("Specific meetings") { showMeetings = true }
            } label: { Label(scopeTitle, systemImage: "line.3.horizontal.decrease") }
            .disabled(isBusy)
            HStack(alignment: .bottom) {
                TextField("Ask a question", text: $draft, axis: .vertical).lineLimit(1...5)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isBusy)
                if isBusy {
                    Button("Stop", systemImage: "stop.circle") { cancel() }
                } else {
                    Button("Send", systemImage: "arrow.up.circle.fill") { submit() }
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !app.isReady)
                }
            }
        }
        .padding()
        .background(.bar)
    }

    private var scopeTitle: String {
        switch session.scope {
        case .all: String(localized: "All meetings")
        case .folder(let id): app.folders.first { $0.id == id }?.name ?? String(localized: "Folder unavailable")
        case .meetings(let ids): String(localized: "\(ids.count) selected meetings")
        }
    }

    private var history: some View {
        NavigationStack {
            List {
                ForEach(sessions) { stored in
                    Button(stored.title) {
                        session = stored
                        savedSession = stored
                        showHistory = false
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) {
                            do {
                                try storage?.remove(stored)
                                reloadHistory()
                                if session.id == stored.id {
                                    session = LibraryChatSession(title: String(localized: "Chat"))
                                    savedSession = nil
                                }
                            } catch { errorMessage = String(localized: "The chat could not be deleted.") }
                        }
                    }
                }
            }
            .navigationTitle("Chat history")
            .toolbar { Button("Done") { showHistory = false } }
        }
    }

    private var meetingPicker: some View {
        NavigationStack {
            List(app.meetings.filter { $0.status != .recording }, id: \.id, selection: $scopedMeetingIDs) { meeting in
                Text(meeting.title)
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Specific meetings")
            .toolbar {
                Button("Done") { session.scope = .meetings(Array(scopedMeetingIDs)); showMeetings = false }
                    .disabled(scopedMeetingIDs.isEmpty)
            }
            .onAppear {
                if case .meetings(let ids) = session.scope { scopedMeetingIDs = Set(ids) }
            }
        }
    }

    private func submit() {
        guard !isBusy, let service else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard text.count <= LibraryChatLimits.maximumMessageCharacters else {
            errorMessage = String(localized: "The question is too long."); return
        }
        let endpoint = settings.selectedEndpoint
        let scope = session.scope
        let sessionID = session.id
        isPreparing = true
        preparationGeneration &+= 1
        let generation = preparationGeneration
        submission = Task { @MainActor in
            defer {
                if preparationGeneration == generation {
                    isPreparing = false
                    submission = nil
                }
            }
            do {
                guard let snapshot = app.runtimeSnapshot(), app.isCurrent(snapshot) else { return }
                let sources = try await LibraryChatSourceCollector.collect(library: snapshot.runtime.library, meetings: app.meetings, scope: scope)
                try Task.checkCancellation()
                guard app.isCurrent(snapshot), session.id == sessionID,
                      settings.selectedEndpoint == endpoint, scenePhase == .active else { return }
                if !consent.permits(endpoint), let endpoint {
                    consent.prepare(endpoint)
                    notice = try LibraryChatSourceCollector.notice(endpoint: endpoint, sources: sources, device: "this device")
                    return
                }
                session.messages.append(LibraryChatMessage(role: .user, text: text))
                if session.messages.count == 1 { session.title = String(text.prefix(60)) }
                guard persist() else { session.messages.removeLast(); return }
                draft = ""
                service.ask(message: text, sources: sources)
            } catch is CancellationError {} catch {
                errorMessage = String(localized: "The meeting content could not be prepared.")
            }
        }
    }

    private func makeAnswerer() throws -> any LiveQueryAnswering {
        if let endpoint = settings.selectedEndpoint {
            return ExternalChatCompletionsLiveQueryStreamer(endpoint: endpoint, resolvingSecret: { id in
                try TextModelKeychain.shared.value(for: TextModelSecretSlot(endpointID: id, configurationRevision: endpoint.configurationRevision))
            })
        }
        return FoundationModelsLiveQueryStreamer()
    }

    private func cancel() {
        preparationGeneration &+= 1
        submission?.cancel()
        submission = nil
        isPreparing = false
        let active = service?.isActive == true
        service?.cancel()
        if active { errorMessage = String(localized: "The answer was interrupted. You can send the question again.") }
    }

    @discardableResult private func persist() -> Bool {
        do {
            guard let storage else { throw CocoaError(.fileNoSuchFile) }
            try storage.save(session, expected: savedSession)
            savedSession = session
            return true
        } catch {
            errorMessage = String(localized: "The chat could not be saved. Another window may have changed it.")
            return false
        }
    }

    private func reloadHistory() {
        do { sessions = try storage?.load() ?? [] }
        catch { errorMessage = String(localized: "The chat history could not be read.") }
    }
}
