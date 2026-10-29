import Observation
import StenoDomain
import StenoLibrary
import SwiftUI

/// Rendering has no lifecycle effects; the meeting detail owns the state lifetime.
struct MeetingAudioPlaybackSection: View {
    @Environment(AppModel.self) private var app
    @Bindable var state: MeetingAudioPlaybackState

    private var isCurrentSource: Bool { state.isCurrentSource(app: app) }
    private var duration: TimeInterval { state.duration(app: app) }
    private var position: TimeInterval { state.position(app: app) }

    var body: some View {
        Group {
            if !state.sources.isEmpty || state.loadError != nil || state.isLoading {
                Section("Original recording") {
                    if state.sources.count > 1 {
                        Picker("Recording", selection: Binding(get: { state.selectedID }, set: { state.select($0, app: app) })) {
                            Text("Choose recording").tag(nil as MediaAssetID?)
                            ForEach(Array(state.sources.enumerated()), id: \.element.id) { index, source in
                                Text("\(title(for: source.asset.kind)) \(index + 1)")
                                    .tag(Optional(source.id))
                            }
                        }
                    }
                    if let selectedSource = state.selectedSource {
                        controls(for: selectedSource)
                    } else if state.isLoading {
                        ProgressView()
                    }
                    if let error = state.loadError ?? app.audioPlayback.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if state.loadError != nil {
                        Button("Reload audio") {
                            let request = state.generation
                            Task { await state.reload(app: app, request: request) }
                        }
                    }
                    if app.recording.isActive, !state.sources.isEmpty {
                        Text("Playback is unavailable during a recording.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func controls(for source: MeetingAudioSource) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    let request = state.generation
                    Task { await state.toggle(source, app: app, request: request) }
                } label: {
                    Label(
                        isCurrentSource && app.audioPlayback.isPlaying
                            ? String(localized: "Pause") : String(localized: "Play"),
                        systemImage: isCurrentSource && app.audioPlayback.isPlaying
                            ? "pause.fill" : "play.fill"
                    )
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("meeting-audio-play-pause")
                .disabled(app.recording.isActive || app.audioPlayback.isBusy
                    || app.libraryActionIsInFlight)

                Slider(
                    value: Binding(get: { position }, set: { app.audioPlayback.seek(to: $0) }),
                    in: 0...max(1, duration)
                )
                .disabled(!isCurrentSource || app.recording.isActive || app.audioPlayback.isBusy)
                .accessibilityLabel("Playback position")
                .accessibilityValue(
                    RecordingAccessibilityPresentation.durationValue(for: position, locale: .current)
                )
                .accessibilityIdentifier("meeting-audio-position")
            }
            HStack {
                Text(durationText(position))
                Spacer()
                Text(durationText(duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Playback duration")
            .accessibilityValue(
                RecordingAccessibilityPresentation.durationValue(for: duration, locale: .current)
            )
        }
        .accessibilityIdentifier("meeting-audio-player")
    }

    private func title(for kind: MediaAsset.Kind) -> String {
        switch kind {
        case .micTrack: String(localized: "Microphone")
        case .systemTrack: String(localized: "System audio")
        case .imported: String(localized: "Imported audio")
        }
    }

}

@MainActor
@Observable
final class MeetingAudioPlaybackState {
    private(set) var sources: [MeetingAudioSource] = []
    private var sourceURLs: [MediaAssetID: URL] = [:]
    private(set) var selectedID: MediaAssetID?
    private(set) var loadError: String?
    private(set) var isLoading = false
    private(set) var generation: UInt64 = 0
    private var meetingID: MeetingID?
    private let loader: @MainActor (Library, MeetingID) async throws -> [MeetingAudioSource]

    init(loader: @escaping @MainActor (Library, MeetingID) async throws -> [MeetingAudioSource] = {
        try await MeetingAudioSource.load(in: $0, meetingID: $1)
    }) {
        self.loader = loader
    }

    var selectedSource: MeetingAudioSource? { sources.first { $0.id == selectedID } }

    func isCurrentSource(app: AppModel) -> Bool {
        guard let selectedID, let url = sourceURLs[selectedID] else { return false }
        return app.audioPlayback.sourceURL == url
    }

    func duration(app: AppModel) -> TimeInterval {
        if isCurrentSource(app: app) { return app.audioPlayback.duration }
        let value = selectedSource?.asset.duration ?? 0
        return value.isFinite ? max(0, value) : 0
    }

    func position(app: AppModel) -> TimeInterval {
        let value = isCurrentSource(app: app) ? app.audioPlayback.currentTime : 0
        return value.isFinite ? min(max(0, value), duration(app: app)) : 0
    }

    func select(_ id: MediaAssetID?, app: AppModel) {
        guard selectedID != id else { return }
        generation &+= 1
        stopCurrentSource(app: app)
        selectedID = id
        app.audioPlayback.clearError()
    }

    func leave(app: AppModel) {
        generation &+= 1
        stopCurrentSource(app: app)
        app.audioPlayback.clearError()
        meetingID = nil
        sources = []
        sourceURLs = [:]
        selectedID = nil
        loadError = nil
        isLoading = false
    }

    func reload(app: AppModel, request: UInt64) async {
        guard generation == request, let meetingID else { return }
        await load(app: app, meetingID: meetingID)
    }

    func load(app: AppModel, meetingID: MeetingID) async {
        leave(app: app)
        self.meetingID = meetingID
        let request = generation
        guard let snapshot = app.runtimeSnapshot() else { return }
        isLoading = true
        defer { if generation == request { isLoading = false } }
        do {
            let loaded = try await loader(snapshot.runtime.library, meetingID)
            guard !Task.isCancelled, generation == request,
                  app.runtime?.library === snapshot.runtime.library else { return }
            let urls = try Dictionary(uniqueKeysWithValues: loaded.map {
                ($0.id, try $0.validatedURL())
            })
            sourceURLs = urls
            sources = loaded
            if loaded.count == 1 { selectedID = loaded[0].id }
        } catch {
            guard !Task.isCancelled, generation == request,
                  app.runtime?.library === snapshot.runtime.library else { return }
            loadError = String(localized: "The saved audio could not be opened.")
        }
    }

    func toggle(_ source: MeetingAudioSource, app: AppModel, request: UInt64) async {
        guard generation == request, !Task.isCancelled,
              selectedID == source.id, !app.recording.isActive,
              !app.libraryActionIsInFlight else { return }
        do {
            let url = try source.validatedURL()
            sourceURLs[source.id] = url
            loadError = nil
            await app.audioPlayback.togglePlayback(url: url)
        } catch {
            stopCurrentSource(app: app)
            loadError = String(localized: "The saved audio could not be opened.")
        }
    }

    private func stopCurrentSource(app: AppModel) {
        if let url = app.audioPlayback.sourceURL, sourceURLs.values.contains(url) {
            app.audioPlayback.stop()
        }
    }
}
