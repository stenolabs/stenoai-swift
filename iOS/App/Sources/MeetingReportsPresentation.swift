import Foundation
import StenoDomain
import StenoIntelligence
import StenoPipeline

struct MeetingReportsPresentation: Equatable {
    var reports: [StoredTemplateResult] = []
    var selectedRunID: RunID?
    var pendingJobID: JobID?
    private(set) var pendingEndpointSnapshot: TextModelEndpointSnapshot?
    private(set) var pendingEndpointID: String?
    private(set) var pendingNativeGemmaModelSnapshot: NativeGemmaModelSnapshot?
    var isStarting = false
    var errorMessage: String?
    private(set) var needsPreflightRefresh = false
    private(set) var hasReconciledSnapshot = false
    private var selectionWasManual = false
    private var snapshotFailureIsCurrent = false
    private let failureLedger: TemplateRenderPinsFailureObservationLedger

    init(
        reports: [StoredTemplateResult] = [],
        failureLedger: TemplateRenderPinsFailureObservationLedger = .process
    ) {
        self.reports = reports
        self.failureLedger = failureLedger
    }

    var shownReport: StoredTemplateResult? {
        selectedRunID.flatMap { selected in
            reports.first { $0.runID == selected }
        } ?? reports.first
    }

    var isPending: Bool {
        isStarting || pendingJobID != nil
    }

    var canBeginGeneration: Bool {
        hasReconciledSnapshot && !isPending
    }

    mutating func beginGeneration() -> Bool {
        guard canBeginGeneration else { return false }
        isStarting = true
        errorMessage = nil
        needsPreflightRefresh = false
        snapshotFailureIsCurrent = false
        return true
    }

    mutating func accepted(job: Job) {
        isStarting = false
        pendingJobID = job.id
        pendingEndpointSnapshot = job.textModelEndpointSnapshot
        pendingEndpointID = job.textModelEndpointID
        pendingNativeGemmaModelSnapshot = job.nativeGemmaModelSnapshot
        errorMessage = nil
        needsPreflightRefresh = false
        snapshotFailureIsCurrent = false
        selectionWasManual = false
    }

    mutating func failedToStart(_ message: String) {
        isStarting = false
        pendingJobID = nil
        pendingEndpointSnapshot = nil
        pendingEndpointID = nil
        pendingNativeGemmaModelSnapshot = nil
        errorMessage = message
        needsPreflightRefresh = false
        snapshotFailureIsCurrent = false
    }

    mutating func snapshotFailed(_ message: String) {
        errorMessage = message
        needsPreflightRefresh = false
        snapshotFailureIsCurrent = true
    }

    mutating func actionFailed(_ message: String) {
        errorMessage = message
        needsPreflightRefresh = false
        snapshotFailureIsCurrent = false
    }

    mutating func reconcile(
        reports newReports: [StoredTemplateResult],
        jobs: [Job]
    ) {
        let isInitialSnapshot = !hasReconciledSnapshot
        hasReconciledSnapshot = true
        if snapshotFailureIsCurrent {
            errorMessage = nil
            snapshotFailureIsCurrent = false
        }
        reports = newReports
        if let selectedRunID,
           !reports.contains(where: { $0.runID == selectedRunID }) {
            self.selectedRunID = reports.first?.runID
            selectionWasManual = false
        }

        adoptActiveJobIfAvailable(in: jobs)

        if isInitialSnapshot,
           pendingJobID == nil,
           let failed = failureLedger.claimLatestFailure(in: jobs) {
            errorMessage = failed.errorMessage
                ?? "Generate the minutes again to confirm the current inputs."
            needsPreflightRefresh = true
            snapshotFailureIsCurrent = false
        }

        guard let pendingJobID,
              let pending = jobs.first(where: { $0.id == pendingJobID })
        else {
            return
        }
        pendingEndpointSnapshot = pending.textModelEndpointSnapshot
        pendingEndpointID = pending.textModelEndpointID
        pendingNativeGemmaModelSnapshot = pending.nativeGemmaModelSnapshot
        let expectedRunID = PipelineRunIdentity.runID(for: pending)

        switch pending.status {
        case .queued, .running:
            break
        case .finished:
            errorMessage = nil
            needsPreflightRefresh = false
            snapshotFailureIsCurrent = false
            if reports.contains(where: { $0.runID == expectedRunID }) {
                if !selectionWasManual {
                    selectedRunID = expectedRunID
                }
                self.pendingJobID = nil
                pendingEndpointSnapshot = nil
                pendingEndpointID = nil
                pendingNativeGemmaModelSnapshot = nil
            } else {
                self.pendingJobID = nil
                pendingEndpointSnapshot = nil
                pendingEndpointID = nil
                pendingNativeGemmaModelSnapshot = nil
                errorMessage = "The minutes finished without a readable result."
            }
        case .failed:
            self.pendingJobID = nil
            pendingEndpointSnapshot = nil
            pendingEndpointID = nil
            pendingNativeGemmaModelSnapshot = nil
            errorMessage = pending.errorMessage
                ?? "The minutes could not be generated."
            needsPreflightRefresh = pending.failureReason == .templateRenderInputChanged
                || pending.failureReason == .templateRenderPinsRequired
                || pending.failureReason == .textModelEndpointConfigurationIncomplete
            snapshotFailureIsCurrent = false
        case .cancelled:
            self.pendingJobID = nil
            pendingEndpointSnapshot = nil
            pendingEndpointID = nil
            pendingNativeGemmaModelSnapshot = nil
            errorMessage = nil
            needsPreflightRefresh = false
            snapshotFailureIsCurrent = false
        }
        adoptActiveJobIfAvailable(in: jobs)
    }

    mutating func select(_ runID: RunID) {
        guard reports.contains(where: { $0.runID == runID }) else { return }
        selectedRunID = runID
        selectionWasManual = true
    }

    mutating func consumePreflightRefreshRequest() -> Bool {
        let requested = needsPreflightRefresh
        needsPreflightRefresh = false
        return requested
    }

    private mutating func adoptActiveJobIfAvailable(in jobs: [Job]) {
        guard pendingJobID == nil,
              let active = jobs.first(where: {
                  $0.kind == .templateRender
                      && ($0.status == .queued || $0.status == .running)
              }) else { return }
        pendingJobID = active.id
        pendingEndpointSnapshot = active.textModelEndpointSnapshot
        pendingEndpointID = active.textModelEndpointID
        pendingNativeGemmaModelSnapshot = active.nativeGemmaModelSnapshot
        selectionWasManual = false
    }

    static func engineLabel(
        _ engine: EngineDescriptor,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let name = DemoDisplayLocalization.engineName(engine.name, locale: locale)
        if let modelVersion = engine.modelVersion {
            return "\(name) · \(modelVersion)"
        }
        return name
    }

    static func versionLabel(
        _ report: StoredTemplateResult,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return "\(formatter.string(from: report.result.createdAt)) · "
            + engineLabel(report.result.engine, locale: locale)
    }

    func isShownVersion(_ report: StoredTemplateResult) -> Bool {
        shownReport?.runID == report.runID
    }
}

struct MeetingReportsAvailabilityPresentation: Equatable {
    let canGenerate: Bool
    let message: LocalizedStringResource?

    init(_ availability: TextModelAvailability) {
        switch availability {
        case .available:
            canGenerate = true
            message = nil
        case .unavailable:
            canGenerate = false
            message = Self.message(for: availability)
        }
    }

    private static func message(
        for availability: TextModelAvailability
    ) -> LocalizedStringResource? {
        switch availability {
        case .available:
            nil
        case .unavailable(.deviceNotEligible):
            "This device does not support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled):
            "Apple Intelligence is not enabled."
        case .unavailable(.modelNotReady):
            "The Apple Intelligence model is not available yet."
        case .unavailable(.unknown):
            "The text model is currently unavailable."
        }
    }
}

struct ReportSharePayload: Equatable {
    let text: String

    init(text: String) {
        self.text = text
    }

    init(report: StoredTemplateResult) {
        text = report.result.markdown
    }
}

struct MeetingReportsViewState: Equatable {
    let actionTitle: LocalizedStringResource
    let canGenerate: Bool
    let availabilityMessage: LocalizedStringResource?
    let speakerHint: LocalizedStringResource?

    init(
        hasReport: Bool,
        hasTranscript: Bool,
        hasUnconfirmedSpeakers: Bool,
        usesExternalEndpoint: Bool,
        appleAvailability: TextModelAvailability
    ) {
        actionTitle = Self.actionTitle(hasReport: hasReport)
        speakerHint = hasUnconfirmedSpeakers
            ? "Some speakers are still unconfirmed. Minutes use generic speaker labels until you confirm them."
            : nil

        if !hasTranscript {
            canGenerate = false
            availabilityMessage = "A transcript is required before minutes can be generated."
        } else if usesExternalEndpoint {
            canGenerate = true
            availabilityMessage = nil
        } else {
            let availability = MeetingReportsAvailabilityPresentation(
                appleAvailability
            )
            canGenerate = availability.canGenerate
            availabilityMessage = availability.message
        }
    }

    static func actionTitle(hasReport: Bool) -> LocalizedStringResource {
        hasReport ? "Regenerate" : "Generate minutes"
    }

    /// The minutes as text for the clipboard.
    ///
    /// Carries the incompleteness note when a track is missing: the label on
    /// screen does not travel with copied text, and minutes that leave out one
    /// side of a conversation must not read like complete ones.
    static func copyText(
        for report: StoredTemplateResult?,
        unrecordedTracks: [MediaAsset.Kind] = []
    ) -> String? {
        guard let report else { return nil }
        guard let note = MeetingMarkdown.incompleteRecordingNote(
            unrecordedTracks
        ) else {
            return report.result.markdown
        }
        return "\(note)\n\n\(report.result.markdown)"
    }

    static func sharePayload(
        for report: StoredTemplateResult?,
        unrecordedTracks: [MediaAsset.Kind] = []
    ) -> ReportSharePayload? {
        guard let text = copyText(
            for: report,
            unrecordedTracks: unrecordedTracks
        ) else { return nil }
        return ReportSharePayload(text: text)
    }
}
