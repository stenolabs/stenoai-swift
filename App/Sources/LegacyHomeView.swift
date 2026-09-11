import StenoDomain
import SwiftUI

enum LegacyHomePresentation {
    static let recentLimit = 8

    static func recentMeetings(_ meetings: [Meeting]) -> [Meeting] {
        Array(
            meetings
                .sorted { $0.createdAt > $1.createdAt }
                .prefix(recentLimit)
        )
    }

    static func greetingHour(_ date: Date, calendar: Calendar = .current) -> Int {
        calendar.component(.hour, from: date)
    }
}

/// The useful no-selection destination: orient, start, and return to recent
/// work without turning the meeting list into a dashboard.
struct LegacyHomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme

    private var recentMeetings: [Meeting] {
        LegacyHomePresentation.recentMeetings(model.meetings)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                hero
                previous
            }
            .padding(.horizontal, 44)
            .padding(.top, 38)
            .padding(.bottom, 80)
            .frame(maxWidth: Steno.Layout.readingWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Steno.Surfaces.paper(colorScheme))
        .navigationTitle("Home")
    }

    private var hero: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Steno.Space.xl) {
                introduction.fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: Steno.Space.l)
                preparation(alignment: .trailing)
                    .fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: Steno.Space.l) {
                introduction
                preparation(alignment: .leading)
            }
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: Steno.Space.s) {
            greeting
                .font(Steno.Typography.homeTitle)
                .foregroundStyle(Steno.Surfaces.ink(colorScheme))
            Text("Ready when you are.")
                .font(.title3)
                .foregroundStyle(Steno.Surfaces.quietInk(colorScheme))
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func preparation(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: Steno.Space.m) {
            Text(Date.now, format: .dateTime.weekday(.wide).month(.wide).day())
                .font(.callout)
                .foregroundStyle(Steno.Surfaces.quietInk(colorScheme))
            HStack {
                Button("New note") {
                    Task { await model.createDraftMeeting() }
                }
                .disabled(!StenoCommandState(model: model).canCreateMeeting)
                newNoteButton
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    @ViewBuilder
    private var greeting: some View {
        switch LegacyHomePresentation.greetingHour(Date.now) {
        case 5..<12:
            Text("Good morning.")
        case 12..<18:
            Text("Good afternoon.")
        default:
            Text("Good evening.")
        }
    }

    private var newNoteButton: some View {
        Button {
            Task { await model.startRecording() }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "record.circle")
                    .font(.caption.weight(.semibold))
                Text("Start Recording")
                    .font(.callout.weight(.semibold))
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 8)
            .foregroundStyle(Steno.Surfaces.paper(colorScheme))
            .background(Steno.Surfaces.ink(colorScheme), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!canCreateNote)
        .opacity(canCreateNote ? 1 : 0.5)
        .help("Start a new recording")
    }

    private var canCreateNote: Bool {
        model.canStartRecording && !model.isStartingRecording
    }

    @ViewBuilder
    private var previous: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !recentMeetings.isEmpty {
                sectionLabel("Previous")
                    .padding(.bottom, Steno.Space.s)
            }
            if recentMeetings.isEmpty {
                emptyPrevious
            } else {
                ForEach(recentMeetings, id: \.id) { meeting in
                    recentRow(meeting)
                }
            }
        }
    }

    private var emptyPrevious: some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Your first note starts here")
                    .font(.headline)
                Text("Record a conversation or choose New note to create a meeting draft.")
                    .font(.callout)
                    .foregroundStyle(Steno.Surfaces.quietInk(colorScheme))
            }
        }
        .padding(.vertical, Steno.Space.l)
        .overlay(alignment: .top) {
            Divider().overlay(Steno.Surfaces.border(colorScheme))
        }
    }

    private func recentRow(_ meeting: Meeting) -> some View {
        Button {
            model.selectedMeetingID = meeting.id
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                Text(meeting.createdAt, format: .dateTime.day().month(.twoDigits).year(.twoDigits))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(Steno.Surfaces.quietInk(colorScheme))
                    .frame(width: Steno.Layout.chronologyRailWidth, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    Text(meeting.title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Text(meeting.createdAt, format: .dateTime.weekday(.abbreviated).hour().minute())
                        .font(.caption)
                        .foregroundStyle(Steno.Surfaces.quietInk(colorScheme))
                }
                Spacer(minLength: Steno.Space.m)
                if meeting.status != .ready {
                    Text(statusLabel(meeting.status))
                        .font(.caption)
                        .foregroundStyle(Steno.Surfaces.quietInk(colorScheme))
                }
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(Steno.Surfaces.quietInk(colorScheme))
            }
            .contentShape(Rectangle())
            .padding(.vertical, 13)
            .overlay(alignment: .top) {
                Divider().overlay(Steno.Surfaces.border(colorScheme))
            }
        }
        .buttonStyle(.plain)
    }

    private func sectionLabel(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .tracking(0.9)
            .foregroundStyle(Steno.Surfaces.quietInk(colorScheme))
    }

    private func statusLabel(_ status: Meeting.Status) -> LocalizedStringKey {
        switch status {
        case .draft: "Draft"
        case .recording: "Recording"
        case .interrupted: "Interrupted"
        case .processing: "Processing"
        case .ready: "Ready"
        }
    }
}
