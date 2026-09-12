import AppKit
import StenoDomain
import StenoIdentity
import StenoPipeline
import SwiftUI

/// Pure projection of app shell state into the header atop the meetings
/// column. Precedence is fixed: an active recording outruns queued jobs,
/// which outrun the idle ready state; the speaker-review count rides along
/// as a secondary row.
struct HomeStatusHeaderState: Equatable {
    enum Mode: Equatable {
        case readyToRecord
        case recording(elapsedSeconds: Int)
        case processing(jobCount: Int)
    }

    let mode: Mode
    let meetingsNeedingSpeakerReview: Int

    static func make(
        isRecording: Bool,
        recordingStartedAt: Date?,
        activeJobCount: Int,
        meetingsNeedingSpeakerReview: Int,
        now: Date
    ) -> HomeStatusHeaderState {
        let mode: Mode
        if isRecording {
            let elapsed = recordingStartedAt.map {
                now.timeIntervalSince($0)
            } ?? 0
            mode = .recording(elapsedSeconds: max(0, Int(elapsed)))
        } else if activeJobCount > 0 {
            mode = .processing(jobCount: activeJobCount)
        } else {
            mode = .readyToRecord
        }
        return HomeStatusHeaderState(
            mode: mode,
            meetingsNeedingSpeakerReview: meetingsNeedingSpeakerReview
        )
    }

    /// mm:ss with unbounded minutes; a stale (future) start date clamps to
    /// zero through `make`, so this only ever sees non-negative seconds.
    static func clockText(seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

/// A meeting needs speaker review when its persisted review still names at
/// least one confirmable cluster "Speaker N": self-clusters and merged
/// multi-speaker clusters are not nameable, matching how ReportsSection
/// counts open speakers for its minutes hint.
enum HomeStatusReviewPolicy {
    static func needsSpeakerReview(
        _ clusters: [IdentityCluster]
    ) -> Bool {
        clusters.contains { cluster in
            guard !cluster.isSelf, !cluster.containsMultipleSpeakers else {
                return false
            }
            // A generic label is itself a persistent review decision.
            // It must not resurface as an open speaker, exactly like a
            // confirmed one.
            switch cluster.reviewState {
            case .confirmed, .generic: return false
            default: return true
            }
        }
    }
}

/// Header view over the meetings column. State projection is pure; the
/// only asynchronous part is polling cheap library facts (queued/running
/// job count and per-meeting review documents). No network access.
struct HomeStatusHeader: View {
    let model: AppModel

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openWindow) private var openWindow

    @State private var activeJobCount = 0
    @State private var processingMeetingIDs: [MeetingID] = []
    @State private var reviewMeetingIDs: [MeetingID] = []

    var body: some View {
        let state = projectedState
        VStack(alignment: .leading, spacing: 0) {
            brandRow
            navigationRow
            Divider()
            statusRow(state)
            PreMeetingBriefCard()
            if !reviewMeetingIDs.isEmpty {
                Divider()
                reviewRow
            }
            Divider()
        }
        .background(Steno.Surfaces.sunkenPaper(colorScheme))
        .task { await refreshLoop() }
    }

    private var brandRow: some View {
        HStack(spacing: 9) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            Text("Steno")
                .font(Steno.Typography.wordmark)
                .foregroundStyle(Steno.Surfaces.ink(colorScheme))
            Spacer()
            MicrophoneSelectionButton()
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(Steno.Surfaces.quietInk(colorScheme))
            SettingsLink {
                Image(systemName: "gearshape")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Steno.Surfaces.quietInk(colorScheme))
            .help("Settings")
        }
        .padding(.horizontal, Steno.Space.m)
        .padding(.top, Steno.Space.m)
        .padding(.bottom, Steno.Space.s)
    }

    private var navigationRow: some View {
        HStack(spacing: Steno.Space.xs) {
            navigationButton(
                title: "Home",
                systemImage: "house",
                isSelected: model.selectedMeetingIDs.isEmpty && !model.isRecording
            ) {
                model.selectedMeetingID = nil
            }
            navigationButton(
                title: "Chat",
                systemImage: "bubble.left.and.text.bubble.right",
                isSelected: false
            ) {
                openWindow(id: "library-chat")
            }
        }
        .padding(.horizontal, Steno.Space.s)
        .padding(.bottom, Steno.Space.s)
    }

    private func navigationButton(
        title: LocalizedStringKey,
        systemImage: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.callout.weight(isSelected ? .semibold : .regular))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                .background(
                    isSelected
                        ? Steno.Surfaces.paper(colorScheme)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7)
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(Steno.Surfaces.ink(colorScheme))
    }

    private var projectedState: HomeStatusHeaderState {
        HomeStatusHeaderState.make(
            isRecording: model.isRecording,
            recordingStartedAt: model.recordingStartedAt,
            activeJobCount: activeJobCount,
            meetingsNeedingSpeakerReview: reviewMeetingIDs.count,
            now: Date()
        )
    }

    @ViewBuilder
    private func statusRow(_ state: HomeStatusHeaderState) -> some View {
        switch state.mode {
        case .readyToRecord:
            headerButton(
                title: "Ready to record",
                icon: "record.circle",
                tint: .secondary
            ) {
                Task { await model.startRecording() }
            }
        case .recording:
            // The clock ticks through TimelineView so the header updates
            // every second without re-polling any library fact.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let startedAt = model.recordingStartedAt
                let seconds = startedAt.map {
                    max(0, Int(context.date.timeIntervalSince($0)))
                } ?? 0
                headerButton(
                    title: "Recording \(HomeStatusHeaderState.clockText(seconds: seconds))",
                    icon: "stop.circle.fill",
                    tint: Steno.Colors.recording
                ) {
                    Task { await model.stopRecording() }
                }
            }
        case .processing(let jobCount):
            headerButton(
                title: jobCount == 1
                    ? "Processing 1 job"
                    : "Processing \(jobCount) jobs",
                icon: "arrow.triangle.2.circlepath",
                tint: Steno.Colors.running
            ) {
                model.selectedMeetingID = processingMeetingIDs.first
            }
        }
    }

    private var reviewRow: some View {
        headerButton(
            title: reviewMeetingIDs.count == 1
                ? "1 meeting needs speaker review"
                : "\(reviewMeetingIDs.count) meetings need speaker review",
            icon: "person.wave.2",
            tint: .secondary
        ) {
            model.selectedMeetingID = reviewMeetingIDs.first
        }
    }

    private func headerButton(
        title: LocalizedStringResource,
        icon: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Steno.Space.s) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Steno.Space.m)
        .padding(.vertical, Steno.Space.s)
        .help(Text(title))
    }

    /// Cheap facts only: one job listing plus one small review.json read
    /// per ready meeting. Refresh cadence is coarse because neither fact
    /// changes faster than the pipeline reports back anyway.
    private func refreshLoop() async {
        while !Task.isCancelled {
            await refreshCounts()
            try? await Task.sleep(for: .seconds(3))
        }
    }

    private func refreshCounts() async {
        guard let runtime = model.runtime else {
            activeJobCount = 0
            processingMeetingIDs = []
            reviewMeetingIDs = []
            return
        }
        let jobs = (try? await runtime.jobStore.list()) ?? []
        let active = jobs.filter {
            $0.status == .queued || $0.status == .running
        }
        activeJobCount = active.count
        processingMeetingIDs = Array(
            Set(active.map(\.meetingID))
        )

        let layout = runtime.library.layout
        let reviewStore = MeetingReviewStore(layout: layout)
        var needingReview: [MeetingID] = []
        for meeting in model.meetings where meeting.status == .ready {
            guard let document = try? reviewStore.load(meetingID: meeting.id)
            else { continue }
            if HomeStatusReviewPolicy.needsSpeakerReview(document.clusters) {
                needingReview.append(meeting.id)
            }
        }
        reviewMeetingIDs = needingReview
    }
}
