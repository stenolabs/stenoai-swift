import Observation
import StenoDomain
import StenoIntelligence
import StenoLibrary
import StenoPipeline
import SwiftUI

/// Card region under the home status strip for the pre-meeting brief.
///
/// Shows the next upcoming calendar event when the app can see one, or a
/// manual "Prepare brief…" control for the selected meeting. Hovering the
/// row reveals the Brief CTA - mirroring the legacy upcoming card's
/// hover-revealed action row (`upcoming-card-brief-btn`). Activating the CTA
/// streams the answer into an expanding region
/// (`upcoming-card-brief-content`); collapsing that region cancels the
/// in-flight generation. When no prior note relates, a calm empty state
/// renders instead of an error (`upcoming-card-brief-empty`).
///
/// Calendar seam: `CalendarPreMeetingScheduler` currently turns events into
/// notifications without exposing them. The optional provider closure below
/// accepts that source once it exists; until then the manual control on the
/// selected meeting covers every case.
struct PreMeetingBriefCard: View {
    @Environment(AppModel.self) private var model
    @Environment(TextModelSettings.self) private var textModelSettings

    /// Optional upcoming-event source; wired by the app shell once the
    /// calendar integration exposes its polled events.
    var upcomingEventProvider: (() async -> UpcomingCalendarEvent?)?

    @State private var service: PreMeetingBriefService?
    @State private var expanded = false
    @State private var hovered = false
    @State private var isPreparing = false
    @State private var upcomingEvent: UpcomingCalendarEvent?
    /// One confirmation per app session before the first external send,
    /// mirroring the live Ask bar and library chat.
    @State private var pendingExternalNotice: LocalizedExternalModelNotice?
    @State private var pendingTarget: BriefTarget?
    @State private var externalConsent = ExternalSendConsent()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let event = upcomingEvent {
                eventRow(event)
                Divider()
            } else if selectedMeeting != nil {
                selectedMeetingRow
                Divider()
            }
            if expanded {
                briefRegion
                Divider()
            }
        }
        .task {
            guard service == nil else { return }
            service = PreMeetingBriefService(makeAnswerer: { [weak textModelSettings] in
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
            })
            await refreshUpcomingEventLoop()
        }
        .onDisappear {
            // Leaving the home surface must not leave a stream running.
            service?.cancel()
        }
        .overlay {
            if let pendingExternalNotice {
                externalConfirmation(notice: pendingExternalNotice)
            }
        }
    }

    // MARK: Rows

    private func eventRow(_ event: UpcomingCalendarEvent) -> some View {
        HStack(spacing: Steno.Space.s) {
            Image(systemName: "calendar")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title.isEmpty ? "Upcoming meeting" : event.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(event.start, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if hovered {
                briefButton(target: BriefTarget(
                    kind: .upcoming(title: event.title),
                    localeIdentifier: nil
                ))
            }
        }
        .padding(.horizontal, Steno.Space.m)
        .padding(.vertical, Steno.Space.s)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                hovered = hovering
            }
        }
        .help("Prepare a brief from your prior notes")
    }

    /// Manual control path: no calendar seam (or nothing upcoming), so the
    /// selected meeting acts as the target for the brief.
    private var selectedMeetingRow: some View {
        HStack(spacing: Steno.Space.s) {
            Image(systemName: "sparkles")
                .foregroundStyle(.secondary)
            Text("Prepare brief…")
                .font(.callout.weight(.medium))
                .lineLimit(1)
            Spacer()
            if hovered, let meeting = selectedMeeting {
                briefButton(target: BriefTarget(
                    kind: .meeting(meeting.id),
                    localeIdentifier: meeting.sourceLocale?.localeIdentifier
                ))
            }
        }
        .padding(.horizontal, Steno.Space.m)
        .padding(.vertical, Steno.Space.s)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                hovered = hovering
            }
        }
        .help("Prepare a brief from your prior notes")
    }

    private func briefButton(target: BriefTarget) -> some View {
        Button("Prepare brief…") {
            requestBrief(for: target)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(isPreparing || service?.isActive == true)
    }

    // MARK: Brief region

    @ViewBuilder
    private var briefRegion: some View {
        switch service?.phase {
        case .streaming(let text):
            HStack(alignment: .top, spacing: Steno.Space.s) {
                Image(systemName: "text.bubble")
                    .foregroundStyle(.secondary)
                ScrollView {
                    Text(text.isEmpty ? "…" : text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
                Button {
                    collapse()
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.borderless)
                .help("Collapse and cancel")
            }
            .padding(.horizontal, Steno.Space.m)
            .padding(.vertical, Steno.Space.s)
        case .empty(let message):
            // Calm empty state, deliberately not an error presentation.
            Label(message, systemImage: "tray")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Steno.Space.m)
                .padding(.vertical, Steno.Space.s)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(Steno.Colors.uncertain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Steno.Space.m)
                .padding(.vertical, Steno.Space.s)
        case .idle, .none:
            EmptyView()
        }
    }

    private func collapse() {
        expanded = false
        service?.cancel()
    }

    // MARK: Targets

    private struct BriefTarget {
        enum Kind {
            case upcoming(title: String)
            case meeting(MeetingID)
        }

        let kind: Kind
        let localeIdentifier: String?
    }

    private var selectedMeeting: Meeting? {
        model.selectedMeetingID.flatMap { id in
            model.meetings.first { $0.id == id }
        }
    }

    private func requestBrief(for target: BriefTarget) {
        guard !externalConsent.permits(textModelSettings.selectedEndpoint) else {
            Task { await startBrief(for: target) }
            return
        }
        pendingTarget = target
        externalConsent.prepare(textModelSettings.selectedEndpoint)
        pendingExternalNotice = makeExternalNotice()
        if pendingExternalNotice == nil {
            pendingTarget = nil
            model.report("The brief could not be prepared.")
        }
    }

    /// Reuses the shared outbound disclosure unchanged, mapping only data
    /// classes: prior report markdown derives from transcripts, so it maps
    /// onto the transcript class. No content enters the notice.
    private func makeExternalNotice() -> LocalizedExternalModelNotice? {
        guard let endpoint = textModelSettings.selectedEndpoint else { return nil }
        let revision = TranscriptRevision(
            meetingID: MeetingID(),
            origin: .liveProvisional,
            turns: [
                TranscriptTurn(
                    speaker: .channel("report"),
                    start: 0,
                    end: 0,
                    segments: [
                        TranscriptSegment(text: "report", start: 0, end: 0, words: []),
                    ]
                ),
            ]
        )
        return try? LocalizedExternalModelNotice.make(
            endpoint: endpoint,
            disclosure: OutboundDisclosure(
                transcript: revision,
                context: RenderContext(participants: [])
            ),
            localDeviceDescription: "this Mac"
        )
    }

    private func externalConfirmation(notice: LocalizedExternalModelNotice) -> some View {
        VStack(alignment: .leading, spacing: Steno.Space.m) {
            Label("Send to an external model?", systemImage: "arrow.up.forward.circle")
                .font(.headline)
            Text(notice.text)
                .font(.callout)
            HStack {
                Spacer()
                Button("Cancel") {
                    pendingExternalNotice = nil
                    pendingTarget = nil
                }
                .keyboardShortcut(.cancelAction)
                Button("Prepare once, then keep going") {
                    pendingExternalNotice = nil
                    guard let target = pendingTarget else { return }
                    pendingTarget = nil
                    _ = externalConsent.accept(current: textModelSettings.selectedEndpoint)
                    requestBrief(for: target)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Steno.Space.l)
        .frame(width: 420)
    }

    @MainActor
    private func startBrief(for target: BriefTarget) async {
        guard let service else { return }
        let endpoint = textModelSettings.selectedEndpoint
        isPreparing = true
        defer { isPreparing = false }

        let title: String
        let names: [String]
        switch target.kind {
        case .upcoming(let eventTitle):
            title = eventTitle
            names = []
        case .meeting(let meetingID):
            let meeting = model.meetings.first { $0.id == meetingID }
            title = meeting?.title ?? ""
            // The helper must not share its name with the local: Swift
            // resolves the call against the declared local otherwise.
            names = await collectAttendeeNames(for: meeting)
        }

        let sources = await collectSources()
        guard textModelSettings.selectedEndpoint == endpoint,
              externalConsent.permits(endpoint) else {
            requestBrief(for: target)
            return
        }
        let budget = PreMeetingBriefBudget.budgetCharacters(
            hosting: endpoint?.hosting,
            contextTokens: endpoint?.contextWindowTokens
        )
        expanded = true
        service.prepare(
            targetTitle: title,
            targetAttendeeNames: names,
            sources: sources,
            characterBudget: budget,
            localeIdentifier: target.localeIdentifier
        )
    }

    /// Cleaned display names for one meeting's participants. Silent
    /// attendees count too: they were present last time, which is the whole
    /// point of the brief.
    @MainActor
    private func collectAttendeeNames(for meeting: Meeting?) async -> [String] {
        guard let meeting else { return [] }
        let persons = await model.allPersons()
        let namesByID = Dictionary(
            uniqueKeysWithValues: persons.map { ($0.id, $0.displayName) }
        )
        return (meeting.participantIDs + meeting.additionalParticipantIDs)
            .compactMap { namesByID[$0] }
            .compactMap { PreMeetingBriefAttendeeCleaner.clean($0) }
    }

    /// Snapshots every ready meeting's latest report markdown plus its
    /// cleaned attendee display names. `model.meetings` is already
    /// reverse-chronological; the builder re-sorts deterministically anyway.
    @MainActor
    private func collectSources() async -> [PreMeetingBriefSource] {
        guard let runtime = model.runtime else { return [] }
        let layout = runtime.library.layout
        let reportStore = TemplateResultStore(layout: layout)
        let persons = await model.allPersons()
        let namesByID = Dictionary(
            uniqueKeysWithValues: persons.map { ($0.id, $0.displayName) }
        )

        var sources: [PreMeetingBriefSource] = []
        for meeting in model.meetings where meeting.status == .ready {
            let reports = (try? reportStore.listWithRepairOutcome(meetingID: meeting.id))?
                .results ?? []
            let latestMarkdown = reports
                .max { $0.result.createdAt < $1.result.createdAt }?
                .result.markdown
            let attendeeNames = (meeting.participantIDs + meeting.additionalParticipantIDs)
                .compactMap { namesByID[$0] }
                .compactMap { PreMeetingBriefAttendeeCleaner.clean($0) }
            sources.append(PreMeetingBriefSource(
                title: meeting.title,
                createdAt: meeting.createdAt,
                attendeeNames: attendeeNames,
                summary: latestMarkdown
            ))
        }
        return sources
    }

    /// Coarse polling matches the status strip's cheap-facts cadence; the
    /// provider itself decides whether any calendar data exists. With no
    /// provider wired the loop stays dormant and the manual row shows.
    private func refreshUpcomingEventLoop() async {
        while !Task.isCancelled {
            if let provider = upcomingEventProvider {
                let event = await provider()
                upcomingEvent = (event?.start ?? .distantPast) > Date() ? event : nil
            }
            try? await Task.sleep(for: .seconds(60))
        }
    }
}
