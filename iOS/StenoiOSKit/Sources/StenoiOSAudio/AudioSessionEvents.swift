import AVFAudio

/// Why the system took the audio session away from us.
///
/// The reason matters for what the UI says: a phone call is an interruption
/// the user understands, a muted built-in microphone is one they have to fix.
///
/// `AVAudioSessionInterruptionReasonSceneWasBackgrounded` is deliberately not
/// mapped: it is declared under `TARGET_OS_VISION` in `AVAudioSessionTypes.h`
/// and does not exist on iOS or iPadOS.
public enum AudioInterruptionReason: Equatable, Sendable {
    case other
    case builtInMicMuted
}

/// Why the input or output route changed mid-recording.
///
/// `oldDeviceUnavailable` is the case that matters most: a USB interface was
/// unplugged, so the track must end deliberately instead of silently
/// continuing on a different microphone with a different format.
public enum AudioRouteChangeReason: Equatable, Sendable {
    case newDeviceAvailable
    case oldDeviceUnavailable
    case categoryChange
    case override
    case wakeFromSleep
    case noSuitableRouteForCategory
    case routeConfigurationChange
    case unknown
}

public enum AudioSessionEvent: Equatable, Sendable {
    case interruptionBegan(AudioInterruptionReason)
    case interruptionEnded(shouldResume: Bool)
    case routeChanged(AudioRouteChangeReason)
    case mediaServicesWereReset
}

// The mappings live apart from the session actor so they can be tested without
// an audio session, the same way `AudioPermissions.microphoneStatus(from:)` is
// tested on the Mac.
extension AudioInterruptionReason {
    static func from(
        _ reason: AVAudioSession.InterruptionReason
    ) -> AudioInterruptionReason {
        switch reason {
        case .default:
            .other
        case .builtInMicMuted:
            .builtInMicMuted
        default:
            .other
        }
    }
}

extension AudioRouteChangeReason {
    static func from(
        _ reason: AVAudioSession.RouteChangeReason
    ) -> AudioRouteChangeReason {
        switch reason {
        case .newDeviceAvailable:
            .newDeviceAvailable
        case .oldDeviceUnavailable:
            .oldDeviceUnavailable
        case .categoryChange:
            .categoryChange
        case .override:
            .override
        case .wakeFromSleep:
            .wakeFromSleep
        case .noSuitableRouteForCategory:
            .noSuitableRouteForCategory
        case .routeConfigurationChange:
            .routeConfigurationChange
        case .unknown:
            .unknown
        @unknown default:
            .unknown
        }
    }

    /// Whether a running capture must stop rather than carry on.
    ///
    /// Losing the current input device invalidates the format the writer was
    /// opened with; the remaining reasons are additive or cosmetic and a
    /// capture may continue through them.
    ///
    /// `categoryChange` continues: the category belongs to this app's own
    /// session, and `beginRecording` sets it itself. The notification for that
    /// arrives while the recording is still preparing, so ending on it stopped
    /// every recording at 00:00:00. A real format change still ends the run,
    /// through the microphone source that cannot restart.
    public var endsCurrentCapture: Bool {
        switch self {
        case .oldDeviceUnavailable, .noSuitableRouteForCategory:
            true
        case .newDeviceAvailable, .categoryChange, .override, .wakeFromSleep,
             .routeConfigurationChange, .unknown:
            false
        }
    }
}
