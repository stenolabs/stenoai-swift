import AVFAudio
import Foundation
import StenoAudioCore
import StenoDomain
import StenoLibrary

extension RecordingSession {
    /// The Mac's two-track recording: microphone plus system audio.
    ///
    /// Kept as its own initializer so that callers on this platform read the
    /// same as before the split, and so that the default activity manager can
    /// stay `RecordingActivityManager` - which is macOS-only and therefore
    /// cannot be a default in the shared core.
    public init(
        meetingID: MeetingID,
        library: Library,
        outputDirectory: URL,
        microphoneSource: any AudioSource,
        systemAudioSource: any AudioSource,
        activityManager: any RecordingActivityManaging = RecordingActivityManager(),
        diagnostics: any RecordingDiagnosticsRecording = NullRecordingDiagnostics(),
        ringCapacity: Int = 64,
        diskCheckInterval: Duration = .seconds(1),
        availableDiskBytes: @escaping @Sendable (URL) throws -> Int64 = {
            try DiskSpaceChecker().availableBytes(at: $0)
        },
        writerFactory: @escaping TrackWriterFactory = {
            try TrackWriter(url: $0, sourceFormat: $1)
        }
    ) {
        precondition(microphoneSource.track == .microphone)
        precondition(systemAudioSource.track == .system)
        self.init(
            meetingID: meetingID,
            library: library,
            outputDirectory: outputDirectory,
            sources: [
                .microphone: microphoneSource,
                .system: systemAudioSource,
            ],
            // Starting the process tap may show macOS' permission dialog and
            // rebuild Core Audio's device graph. Select and bind the physical
            // microphone only after that operation has fully completed.
            sourceOrder: [.system, .microphone],
            diagnostics: diagnostics,
            activityManager: activityManager,
            ringCapacity: ringCapacity,
            diskCheckInterval: diskCheckInterval,
            availableDiskBytes: availableDiskBytes,
            writerFactory: writerFactory
        )
    }

    /// Starts the two-track recording, optionally armed with automatic
    /// silence-triggered stopping.
    ///
    /// Passing `nil` or a config with `isEnabled == false` records exactly as
    /// `start()` does. When enabled, a `SilenceAutoStopMonitor` is fed from
    /// the session's existing level metering (the per-buffer RMS/peak
    /// measurements surfaced through `levels(for:)`); once every tracked
    /// track has stayed below the threshold for the configured interval the
    /// monitor stops the session through the same `stop()` path a manual
    /// stop uses.
    ///
    /// The parameter defaults to `nil` so every existing call site keeps its
    /// behavior and compiles unchanged.
    public func start(silenceAutoStop: SilenceAutoStopConfig? = nil) async throws {
        // Deliberately off unless explicitly enabled: see
        // `SilenceAutoStopConfig` for why this diverges from stenoai's
        // default-on setting.
        guard let config = silenceAutoStop, config.isEnabled else {
            try await start()
            return
        }
        let monitor = SilenceAutoStopMonitor(config: config) { [weak self] in
            _ = try? await self?.stop()
        }
        try await start()
        Task { [weak self] in
            // Exits on its own once the session leaves `.recording`, so no
            // cancellation wiring is needed beyond the state check.
            while await self?.state == .recording {
                try? await Task.sleep(for: .milliseconds(500))
                guard await self?.state == .recording else { return }
                let levelsByTrack: [AudioTrack: AudioLevels] = [
                    .microphone: await self?.levels(for: .microphone) ?? .silence,
                    .system: await self?.levels(for: .system) ?? .silence,
                ]
                await monitor.ingest(levelsByTrack, at: .now)
            }
        }
    }
}
