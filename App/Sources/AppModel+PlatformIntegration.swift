import AppKit
import Foundation
import StenoAudioCore
import StenoMacAudio

/// UserDefaults-backed preferences for the Wave-1 platform integrations,
/// following the existing `steno.*` key style. An absent value always means
/// the documented default, mirroring how `StenoNotifications` and
/// `MeetingDetectionController` read their own gates.
enum PlatformPreferences {
    static let globalRecordHotkeyEnabledKey =
        "steno.recording.globalHotkeyEnabled"
    static let silenceAutoStopEnabledKey =
        "steno.recording.silenceAutoStop.enabled"
    static let silenceAutoStopThresholdDBKey =
        "steno.recording.silenceAutoStop.thresholdDB"
    static let silenceAutoStopIntervalSecondsKey =
        "steno.recording.silenceAutoStop.intervalSeconds"

    static let silenceAutoStopDefaultThresholdDB = -50.0
    static let silenceAutoStopDefaultIntervalSeconds = 300.0

    /// Global Cmd+Shift+R record hotkey; on unless explicitly disabled.
    static var isGlobalRecordHotkeyEnabled: Bool {
        UserDefaults.standard.object(forKey: globalRecordHotkeyEnabledKey)
            as? Bool ?? true
    }

    /// Rebuilds the silence auto-stop configuration from settings. The
    /// config itself clamps nonsensical thresholds and enforces the minimum
    /// interval, so stale values cannot break a recording run.
    static func silenceAutoStopConfig(
        defaults: UserDefaults = .standard
    ) -> SilenceAutoStopConfig {
        SilenceAutoStopConfig(
            isEnabled: defaults.object(forKey: silenceAutoStopEnabledKey)
                as? Bool ?? false,
            thresholdDBFS: defaults.object(forKey: silenceAutoStopThresholdDBKey)
                as? Double ?? silenceAutoStopDefaultThresholdDB,
            interval: defaults.object(forKey: silenceAutoStopIntervalSecondsKey)
                as? Double ?? silenceAutoStopDefaultIntervalSeconds
        )
    }
}

// MARK: - Platform integration glue
//
// Lifecycle logic for the menu bar item, the global record hotkey, deep
// links and meeting detection. The instances themselves live as stored
// properties on AppModel (extensions cannot add stored properties); keeping
// them per-model rather than process-global statics keeps previews and tests
// independent of each other.

extension AppModel {
    /// Installs every platform integration exactly once. The menu bar and
    /// hotkey route through the SAME start/stop path as Cmd+R and Cmd+.,
    /// including the `canStartRecording` guards inside `startRecording()`.
    ///
    /// `openMainWindow` is injected by the app entry point because bringing
    /// the main SwiftUI window scene forward requires its `openWindow`
    /// environment value.
    func installPlatformIntegrations(
        openMainWindow: @escaping () -> Void
    ) {
        guard menuBarController == nil else { return }

        let menuBar = MenuBarController()
        menuBar.onToggleRecording = { [weak self] in
            guard let self else { return }
            if isRecording {
                Task { await stopRecording() }
            } else {
                Task { await startRecording() }
            }
        }
        menuBar.onOpenMainWindow = openMainWindow
        menuBarController = menuBar
        menuBar.install()
        syncMenuBar()

        let hotkey = GlobalRecordHotkey { [weak self] in
            guard let self else { return }
            if isRecording {
                Task { await stopRecording() }
            } else {
                Task { await startRecording() }
            }
        }
        hotkey.setEnabled(PlatformPreferences.isGlobalRecordHotkeyEnabled)
        globalRecordHotkey = hotkey

        meetingDetectionController = MeetingDetectionController(
            postMeetingDetected: { [weak self] in
                self?.postMeetingDetectedNotification()
            },
            isRecordingProvider: { [weak self] in self?.isRecording ?? false }
        )
        resumeMeetingDetectionMonitor()
    }

    /// The controller posts synchronously; the notification center call is
    /// async, so hop onto a task. There is no real meeting yet, hence the
    /// fixed pseudo identifier (coalesces repeated episodes) and the
    /// "Meeting detected" title fallback.
    func postMeetingDetectedNotification() {
        Task {
            await StenoNotifications.shared.post(
                kind: .meetingDetected,
                meetingTitle: String(localized: "Meeting detected"),
                meetingID: "external-capture"
            )
        }
    }

    /// Pushes the current command state into the menu bar. The app entry
    /// point calls this whenever one of the flags StenoCommandState derives
    /// its enabled states from changes.
    func syncMenuBar() {
        menuBarController?.refresh(state: StenoCommandState(model: self))
    }

    /// Persists the Settings toggle and applies it to the live hotkey
    /// without requiring a relaunch.
    func setGlobalRecordHotkeyEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(
            enabled,
            forKey: PlatformPreferences.globalRecordHotkeyEnabledKey
        )
        globalRecordHotkey?.setEnabled(enabled)
    }

    // MARK: Meeting detection lifecycle

    /// Begins (or resumes) polling Core Audio for external microphone
    /// capture. Runs whenever Steno is NOT recording - that is the state in
    /// which a detection is actionable. Idempotent.
    func resumeMeetingDetectionMonitor() {
        if let monitor = microphoneActivityMonitor {
            monitor.start()
            return
        }
        let monitor = MicrophoneActivityMonitor()
        monitor.allowsBundleIdentifier = { identifier in
            MeetingDetectionAppSelection().allows(identifier)
        }
        monitor.onExternalCaptureStart = { [weak self] in
            self?.meetingDetectionController?.externalCaptureStarted()
        }
        monitor.onExternalCaptureEnd = { [weak self] in
            self?.meetingDetectionController?.externalCaptureEnded()
        }
        microphoneActivityMonitor = monitor
        monitor.start()
    }

    /// Pauses polling while Steno itself records: an episode fired during
    /// our own capture would be suppressed by the controller anyway, so
    /// there is no point paying for the poll.
    func pauseMeetingDetectionMonitor() {
        microphoneActivityMonitor?.stop()
    }

    // MARK: Deep links

    /// Routes `steno://` / `stenoai://` automation links through the same
    /// start/stop path as Cmd+R and Cmd+.; unrecognized URLs are ignored.
    func handleDeepLink(_ url: URL) {
        switch DeepLinkRouter.parse(url) {
        case .startRecording(let title):
            Task { await startRecording(title: title) }
        case .stopRecording:
            Task { await stopRecording() }
        case nil:
            break
        }
    }
}
