import StenoDomain
import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var app
    let router: NavigationRouter
    @State private var durations: [MeetingID: TimeInterval] = [:]

    private var recent: [Meeting] {
        Array(app.meetings.sorted { $0.createdAt > $1.createdAt }.prefix(8))
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    greeting.font(.largeTitle.bold())
                    Text(Date.now, format: .dateTime.weekday(.wide).month(.wide).day())
                        .foregroundStyle(.secondary)
                    Text("Ready when you are.")
                    Button("Start Recording", systemImage: "record.circle") {
                        Task {
                            if await app.startRecording() { router.select(.recording) }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!app.canStartRecording)
                    Button("New note", systemImage: "square.and.pencil") {
                        Task {
                            if let id = await app.createDraftMeeting() { router.select(.meeting(id)) }
                        }
                    }
                    .disabled(!app.isReady || app.libraryActionIsInFlight)
                }
                .padding(.vertical, 8)
            }
            Section("Previous") {
                if recent.isEmpty {
                    Text("Recordings and imports appear here.").foregroundStyle(.secondary)
                }
                ForEach(recent, id: \.id) { meeting in
                    Button { router.select(.meeting(meeting.id)) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(meeting.title).font(.headline).foregroundStyle(.primary).lineLimit(2)
                            ViewThatFits(in: .horizontal) {
                                HStack {
                                    date(meeting)
                                    if let duration = durations[meeting.id] { durationLabel(duration) }
                                }
                                VStack(alignment: .leading) {
                                    date(meeting)
                                    if let duration = durations[meeting.id] { durationLabel(duration) }
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .navigationTitle("Home")
        .task(id: recent) {
            var loaded: [MeetingID: TimeInterval] = [:]
            for meeting in recent {
                guard !Task.isCancelled else { return }
                if let duration = await app.duration(for: meeting.id), duration.isFinite, duration > 0 {
                    loaded[meeting.id] = duration
                }
            }
            guard !Task.isCancelled else { return }
            durations = loaded
        }
    }

    private func date(_ meeting: Meeting) -> some View {
        Text(meeting.createdAt, format: .dateTime.day().month().year().hour().minute())
    }

    private func durationLabel(_ duration: TimeInterval) -> some View {
        Label(Duration.seconds(duration).formatted(.time(pattern: .hourMinuteSecond)), systemImage: "clock")
    }

    @ViewBuilder private var greeting: some View {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: Text("Good morning.")
        case 12..<18: Text("Good afternoon.")
        default: Text("Good evening.")
        }
    }
}
