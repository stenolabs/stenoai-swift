import Foundation
import StenoDomain
import StenoIntelligence
import StenoPipeline
import SwiftUI
import UIKit

struct MeetingReportsSection: View {
    @Environment(AppModel.self) private var app
    @Environment(TextModelSettings.self) private var textModels

    let meetingID: MeetingID
    let review: MeetingReviewData?
    let hasTranscript: Bool
    /// Tracks this recording never got. Copied and shared minutes have to carry
    /// that warning; the label on screen does not travel with the text.
    var unrecordedTracks: [MediaAsset.Kind] = []

    @State private var presentation = MeetingReportsPresentation()
    @State private var preflight: TemplateRenderPreflight?
    @State private var preflightError: String?
    @State private var informationMessage: String?
    @State private var selectedEndpointSnapshot: TextModelEndpointSnapshot?
    @State private var identity = ViewIdentityGeneration<MeetingID>()
    @State private var shareDisclosure = ReportShareDisclosureState()

    private static let readableWidth: CGFloat = 720

    var body: some View {
        Section("Minutes") {
            if hasCurrentIdentity {
                reportRows
            } else {
                ProgressView("Loading minutes…")
            }
        }
        .task(id: meetingID) {
            let token = identity.begin(meetingID)
            presentation = MeetingReportsPresentation()
            preflight = nil
            preflightError = nil
            informationMessage = nil
            shareDisclosure.discardRequests(notMatching: meetingID)
            selectedEndpointSnapshot = textModels.selectedEndpoint?.snapshot
            await loadPreflight(token)
            await refresh(token)
        }
        // Die Wahl bleibt, ihr Inhalt wird nachgezogen. Ohne das behaelt eine
        // offene Ansicht die Kopie vom Oeffnen: der Bericht ginge mit der
        // alten `configurationRevision` in die Warteschlange und wuerde
        // abgewiesen, und der Hinweis darueber naennte ein Ziel von gestern.
        .onChange(of: textModels.endpoints) {
            selectedEndpointSnapshot = ReportTextModelDisplay.refreshedSelection(
                selectedEndpointSnapshot,
                in: textModels.endpoints
            )
        }
        .task(id: ReportPollingKey(
            meetingID: meetingID,
            pendingJobID: presentation.pendingJobID
        )) {
            guard let token = identity.token(for: meetingID),
                  presentation.pendingJobID != nil
            else { return }
            await refreshLoop(token)
        }
        .alert(
            Text(ReportShareDisclosurePresentation.title),
            isPresented: shareDisclosureIsPresented,
            presenting: shareDisclosure.pendingPayload
        ) { _ in
            Button {
                shareDisclosure.proceed(
                    meetingID: meetingID,
                    store: ReportShareDisclosureStore()
                )
            } label: {
                Text(ReportShareDisclosurePresentation.proceedLabel)
            }
            Button(role: .cancel) {
                shareDisclosure.cancelDisclosure()
            } label: {
                Text(ReportShareDisclosurePresentation.cancelLabel)
            }
        } message: { _ in
            Text(ReportShareDisclosurePresentation.message)
        }
        .sheet(isPresented: reportShareSheetIsPresented) {
            if let request = shareDisclosure.activeRequest,
               request.meetingID == meetingID {
                ReportShareSheet(text: request.payload.text) {
                    shareDisclosure.finishSharing()
                }
            }
        }
    }

    @ViewBuilder
    private var reportRows: some View {
        modelPicker

        if let errorMessage = presentation.errorMessage {
            HStack(alignment: .firstTextBaseline, spacing: Steno.Space.s) {
                reportMessage(
                    errorMessage,
                    systemImage: "exclamationmark.circle",
                    color: Steno.Colors.error
                )
                Spacer(minLength: Steno.Space.s)
                if !presentation.hasReconciledSnapshot {
                    Button("Try again") {
                        retryInitialLoad()
                    }
                    .controlSize(.small)
                }
            }
        }

        if presentation.isPending, let informationMessage {
            reportMessage(
                informationMessage,
                systemImage: "info.circle",
                color: Color(uiColor: .secondaryLabel)
            )
        }

        if let speakerHint = viewState.speakerHint {
            reportMessage(
                String(localized: speakerHint),
                systemImage: "person.crop.circle.badge.questionmark",
                color: Color(uiColor: .secondaryLabel)
            )
        }

        if let message = blockingMessage {
            HStack(alignment: .firstTextBaseline, spacing: Steno.Space.s) {
                reportMessage(
                    message,
                    systemImage: "info.circle",
                    color: Color(uiColor: .secondaryLabel)
                )
                Spacer(minLength: Steno.Space.s)
                if hasTranscript,
                   preflightError != nil,
                   shouldShowPreflightRetry
                {
                    Button("Try again") {
                        retryInitialLoad()
                    }
                    .controlSize(.small)
                }
            }
        }

        if let notice = externalNotice {
            reportMessage(
                notice.text,
                systemImage: "arrow.up.forward.circle",
                color: notice.isPlaintext
                    ? Steno.Colors.uncertain
                    : Color(uiColor: .secondaryLabel)
            )
        } else if let externalNoticeError {
            reportMessage(
                externalNoticeError,
                systemImage: "exclamationmark.triangle",
                color: Steno.Colors.error
            )
        }

        generationControls

        if let report = presentation.shownReport {
            reportContent(report)
        } else if presentation.isPending {
            Text("The minutes are being generated. You can leave this meeting and return later.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            Text("No minutes have been generated yet. Choose a model and generate them when the transcript is ready.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var hasCurrentIdentity: Bool {
        identity.token(for: meetingID) != nil
    }

    private var shouldShowPreflightRetry: Bool {
        presentation.hasReconciledSnapshot
            || presentation.errorMessage == nil
    }

    private var modelPicker: some View {
        Group {
            if presentation.pendingJobID != nil {
                LabeledContent("Language model", value: endpointDisplay.modelLabel)
            } else {
                Picker("Language model", selection: selectedEndpointID) {
                    Text("Apple Intelligence (on device)").tag(UUID?.none)
                    ForEach(textModels.endpoints, id: \.id) { endpoint in
                        Text("\(endpoint.name) (\(endpoint.hosting.displayName))")
                            .tag(Optional(endpoint.id))
                    }
                }
            }
        }
        .disabled(presentation.isPending)
    }

    private var selectedEndpointID: Binding<UUID?> {
        Binding(
            get: { selectedEndpointSnapshot?.id },
            set: { endpointID in
                selectedEndpointSnapshot = endpointID.flatMap { selectedID in
                    textModels.endpoints.first { $0.id == selectedID }?.snapshot
                }
                textModels.selectedEndpointID = endpointID
            }
        )
    }

    private var generationControls: some View {
        VStack(alignment: .leading, spacing: Steno.Space.s) {
            Button {
                generate()
            } label: {
                if presentation.isStarting {
                    ProgressView()
                } else {
                    Label(
                        viewState.actionTitle,
                        systemImage: "doc.badge.gearshape"
                    )
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                !viewState.canGenerate
                    || !presentation.canBeginGeneration
                    || preflight == nil
                    || externalNoticeError != nil
            )

            if presentation.pendingJobID != nil {
                HStack(spacing: Steno.Space.s) {
                    ProgressView()
                    Text("Generating minutes…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: Steno.Space.s)
                    Button("Cancel", role: .cancel) {
                        cancel()
                    }
                }
            }
        }
    }

    private func reportContent(_ report: StoredTemplateResult) -> some View {
        VStack(alignment: .leading, spacing: Steno.Space.l) {
            HStack(alignment: .firstTextBaseline, spacing: Steno.Space.s) {
                Text(provenanceLabel(report))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: Steno.Space.s)
                if presentation.reports.count > 1 {
                    versionMenu
                }
            }

            MarkdownLiteView(markdown: report.result.markdown)

            HStack(spacing: Steno.Space.l) {
                Button {
                    UIPasteboard.general.string = MeetingReportsViewState
                        .copyText(
                            for: presentation.shownReport,
                            unrecordedTracks: unrecordedTracks
                        )
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }

                if let payload = MeetingReportsViewState.sharePayload(
                    for: presentation.shownReport,
                    unrecordedTracks: unrecordedTracks
                ) {
                    Button {
                        shareDisclosure.request(
                            payload,
                            meetingID: meetingID,
                            disclosureSeen: ReportShareDisclosureStore()
                                .hasSeenDisclosure
                        )
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .frame(maxWidth: Self.readableWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, Steno.Space.xs)
    }

    private var versionMenu: some View {
        Menu {
            ForEach(presentation.reports, id: \.runID) { report in
                Button {
                    presentation.select(report.runID)
                } label: {
                    if presentation.isShownVersion(report) {
                        Label(versionLabel(report), systemImage: "checkmark")
                    } else {
                        Text(versionLabel(report))
                    }
                }
            }
        } label: {
            Label("Versions", systemImage: "clock.arrow.circlepath")
                .font(.caption)
        }
    }

    private var shareDisclosureIsPresented: Binding<Bool> {
        Binding(
            get: { shareDisclosure.isDisclosurePresented(for: meetingID) },
            set: { if !$0 { shareDisclosure.cancelDisclosure() } }
        )
    }

    private var reportShareSheetIsPresented: Binding<Bool> {
        Binding(
            get: { shareDisclosure.isSharePresented(for: meetingID) },
            set: { if !$0 { shareDisclosure.finishSharing() } }
        )
    }

    private func reportMessage(
        _ message: String,
        systemImage: String,
        color: Color
    ) -> some View {
        Label(message, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var viewState: MeetingReportsViewState {
        MeetingReportsViewState(
            hasReport: presentation.shownReport != nil,
            hasTranscript: hasTranscript,
            hasUnconfirmedSpeakers: hasUnconfirmedSpeakers,
            usesExternalEndpoint: endpointDisplay.usesExternalEndpoint,
            appleAvailability: FoundationModelsProvider().availability
        )
    }

    private var blockingMessage: String? {
        if !hasTranscript {
            return viewState.availabilityMessage.map { String(localized: $0) }
        }
        if let preflightError { return preflightError }
        return viewState.availabilityMessage.map { String(localized: $0) }
    }

    private var hasUnconfirmedSpeakers: Bool {
        review?.clusters.contains { cluster in
            if cluster.containsMultipleSpeakers { return true }
            switch cluster.reviewState {
            case .confirmed:
                return false
            case .unreviewed, .generic, .multiple, .stale:
                return !cluster.isSelf
            }
        } ?? false
    }

    private var externalNotice: LocalizedExternalModelNotice? {
        guard let snapshot = endpointDisplay.endpointSnapshot,
              let preflight
        else { return nil }
        return try? LocalizedExternalModelNotice.make(
            endpoint: TextModelEndpoint(snapshot: snapshot),
            disclosure: preflight.disclosure,
            localDeviceDescription: localDeviceDescription
        )
    }

    private var externalNoticeError: String? {
        if case .unavailableExternal = endpointDisplay {
            return String(localized: "The selected text-model endpoint is no longer available.")
        }
        guard let snapshot = endpointDisplay.endpointSnapshot,
              let preflight else { return nil }
        do {
            _ = try ExternalModelNotice(
                endpoint: TextModelEndpoint(snapshot: snapshot),
                disclosure: preflight.disclosure,
                localDeviceDescription: localDeviceDescription
            )
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private var endpointDisplay: ReportTextModelDisplay {
        ReportTextModelDisplay.resolve(
            isPending: presentation.pendingJobID != nil,
            pendingEndpointID: presentation.pendingEndpointID,
            pendingEndpointSnapshot: presentation.pendingEndpointSnapshot,
            pendingNativeGemmaModelSnapshot: presentation.pendingNativeGemmaModelSnapshot,
            selectedEndpointSnapshot: selectedEndpointSnapshot,
            configuredEndpoints: textModels.endpoints
        )
    }

    private var localDeviceDescription: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "this iPad" : "this iPhone"
    }

    private func provenanceLabel(_ report: StoredTemplateResult) -> String {
        let date = report.result.createdAt.formatted(
            date: .abbreviated,
            time: .shortened
        )
        return "\(date) · \(MeetingReportsPresentation.engineLabel(report.result.engine))"
    }

    private func versionLabel(_ report: StoredTemplateResult) -> String {
        MeetingReportsPresentation.versionLabel(report)
    }

    private func generate() {
        guard let token = identity.token(for: meetingID) else { return }
        guard presentation.beginGeneration() else { return }
        guard let preflight else {
            presentation.failedToStart("The report inputs are not ready yet.")
            return
        }
        let endpoint = selectedEndpointSnapshot
        informationMessage = nil
        Task {
            do {
                let job = try await app.requestMeetingMinutes(
                    meetingID: token.value,
                    textModelEndpointID: endpoint?.id.uuidString,
                    textModelEndpointSnapshot: endpoint,
                    preflight: preflight
                )
                guard identity.accepts(token, currentValue: meetingID) else {
                    return
                }
                presentation.accepted(job: job)
            } catch {
                guard identity.accepts(token, currentValue: meetingID) else {
                    return
                }
                presentation.failedToStart(error.localizedDescription)
                await loadPreflight(token)
            }
        }
    }

    private func cancel() {
        guard let token = identity.token(for: meetingID),
              let pendingJobID = presentation.pendingJobID
        else { return }
        Task {
            do {
                try await app.cancelReportJob(pendingJobID)
                guard identity.accepts(token, currentValue: meetingID) else {
                    return
                }
                informationMessage = nil
            } catch let error as PipelineError {
                guard identity.accepts(token, currentValue: meetingID) else {
                    return
                }
                switch error {
                case .cancellationTooLate:
                    informationMessage = "The minutes are already finishing. Steno is waiting for the saved result."
                default:
                    presentation.actionFailed(error.localizedDescription)
                }
            } catch {
                guard identity.accepts(token, currentValue: meetingID) else {
                    return
                }
                presentation.actionFailed(error.localizedDescription)
            }
            await refresh(token)
        }
    }

    private func retryInitialLoad() {
        guard let token = identity.token(for: meetingID) else { return }
        Task {
            await loadPreflight(token)
            guard !Task.isCancelled,
                  identity.accepts(token, currentValue: meetingID)
            else { return }
            await refresh(token)
        }
    }

    private func loadPreflight(
        _ token: ViewIdentityGeneration<MeetingID>.Token
    ) async {
        guard identity.accepts(token, currentValue: meetingID) else { return }
        preflight = nil
        preflightError = nil
        do {
            let loaded = try await app.reportPreflight(for: token.value)
            guard !Task.isCancelled,
                  identity.accepts(token, currentValue: meetingID)
            else { return }
            preflight = loaded
        } catch {
            guard !Task.isCancelled,
                  identity.accepts(token, currentValue: meetingID)
            else { return }
            preflightError = error.localizedDescription
        }
    }

    private func refreshLoop(
        _ token: ViewIdentityGeneration<MeetingID>.Token
    ) async {
        while !Task.isCancelled {
            await refresh(token)
            guard identity.accepts(token, currentValue: meetingID),
                  presentation.isPending
            else { return }
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
        }
    }

    private func refresh(
        _ token: ViewIdentityGeneration<MeetingID>.Token
    ) async {
        do {
            let snapshot = try await app.reportsSnapshot(for: token.value)
            guard !Task.isCancelled,
                  identity.accepts(token, currentValue: meetingID)
            else { return }
            presentation.reconcile(reports: snapshot.reports, jobs: snapshot.jobs)
            if presentation.consumePreflightRefreshRequest() {
                await loadPreflight(token)
            }
        } catch {
            guard !Task.isCancelled,
                  identity.accepts(token, currentValue: meetingID)
            else { return }
            presentation.snapshotFailed(error.localizedDescription)
        }
    }
}

private struct ReportPollingKey: Equatable {
    let meetingID: MeetingID
    let pendingJobID: JobID?
}
