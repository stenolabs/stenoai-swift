// Ported from stenoai's mic-monitor helper (mic-monitor/mic_monitor.swift).
// The legacy tool ran as a separate process that polled CoreAudio and printed
// JSON lines; here the same detection runs in-process so the app can show
// "Meeting detected" when another application starts using the microphone.

import CoreAudio
import Foundation
import os

/// Watches the default input device and reports when a process other than
/// Steno begins or ends capturing it.
///
/// Like the legacy monitor, this needs NO microphone permission: it reads the
/// CoreAudio process-object properties (`kAudioHardwarePropertyProcessObjectList`,
/// `kAudioProcessPropertyIsRunningInput`) that coreaudiod vends to any
/// process, so it sees who is capturing without ever touching audio buffers.
/// The deployment target is macOS 26, so the pre-14 device-level fallback of
/// the legacy tool is not carried over.
///
/// Transitions are debounced: a change in the capturing-pid set must persist
/// for `debounceInterval` before a callback fires, which absorbs the short
/// blips devices produce when apps probe or reconfigure input.
@MainActor
public final class MicrophoneActivityMonitor {
    /// Optional caller policy. Unknown identities can be rejected without
    /// reading audio or changing recording permissions.
    public var allowsBundleIdentifier: ((String?) -> Bool)?
    /// Invoked on the main actor once per episode, when external capture starts.
    public var onExternalCaptureStart: (() -> Void)?

    /// Invoked on the main actor once per episode, when external capture ends.
    public var onExternalCaptureEnd: (() -> Void)?

    private let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier
    private var pollTask: Task<Void, Never>?

    public init() {}

    /// Begins polling. Repeated calls while running are ignored; pair with
    /// `stop()` to re-arm.
    public func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            var decision = CaptureEpisodeDecider(
                debounceInterval: MicrophoneActivityMonitor.debounceInterval
            )
            while !Task.isCancelled, let self {
                let capturingPIDs = MicrophoneActivityMonitor.eligibleCapturePIDs(
                    MicrophoneActivityMonitor.sampleCapturingProcesses(),
                    allowing: self.allowsBundleIdentifier
                )
                let transition = decision.update(
                    rawCapturingPIDs: capturingPIDs,
                    excluding: self.ownProcessIdentifier,
                    at: MicrophoneActivityMonitor.monotonicSeconds()
                )
                switch transition {
                case .episodeStarted:
                    Self.log.info("External microphone capture started")
                    self.onExternalCaptureStart?()
                case .episodeEnded:
                    Self.log.info("External microphone capture ended")
                    self.onExternalCaptureEnd?()
                case .noChange:
                    break
                }
                try? await Task.sleep(for: .seconds(MicrophoneActivityMonitor.pollInterval))
            }
        }
    }

    /// Stops polling. Any pending debounced transition is discarded.
    public func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Sampling

    /// Every pid whose CoreAudio process object reports active input capture,
    /// including Steno's own. Mirrors `processObjectsCapturingInput()` from
    /// the legacy monitor.
    struct CapturingProcess: Sendable {
        let pid: pid_t
        let bundleIdentifier: String?
    }

    nonisolated static func eligibleCapturePIDs(
        _ captures: [CapturingProcess],
        allowing policy: ((String?) -> Bool)?
    ) -> Set<pid_t> {
        Set(captures.filter { policy?($0.bundleIdentifier) ?? true }.map(\.pid))
    }

    nonisolated static func sampleCapturingProcesses() -> [CapturingProcess] {
        var listAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &size
        ) == noErr else {
            Self.log.error("Could not read CoreAudio process object list size")
            return []
        }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var processes = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &size, &processes
        ) == noErr else {
            Self.log.error("Could not read CoreAudio process object list")
            return []
        }

        var isRunningInputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var bundleAddress = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var captures: [CapturingProcess] = []
        for process in processes {
            var isRunningInput: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(
                process, &isRunningInputAddress, 0, nil, &runningSize, &isRunningInput
            ) == noErr, isRunningInput != 0
            else { continue }

            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            if AudioObjectGetPropertyData(process, &pidAddress, 0, nil, &pidSize, &pid) == noErr {
                var bundle: CFString?
                var bundleSize = UInt32(MemoryLayout<CFString?>.size)
                let status = withUnsafeMutablePointer(to: &bundle) {
                    AudioObjectGetPropertyData(process, &bundleAddress, 0, nil, &bundleSize, $0)
                }
                captures.append(CapturingProcess(
                    pid: pid,
                    bundleIdentifier: status == noErr ? bundle as String? : nil
                ))
            }
        }
        return captures
    }

    nonisolated private static func monotonicSeconds() -> TimeInterval {
        // Monotonic so a wall-clock jump cannot distort the debounce window.
        TimeInterval(DispatchTime.now().uptimeNanoseconds) * 1e-9
    }

    private static let pollInterval: TimeInterval = 1.0
    private static let debounceInterval: TimeInterval = 2.0

    nonisolated private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.steno",
        category: "microphone-activity"
    )
}

/// Pure decision logic behind `MicrophoneActivityMonitor`: turns successive
/// observations of the capturing-pid set into debounced episode transitions.
///
/// Steno's own pid is filtered here (not during sampling) so the rule stays
/// unit-testable without a live CoreAudio session. An episode spans from the
/// first debounced moment at least one foreign pid captures until the first
/// debounced moment none do; the decider then re-arms automatically.
struct CaptureEpisodeDecider: Sendable {
    enum Transition: Equatable {
        case episodeStarted
        case episodeEnded
        case noChange
    }

    enum Phase: Equatable {
        case idle
        case active
    }

    private(set) var phase: Phase = .idle
    private let debounceInterval: TimeInterval
    private var pending: (phase: Phase, since: TimeInterval)?

    init(debounceInterval: TimeInterval) {
        self.debounceInterval = debounceInterval
    }

    /// Feeds one observation. `rawCapturingPIDs` may include Steno's own pid;
    /// `excludedPID` is removed before the episode decision.
    mutating func update(
        rawCapturingPIDs: Set<pid_t>,
        excluding excludedPID: pid_t?,
        at now: TimeInterval
    ) -> Transition {
        var externalPIDs = rawCapturingPIDs
        if let excludedPID { externalPIDs.remove(excludedPID) }
        let observed: Phase = externalPIDs.isEmpty ? .idle : .active

        if observed == phase {
            pending = nil
            return .noChange
        }
        if let candidate = pending, candidate.phase == observed {
            if now - candidate.since >= debounceInterval {
                phase = observed
                pending = nil
                return observed == .active ? .episodeStarted : .episodeEnded
            }
            return .noChange
        }
        pending = (observed, now)
        return .noChange
    }
}
