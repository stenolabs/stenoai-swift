import StenoDomain
import StenoIntelligence
import StenoLibrary
import StenoPipeline
import SwiftUI

struct MeetingBriefView: View {
    @Environment(AppModel.self) private var app
    @Environment(TextModelSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let meetingID: MeetingID
    @State private var service: PreMeetingBriefService?
    @State private var consent = ExternalSendConsent()
    @State private var notice: LocalizedExternalModelNotice?
    @State private var preparation: Task<Void, Never>?
    @State private var isPreparing = false
    @State private var preparationGeneration: UInt64 = 0
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(app.meetings.first { $0.id == meetingID }?.title ?? "")
                        .font(.title2.bold())
                    Text("Prepare for this meeting using related earlier meeting reports.")
                        .foregroundStyle(.secondary)
                    if let failure { Text(failure).foregroundStyle(.red) }
                    switch service?.phase {
                    case .empty(let text), .failed(let text): Text(LocalizedStringKey(text))
                    case .streaming(let text): Text(text).textSelection(.enabled)
                    default: EmptyView()
                    }
                    if isPreparing { ProgressView() }
                    if service?.isActive == true || isPreparing {
                        Button("Stop") { cancel() }
                    } else {
                        Button("Prepare brief…") { prepare() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!app.isReady || app.recording.isActive)
                    }
                }
                .padding()
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Meeting preparation")
            .toolbar { Button("Done") { dismiss() } }
            .task {
                service = PreMeetingBriefService(makeAnswerer: makeAnswerer)
            }
            .onDisappear { cancel() }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {
                    if service?.isActive == true || isPreparing {
                        failure = String(localized: "Preparation was interrupted. You can try again.")
                    }
                    cancel()
                }
            }
            .onChange(of: app.runtimeSnapshot()?.generation) { _, _ in cancel(); dismiss() }
            .alert("External model", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
                Button("Cancel", role: .cancel) { notice = nil }
                Button("Continue") {
                    notice = nil
                    if consent.accept(current: settings.selectedEndpoint) { prepare() }
                    else { failure = String(localized: "The model destination changed. Please try again.") }
                }
            } message: { Text(notice?.text ?? "") }
        }
    }

    private func prepare() {
        guard !isPreparing, service?.isActive != true else { return }
        failure = nil
        isPreparing = true
        let endpoint = settings.selectedEndpoint
        preparationGeneration &+= 1
        let generation = preparationGeneration
        preparation = Task { @MainActor in
            defer {
                if preparationGeneration == generation {
                    isPreparing = false
                    preparation = nil
                }
            }
            do {
                guard let snapshot = app.runtimeSnapshot(), app.isCurrent(snapshot),
                      let target = app.meetings.first(where: { $0.id == meetingID }) else { return }
                let people = try await app.allPersons()
                let names = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0.displayName) })
                func attendees(_ meeting: Meeting) -> [String] {
                    (meeting.participantIDs + meeting.additionalParticipantIDs)
                        .compactMap { names[$0] }.compactMap(PreMeetingBriefAttendeeCleaner.clean)
                }
                let candidates = app.meetings.filter { $0.id != target.id && $0.status == .ready && $0.createdAt < target.createdAt }
                let reports = TemplateResultStore(layout: snapshot.runtime.library.layout)
                var sources: [PreMeetingBriefSource] = []
                for meeting in candidates {
                    try Task.checkCancellation()
                    let latest = try reports.listWithRepairOutcome(meetingID: meeting.id).results
                        .max { $0.result.createdAt < $1.result.createdAt }?.result.markdown
                    sources.append(PreMeetingBriefSource(title: meeting.title, createdAt: meeting.createdAt,
                        attendeeNames: attendees(meeting), summary: latest))
                }
                try Task.checkCancellation()
                guard app.isCurrent(snapshot), settings.selectedEndpoint == endpoint,
                      scenePhase == .active, !app.recording.isActive else { return }
                if !consent.permits(endpoint), let endpoint {
                    consent.prepare(endpoint)
                    notice = try LibraryChatSourceCollector.notice(endpoint: endpoint, sources: sources.map {
                        LibraryChatMeetingSource(title: $0.title, createdAt: $0.createdAt, userNotes: nil, reportMarkdown: $0.summary)
                    }, device: "this device")
                    return
                }
                let budget = endpoint.map {
                    PreMeetingBriefBudget.budgetCharacters(hosting: $0.hosting, contextTokens: $0.contextWindowTokens)
                } ?? PreMeetingBriefBudget.localBudgetCharacters(contextTokens: 8192)
                service?.prepare(targetTitle: target.title, targetAttendeeNames: attendees(target), sources: sources,
                    characterBudget: budget, localeIdentifier: target.sourceLocale?.localeIdentifier)
            } catch is CancellationError {} catch {
                failure = String(localized: "The brief could not be prepared.")
            }
        }
    }

    private func cancel() {
        preparationGeneration &+= 1
        preparation?.cancel()
        preparation = nil
        isPreparing = false
        service?.cancel()
    }

    private func makeAnswerer() throws -> any LiveQueryAnswering {
        if let endpoint = settings.selectedEndpoint {
            return ExternalChatCompletionsLiveQueryStreamer(endpoint: endpoint, resolvingSecret: { id in
                try TextModelKeychain.shared.value(for: TextModelSecretSlot(endpointID: id, configurationRevision: endpoint.configurationRevision))
            })
        }
        return FoundationModelsLiveQueryStreamer()
    }
}
