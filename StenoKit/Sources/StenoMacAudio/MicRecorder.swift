@preconcurrency import AVFAudio
@preconcurrency import AudioToolbox
@preconcurrency import CoreAudio
import Dispatch
import Foundation
import OSLog
import StenoAudioCore
import StenoDomain

public actor MicRecorder: AudioSource {
    public nonisolated let track: AudioTrack = .microphone

    private let listenerQueue = DispatchQueue(
        label: "org.steno.microphone-device-listener",
        qos: .userInitiated
    )
    /// Resolves which microphone to bind, asked again on every attempt.
    ///
    /// Not a fixed identifier: a recording is usually started before joining
    /// the call, and the automatic choice looks for the microphone a meeting
    /// app is using. Pinning the answer at construction time made that choice
    /// permanent, so a recording started one moment too early could never get
    /// its microphone - not even when the call started seconds later.
    private let resolveDeviceUID: @Sendable () async -> String?
    private var selectedDeviceUID: String = ""
    private let stabilityPolicy: MicrophoneStabilityPolicy
    private let listDevices: @Sendable () -> [CoreAudioInputDevice]
    private let diagnostics: any RecordingDiagnosticsRecording
    private let stabilityTimeline: any StabilityTimeline
    private var preparedEngine = PreparedMicEngineState()
    private var activeCapture: MicEngineCapture?
    private var format: AVAudioFormat?
    private var pinnedDevice: PinnedInputDeviceState?
    private var liveness: InputLivenessState?
    private var bufferHandler: AudioBufferHandler?
    private var availabilityReporter: SourceAvailabilityReporter?
    private var isRunning = false
    private var rebuildState = MicRebuildState()
    private var lastRebuildAttempt: ContinuousClock.Instant?
    private var reconnectAttempt = ReconnectAttemptState()
    private var captureGeneration = MicCaptureGenerationState()
    private var operationState = MicRecorderOperationState()
    private var rebuildTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var deviceListListener: AudioObjectPropertyListenerBlock?
    private static let logger = Logger(
        subsystem: "org.steno.Steno",
        category: "MicrophoneCapture"
    )

    public init(
        resolveDeviceUID: @escaping @Sendable () async -> String?,
        diagnostics: any RecordingDiagnosticsRecording = NullRecordingDiagnostics()
    ) {
        self.resolveDeviceUID = resolveDeviceUID
        stabilityPolicy = .standard
        listDevices = { (try? CoreAudioInputDevice.availableDevices()) ?? [] }
        self.diagnostics = diagnostics
        stabilityTimeline = RealStabilityTimeline()
    }

    /// Injects the device list and the waiting policy so the start path can be
    /// exercised without real Core Audio hardware.
    init(
        resolveDeviceUID: @escaping @Sendable () async -> String?,
        stabilityPolicy: MicrophoneStabilityPolicy,
        listDevices: @escaping @Sendable () -> [CoreAudioInputDevice],
        diagnostics: any RecordingDiagnosticsRecording,
        timeline: any StabilityTimeline = RealStabilityTimeline()
    ) {
        self.resolveDeviceUID = resolveDeviceUID
        self.stabilityPolicy = stabilityPolicy
        self.listDevices = listDevices
        self.diagnostics = diagnostics
        stabilityTimeline = timeline
    }

    public func prepare() async throws -> AVAudioFormat {
        guard !isRunning, !operationState.isBusy else {
            throw AudioRecordingError.alreadyRecording
        }
        cleanup(resetFormat: true)
        guard let operationID = operationState.beginPreparation() else {
            throw AudioRecordingError.alreadyRecording
        }
        var capture: MicEngineCapture?
        do {
            // Asked again every time, so a microphone that appears later can
            // still join the recording that is already running.
            guard let uid = await resolveDeviceUID() else {
                throw AudioRecordingError.audioSourceUnavailable(
                    "no microphone is available yet"
                )
            }
            selectedDeviceUID = uid
            let device = try await stableSelectedInput(uid: uid)
            let preparedCapture = makeCapture(announcesRecovery: false)
            capture = preparedCapture
            activeCapture = preparedCapture
            let generation = captureGeneration.advance()
            let nativeFormat = try await preparedCapture.prepare(
                deviceID: device.id
            )
            guard operationState.finishPreparation(operationID),
                  captureGeneration.isCurrent(generation),
                  activeCapture === preparedCapture else {
                throw AudioRecordingError.audioSourceUnavailable(
                    "microphone setup was superseded"
                )
            }
            _ = preparedEngine.prepare(deviceID: device.id) { _ in nativeFormat }
            // How long binding the device actually took. This is the number
            // that decided between a recording and a lost microphone track:
            // through AVAudioEngine it was over 3000 ms on a device another app
            // was holding, because reaching the input node opened the default
            // device first.
            diagnostics.record(RecordingDiagnosticEvent(
                name: "microphone-bound",
                details: [
                    "uid": selectedDeviceUID,
                    "deviceID": "\(device.id)",
                    "sampleRate": "\(Int(nativeFormat.sampleRate))",
                    "bindMilliseconds":
                        "\(preparedCapture.lastPhaseDuration.wholeMilliseconds)",
                ]
            ))
            format = nativeFormat
            pinnedDevice = PinnedInputDeviceState(device: device)
            liveness = InputLivenessState(startedAt: .now)
            return nativeFormat
        } catch {
            if operationState.finishPreparation(operationID) {
                if let capture, activeCapture === capture {
                    retireActiveCapture()
                }
                preparedEngine.clear()
            }
            throw error
        }
    }

    private func stableSelectedInput(
        uid: String
    ) async throws -> CoreAudioInputDevice {
        let outcome = await MicrophoneStability.awaitStableInput(
            uid: uid,
            window: stabilityPolicy.window,
            deadline: stabilityPolicy.deadline,
            pollInterval: stabilityPolicy.pollInterval,
            listDevices: listDevices,
            timeline: stabilityTimeline
        )
        switch outcome {
        case let .stable(device, waited):
            diagnostics.record(RecordingDiagnosticEvent(
                name: "microphone-settled",
                details: [
                    "uid": uid,
                    "deviceID": "\(device.id)",
                    "waitedMilliseconds": "\(waited.wholeMilliseconds)",
                ]
            ))
            return device

        case let .unstable(trace, observedDevices):
            // The notice on screen is gone as soon as it is read, so the one
            // thing that explains a failed start - what Core Audio actually
            // reported while waiting - is written down here.
            diagnostics.record(RecordingDiagnosticEvent(
                name: "microphone-not-stable",
                details: [
                    "uid": uid,
                    "waitedMilliseconds":
                        "\(stabilityPolicy.deadline.wholeMilliseconds)",
                    "trace": trace.summary,
                    "devicesSeen": observedDevices.joined(separator: "; "),
                ]
            ))
            // Written through immediately: this entry only matters when the
            // recording it belongs to is already failing.
            diagnostics.flush()
            Self.logger.error(
                """
                Microphone \(uid, privacy: .public) never settled within \
                \(self.stabilityPolicy.deadline.wholeMilliseconds, privacy: .public) ms: \
                \(trace.summary, privacy: .public)
                """
            )
            throw AudioRecordingError.audioSourceUnavailable(
                "the microphone selected before audio setup is not stable"
            )
        }
    }

    public func start(
        bufferHandler: @escaping AudioBufferHandler
    ) async throws {
        try await start(bufferHandler: bufferHandler, eventHandler: { _ in })
    }

    public func start(
        bufferHandler: @escaping AudioBufferHandler,
        eventHandler: @escaping AudioSourceEventHandler
    ) async throws {
        guard !isRunning, !operationState.isBusy else {
            throw AudioRecordingError.alreadyRecording
        }
        if format == nil || pinnedDevice == nil {
            _ = try await prepare()
        }
        guard let fixedFormat = format,
              let deviceID = pinnedDevice?.currentDeviceID,
              let deviceUID = pinnedDevice?.pinnedUID,
              let capture = activeCapture else {
            throw AudioRecordingError.audioSourceUnavailable(
                "the selected microphone is no longer available"
            )
        }
        guard operationState.beginStart(captureID: capture.retirementID) else {
            throw AudioRecordingError.alreadyRecording
        }

        self.bufferHandler = bufferHandler
        availabilityReporter = SourceAvailabilityReporter(
            deviceName: pinnedDevice?.deviceName,
            handler: eventHandler
        )
        do {
            let nativeFormat = try preparedEngine.nativeFormatForStart(
                deviceID: deviceID
            )
            try await capture.start(
                nativeFormat: nativeFormat,
                fixedFormat: fixedFormat,
                expectedDeviceID: deviceID,
                expectedDeviceUID: deviceUID,
                bufferHandler: bufferHandler,
                availabilityReporter: availabilityReporter,
                configurationChanged: { [weak self] captureID, change in
                    Task {
                        await self?.engineConfigurationDidChange(
                            captureID,
                            change: change
                        )
                    }
                },
                bufferReceived: { [weak self] captureID in
                    Task {
                        await self?.didReceiveBuffer(
                            from: captureID,
                            at: .now
                        )
                    }
                }
            )
            guard activeCapture === capture else {
                throw AudioRecordingError.audioSourceUnavailable(
                    "microphone start was superseded"
                )
            }
            guard operationState.finishStart(
                captureID: capture.retirementID
            ) else {
                throw AudioRecordingError.audioSourceUnavailable(
                    "microphone start was superseded"
                )
            }
            isRunning = true
            installDeviceListeners()
            liveness?.begin(at: .now)
            startWatchdog()
        } catch {
            if operationState.finishStart(captureID: capture.retirementID) {
                cleanup(resetFormat: true)
            }
            throw error
        }
    }

    public func stop() {
        cleanup(resetFormat: true)
    }

    private func engineConfigurationDidChange(
        _ captureID: UUID,
        change: InputCaptureConfigurationChange
    ) async {
        guard let capture = activeCapture,
              capture.retirementID == captureID else { return }
        switch change {
        case .ignore:
            return
        case let .validate(epoch):
            availabilityReporter?.reportUnavailable()
            liveness?.markUnavailable(at: .now)
            let isValid = await capture.canResumeAfterConfigurationChange(
                expectedDeviceID: pinnedDevice?.currentDeviceID,
                expectedDeviceUID: pinnedDevice?.pinnedUID
            )
            guard activeCapture === capture else { return }
            guard isValid else {
                guard capture.retireSuspension(
                    configurationEpoch: epoch
                ) else { return }
                handleInvalidConfiguration(for: capture, at: .now)
                return
            }
            guard capture.resumeGate(configurationEpoch: epoch) else { return }
            liveness?.begin(at: .now)
            startConfigurationResumeWatchdog(
                captureID: captureID,
                configurationEpoch: epoch
            )
        }
    }

    private func startConfigurationResumeWatchdog(
        captureID: UUID,
        configurationEpoch: UInt64
    ) {
        Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(2))
                await self?.configurationResumeTimedOut(
                    captureID: captureID,
                    configurationEpoch: configurationEpoch,
                    at: .now
                )
            } catch {
                return
            }
        }
    }

    private func configurationResumeTimedOut(
        captureID: UUID,
        configurationEpoch: UInt64,
        at instant: ContinuousClock.Instant
    ) {
        guard let capture = activeCapture,
              capture.retirementID == captureID,
              capture.retireIfNoBuffer(
                configurationEpoch: configurationEpoch
              ) else { return }
        handleInvalidConfiguration(for: capture, at: instant)
    }

    private func handleInvalidConfiguration(
        for capture: MicEngineCapture,
        at instant: ContinuousClock.Instant
    ) {
        guard activeCapture === capture else { return }
        pinnedDevice?.markUnstable(at: instant)
        reconnectAttempt.arm()
        availabilityReporter?.reportUnavailable()
        liveness?.markUnavailable(at: instant)
        cancelRebuildAndRetireActiveCapture()
        hardwareDevicesDidChange()
    }

    private func didReceiveBuffer(
        from captureID: UUID,
        at instant: ContinuousClock.Instant
    ) {
        guard activeCapture?.retirementID == captureID else { return }
        _ = liveness?.noteBuffer(
            at: instant,
            deviceName: pinnedDevice?.deviceName
        )
    }

    // MARK: - Device lifecycle

    private func installDeviceListeners() {
        let deviceListBlock: AudioObjectPropertyListenerBlock = {
            [weak self] _, _ in
            Task { await self?.hardwareDevicesDidChange() }
        }
        var listAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &listAddress,
            listenerQueue,
            deviceListBlock
        ) == noErr {
            deviceListListener = deviceListBlock
        }
    }

    private func removeDeviceListeners() {
        if let deviceListListener {
            self.deviceListListener = nil
            let token = MicDeviceListenerToken(block: deviceListListener)
            listenerQueue.async { [listenerQueue] in
                var address = AudioObjectPropertyAddress(
                    mSelector: kAudioHardwarePropertyDevices,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                AudioObjectRemovePropertyListenerBlock(
                    AudioObjectID(kAudioObjectSystemObject),
                    &address,
                    listenerQueue,
                    token.block
                )
            }
        }
    }

    private func hardwareDevicesDidChange() {
        guard isRunning, var pinnedDevice else { return }
        guard let devices = try? CoreAudioInputDevice.availableDevices() else {
            return
        }
        let now = ContinuousClock.now
        let previousDeviceID = pinnedDevice.currentDeviceID
        let event = pinnedDevice.observe(devices, at: now)
        self.pinnedDevice = pinnedDevice
        switch event {
        case .unavailable:
            reconnectAttempt.disarm()
            availabilityReporter?.reportUnavailable()
            liveness?.markUnavailable(at: .now)
            cancelRebuildAndRetireActiveCapture()
        case .available:
            reconnectAttempt.arm()
            attemptRebuild()
        case nil:
            if previousDeviceID != pinnedDevice.currentDeviceID {
                reconnectAttempt.arm()
                cancelRebuildAndRetireActiveCapture()
            }
            if activeCapture == nil { attemptRebuild() }
        }
    }

    // MARK: - Watchdog and rebuild

    private func startWatchdog() {
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { return }
                    await self?.pollInput(at: .now)
                } catch is CancellationError {
                    return
                } catch {
                    continue
                }
            }
        }
    }

    private func pollInput(at instant: ContinuousClock.Instant) async {
        guard isRunning else { return }
        if activeCapture?.isAwaitingConfigurationValidation == true {
            return
        }
        if let capture = activeCapture, !rebuildState.isActive {
            let isValid = await capture.isInputRouteValid(
                expectedDeviceID: pinnedDevice?.currentDeviceID,
                expectedDeviceUID: pinnedDevice?.pinnedUID
            )
            guard isRunning, activeCapture === capture else { return }
            if !isValid {
                reconnectAttempt.arm()
                pinnedDevice?.markUnstable(at: instant)
                availabilityReporter?.reportUnavailable()
                liveness?.markUnavailable(at: instant)
                retireActiveCapture()
                hardwareDevicesDidChange()
                return
            }
        }
        if activeCapture != nil,
           !rebuildState.isActive,
           let event = liveness?.poll(
               at: instant,
               timeout: .seconds(5),
               deviceName: pinnedDevice?.deviceName
           ), case .unavailable = event {
            reconnectAttempt.arm()
            pinnedDevice?.markUnstable(at: instant)
            availabilityReporter?.reportUnavailable()
            liveness?.markUnavailable(at: instant)
            retireActiveCapture()
            hardwareDevicesDidChange()
        }
        if activeCapture == nil {
            _ = reconnectAttempt.rearmIfExhausted(
                at: instant,
                after: .seconds(10)
            )
            attemptRebuild(at: instant)
        }
    }

    private func attemptRebuild(
        at instant: ContinuousClock.Instant = .now
    ) {
        guard isRunning,
              !rebuildState.isActive,
              activeCapture == nil,
              let pinnedDevice,
              pinnedDevice.isStable(at: instant, for: .seconds(3)),
              let deviceID = pinnedDevice.currentDeviceID,
              let fixedFormat = format else { return }
        if let lastRebuildAttempt,
           lastRebuildAttempt.duration(to: instant) < .seconds(3) {
            return
        }
        guard reconnectAttempt.consumeAttempt(at: instant) else { return }
        lastRebuildAttempt = instant
        let capture = makeCapture(announcesRecovery: true)
        guard rebuildState.begin(captureID: capture.retirementID) else { return }
        activeCapture = capture
        let generation = captureGeneration.advance()
        rebuildTask = Task { [weak self] in
            await self?.performRebuild(
                capture: capture,
                generation: generation,
                deviceID: deviceID,
                deviceUID: pinnedDevice.pinnedUID,
                fixedFormat: fixedFormat
            )
        }
    }

    private func performRebuild(
        capture: MicEngineCapture,
        generation: UInt64,
        deviceID: AudioDeviceID,
        deviceUID: String,
        fixedFormat: AVAudioFormat
    ) async {
        do {
            let nativeFormat = try await capture.prepare(deviceID: deviceID)
            guard isCurrent(capture, generation: generation) else { return }
            try await capture.start(
                nativeFormat: nativeFormat,
                fixedFormat: fixedFormat,
                expectedDeviceID: deviceID,
                expectedDeviceUID: deviceUID,
                bufferHandler: bufferHandler,
                availabilityReporter: availabilityReporter,
                configurationChanged: { [weak self] captureID, change in
                    Task {
                        await self?.engineConfigurationDidChange(
                            captureID,
                            change: change
                        )
                    }
                },
                bufferReceived: { [weak self] captureID in
                    Task {
                        await self?.didReceiveBuffer(
                            from: captureID,
                            at: .now
                        )
                    }
                }
            )
            guard isCurrent(capture, generation: generation) else { return }
            liveness?.begin(at: .now)
            _ = rebuildState.finish(captureID: capture.retirementID)
            rebuildTask = nil
        } catch {
            guard isCurrent(capture, generation: generation) else { return }
            Self.logger.error(
                "Microphone rebuild failed for capture \(capture.retirementID, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            retireActiveCapture()
            _ = rebuildState.finish(captureID: capture.retirementID)
            rebuildTask = nil
        }
    }

    private func isCurrent(
        _ capture: MicEngineCapture,
        generation: UInt64
    ) -> Bool {
        isRunning
            && captureGeneration.isCurrent(generation)
            && activeCapture === capture
    }

    // MARK: - Cleanup

    private func makeCapture(
        announcesRecovery: Bool
    ) -> MicEngineCapture {
        // Created here, never ahead of time: the unit must be built after the
        // system-audio tap has rebuilt Core Audio's device graph.
        return MicEngineCapture(
            unit: HALInputUnit(),
            announcesRecovery: announcesRecovery
        )
    }

    private func cancelRebuildAndRetireActiveCapture() {
        rebuildTask?.cancel()
        rebuildTask = nil
        captureGeneration.invalidate()
        rebuildState.cancel()
        retireActiveCapture()
    }

    private func retireActiveCapture() {
        guard let capture = activeCapture else { return }
        capture.retireGate()
        activeCapture = nil
        retiredMicCaptures.retire(capture)
        let retainedCount = retiredMicCaptures.retainedCount
        if retainedCount > 8 {
            Self.logger.warning(
                "\(retainedCount, privacy: .public) microphone captures are still tearing down"
            )
        }
    }

    private func cleanup(resetFormat: Bool) {
        isRunning = false
        operationState.reset()
        cancelRebuildAndRetireActiveCapture()
        watchdogTask?.cancel()
        watchdogTask = nil
        removeDeviceListeners()
        availabilityReporter?.finish()
        availabilityReporter = nil
        bufferHandler = nil
        pinnedDevice = nil
        liveness = nil
        lastRebuildAttempt = nil
        reconnectAttempt = ReconnectAttemptState()
        if resetFormat {
            format = nil
            preparedEngine.clear()
        }
    }
}

private let retiredMicCaptures = MicCaptureRetirementPool<MicEngineCapture>()

private final class MicDeviceListenerToken: @unchecked Sendable {
    let block: AudioObjectPropertyListenerBlock

    init(block: @escaping AudioObjectPropertyListenerBlock) {
        self.block = block
    }
}

private final class MicEngineCapture: MicCaptureRetirementResource,
    @unchecked Sendable {
    let retirementID = UUID()

    private let unit: HALInputUnit
    private let gate: InputCaptureGate
    private let queue: DispatchQueue

    init(unit: HALInputUnit, announcesRecovery: Bool) {
        self.unit = unit
        gate = InputCaptureGate(announcesRecovery: announcesRecovery)
        queue = DispatchQueue(
            label: "org.steno.microphone-engine.\(retirementID.uuidString)",
            qos: .userInitiated
        )
    }

    func prepare(deviceID: AudioDeviceID) async throws -> AVAudioFormat {
        try await perform("prepare") { unit in
            try unit.prepare(deviceID: deviceID)
        }
    }

    func start(
        nativeFormat: AVAudioFormat,
        fixedFormat: AVAudioFormat,
        expectedDeviceID: AudioDeviceID,
        expectedDeviceUID: String,
        bufferHandler: AudioBufferHandler?,
        availabilityReporter: SourceAvailabilityReporter?,
        configurationChanged: @escaping @Sendable (
            UUID,
            InputCaptureConfigurationChange
        ) -> Void,
        bufferReceived: @escaping @Sendable (UUID) -> Void
    ) async throws {
        guard let bufferHandler, let availabilityReporter else {
            throw AudioRecordingError.audioSourceUnavailable(
                "the microphone handlers are unavailable"
            )
        }
        try await perform("start") { [self] unit in
            let gate = gate
            let converter = try AudioBufferConverter(
                sourceFormat: nativeFormat,
                targetFormat: fixedFormat
            )
            let retirementID = retirementID
            try unit.start { buffer in
                guard let converted = converter.convert(buffer) else { return }
                let decision = gate.consume(
                    frameLength: converted.frameLength
                )
                guard decision != .drop else { return }
                if decision == .acceptAndAnnounceRecovery {
                    availabilityReporter.reportAvailable()
                }
                bufferHandler(converted)
                bufferReceived(retirementID)
            }
            // The HAL unit has no configuration-change notification of its own,
            // so the bound device is observed directly. Same contract as before.
            unit.observeFormatChanges { [retirementID] in
                let change = gate.configurationChanged()
                guard change != .ignore else { return }
                configurationChanged(retirementID, change)
            }
            let configurationEpoch = gate.configurationEpoch
            guard Self.routeIsValid(
                unit: unit,
                expectedDeviceID: expectedDeviceID,
                expectedDeviceUID: expectedDeviceUID
            ) else {
                throw AudioRecordingError.audioSourceUnavailable(
                    "the selected microphone changed while capture was starting"
                )
            }
            guard gate.open(
                afterVerifyingConfigurationEpoch: configurationEpoch
            ) else {
                throw AudioRecordingError.audioSourceUnavailable(
                    "the selected microphone changed while capture was starting"
                )
            }
        }
    }

    var isAwaitingConfigurationValidation: Bool {
        gate.isAwaitingConfigurationValidation
    }

    func resumeGate(configurationEpoch: UInt64) -> Bool {
        gate.resume(configurationEpoch: configurationEpoch)
    }

    func retireSuspension(configurationEpoch: UInt64) -> Bool {
        gate.retireSuspension(configurationEpoch: configurationEpoch)
    }

    func retireIfNoBuffer(configurationEpoch: UInt64) -> Bool {
        gate.retireIfNoBuffer(configurationEpoch: configurationEpoch)
    }

    func retireGate() {
        gate.retire()
    }

    func isInputRouteValid(
        expectedDeviceID: AudioDeviceID?,
        expectedDeviceUID: String?
    ) async -> Bool {
        guard let expectedDeviceID, let expectedDeviceUID else { return false }
        return await performWithoutThrowing(timeoutFallback: false) { unit in
            Self.routeIsValid(
                unit: unit,
                expectedDeviceID: expectedDeviceID,
                expectedDeviceUID: expectedDeviceUID
            )
        }
    }

    func canResumeAfterConfigurationChange(
        expectedDeviceID: AudioDeviceID?,
        expectedDeviceUID: String?
    ) async -> Bool {
        guard let expectedDeviceID, let expectedDeviceUID else { return false }
        return await performWithoutThrowing(
            timeout: .seconds(1),
            timeoutFallback: false
        ) { unit in
            unit.isCapturing && Self.routeIsValid(
                unit: unit,
                expectedDeviceID: expectedDeviceID,
                expectedDeviceUID: expectedDeviceUID
            )
        }
    }

    func beginRetirement(
        completion: @escaping @Sendable () -> Void
    ) {
        retireGate()
        queue.async { [unit] in
            // Stopping the unit removes its format listener and disposes it.
            unit.stop()
            completion()
        }
    }

    /// Runs one bring-up step on the capture queue, with a watchdog.
    ///
    /// The watchdog stays generous on purpose. A call that overruns it is not
    /// cancellable - it keeps running on this queue and holds Core Audio's
    /// client lock - so a timeout here does not merely fail one attempt, it
    /// poisons every later one. Naming the phase is what makes that visible in
    /// the diagnostics instead of guessable.
    private func perform<Value: Sendable>(
        _ phase: String,
        _ operation: @escaping @Sendable (HALInputUnit) throws -> Value
    ) async throws -> Value {
        let result = MicCaptureResultLatch<Value>()
        let started = ContinuousClock.now
        queue.async { [unit] in
            do {
                result.resolve(.success(try operation(unit)))
            } catch {
                result.resolve(.failure(error))
            }
        }
        Task {
            do {
                try await Task.sleep(for: Self.watchdogTimeout)
                result.resolve(.failure(
                    AudioRecordingError.audioSourceUnavailable(
                        "the microphone did not respond while it was asked to \(phase)"
                    )
                ))
            } catch {
                return
            }
        }
        let value = try await result.value()
        lastPhaseDuration = started.duration(to: .now)
        return value
    }

    /// How long the last completed bring-up step took, for the diagnostics log.
    private(set) var lastPhaseDuration: Duration = .zero

    static let watchdogTimeout: Duration = .seconds(15)

    private func performWithoutThrowing<Value: Sendable>(
        timeout: Duration = .seconds(5),
        timeoutFallback: Value,
        _ operation: @escaping @Sendable (HALInputUnit) -> Value
    ) async -> Value {
        let result = MicCaptureResultLatch<Value>()
        queue.async { [unit] in
            result.resolve(.success(operation(unit)))
        }
        return await result.value(
            timeout: timeout,
            fallback: timeoutFallback
        )
    }

    private static func routeIsValid(
        unit: HALInputUnit,
        expectedDeviceID: AudioDeviceID,
        expectedDeviceUID: String
    ) -> Bool {
        guard let reportedDeviceID = unit.currentDeviceID() else {
            return false
        }
        let route = PinnedEngineInputRoute(
            deviceID: expectedDeviceID,
            deviceUID: expectedDeviceUID
        )
        return route.accepts(
            reportedDeviceID: reportedDeviceID,
            activeInputUIDs: reportedDeviceID == expectedDeviceID
                ? nil
                : CoreAudioInputDevice.activeInputSubdeviceUIDs(
                    of: reportedDeviceID
                )
        )
    }

    private static func currentDeviceID(
        for engine: AVAudioEngine
    ) -> AudioDeviceID? {
        guard let audioUnit = engine.inputNode.audioUnit else { return nil }
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            &size
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            return nil
        }
        return deviceID
    }
}

struct MicRecorderOperationState: Sendable {
    private var preparationID: UUID?
    private var startingCaptureID: UUID?

    var isBusy: Bool {
        preparationID != nil || startingCaptureID != nil
    }

    mutating func beginPreparation() -> UUID? {
        guard !isBusy else { return nil }
        let id = UUID()
        preparationID = id
        return id
    }

    mutating func finishPreparation(_ id: UUID) -> Bool {
        guard preparationID == id else { return false }
        preparationID = nil
        return true
    }

    mutating func beginStart(captureID: UUID) -> Bool {
        guard !isBusy else { return false }
        startingCaptureID = captureID
        return true
    }

    mutating func finishStart(captureID: UUID) -> Bool {
        guard startingCaptureID == captureID else { return false }
        startingCaptureID = nil
        return true
    }

    mutating func reset() {
        preparationID = nil
        startingCaptureID = nil
    }
}

struct MicRebuildState: Sendable {
    private var captureID: UUID?

    var isActive: Bool {
        captureID != nil
    }

    mutating func begin(captureID: UUID) -> Bool {
        guard self.captureID == nil else { return false }
        self.captureID = captureID
        return true
    }

    mutating func finish(captureID: UUID) -> Bool {
        guard self.captureID == captureID else { return false }
        self.captureID = nil
        return true
    }

    mutating func cancel() {
        captureID = nil
    }
}

struct MicCaptureGenerationState: Sendable {
    private var value: UInt64 = 0

    mutating func advance() -> UInt64 {
        value &+= 1
        return value
    }

    mutating func invalidate() {
        value &+= 1
    }

    func isCurrent(_ candidate: UInt64) -> Bool {
        candidate == value
    }
}

final class MicCaptureResultLatch<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, any Error>?
    private var continuation: CheckedContinuation<
        Result<Value, any Error>,
        Never
    >?

    func value() async throws -> Value {
        let settled: Result<Value, any Error> = await withCheckedContinuation {
            continuation in
            let immediate = lock.withLock { () -> Result<Value, any Error>? in
                if let result { return result }
                self.continuation = continuation
                return nil
            }
            if let immediate {
                continuation.resume(returning: immediate)
            }
        }
        return try settled.get()
    }

    func value(
        timeout: Duration,
        fallback: Value
    ) async -> Value {
        let timeoutTask = Task { [self] in
            do {
                try await Task.sleep(for: timeout)
                resolve(.success(fallback))
            } catch {
                return
            }
        }
        defer { timeoutTask.cancel() }
        return (try? await value()) ?? fallback
    }

    func resolve(_ result: Result<Value, any Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<
            Result<Value, any Error>,
            Never
        >? in
            guard self.result == nil else { return nil }
            self.result = result
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(returning: result)
    }
}

struct ReconnectAttemptState: Sendable {
    private var remainingAttempts = 0
    private var exhaustedAt: ContinuousClock.Instant?

    mutating func arm() {
        remainingAttempts = 3
        exhaustedAt = nil
    }

    mutating func disarm() {
        remainingAttempts = 0
        exhaustedAt = nil
    }

    mutating func consumeAttempt(
        at instant: ContinuousClock.Instant = .now
    ) -> Bool {
        guard remainingAttempts > 0 else { return false }
        remainingAttempts -= 1
        if remainingAttempts == 0 {
            exhaustedAt = instant
        }
        return true
    }

    mutating func rearmIfExhausted(
        at instant: ContinuousClock.Instant,
        after cooldown: Duration
    ) -> Bool {
        guard remainingAttempts == 0,
              let exhaustedAt,
              exhaustedAt.duration(to: instant) >= cooldown else {
            return false
        }
        arm()
        return true
    }
}

struct PreferredInputStabilityState: Sendable {
    private var device: CoreAudioInputDevice?
    private var stableSince: ContinuousClock.Instant?

    mutating func observe(
        _ observedDevice: CoreAudioInputDevice?,
        at instant: ContinuousClock.Instant
    ) {
        guard observedDevice?.id == device?.id else {
            device = observedDevice
            stableSince = observedDevice == nil ? nil : instant
            return
        }
    }

    func stableDevice(
        at instant: ContinuousClock.Instant,
        for duration: Duration
    ) -> CoreAudioInputDevice? {
        guard let device, let stableSince,
              stableSince.duration(to: instant) >= duration else {
            return nil
        }
        return device
    }
}

struct PreparedMicEngineState {
    private var deviceID: AudioDeviceID?
    private var nativeFormat: AVAudioFormat?

    mutating func prepare(
        deviceID: AudioDeviceID,
        bind: (AudioDeviceID) throws -> AVAudioFormat
    ) rethrows -> AVAudioFormat {
        let format = try bind(deviceID)
        self.deviceID = deviceID
        nativeFormat = format
        return format
    }

    func nativeFormatForStart(deviceID: AudioDeviceID) throws -> AVAudioFormat {
        guard self.deviceID == deviceID, let nativeFormat else {
            throw AudioRecordingError.audioSourceUnavailable(
                "the selected microphone was not prepared"
            )
        }
        return nativeFormat
    }

    mutating func clear() {
        deviceID = nil
        nativeFormat = nil
    }
}

private final class SourceAvailabilityReporter: @unchecked Sendable {
    private let lock = NSLock()
    private let deviceName: String?
    private var handler: AudioSourceEventHandler?
    private var isAvailable = true

    init(
        deviceName: String?,
        handler: @escaping AudioSourceEventHandler
    ) {
        self.deviceName = deviceName
        self.handler = handler
    }

    func reportUnavailable() {
        let handler = lock.withLock { () -> AudioSourceEventHandler? in
            guard isAvailable else { return nil }
            isAvailable = false
            return self.handler
        }
        handler?(.unavailable(deviceName: deviceName))
    }

    func reportAvailable() {
        let handler = lock.withLock { () -> AudioSourceEventHandler? in
            guard !isAvailable else { return nil }
            isAvailable = true
            return self.handler
        }
        handler?(.available(deviceName: deviceName))
    }

    func finish() {
        lock.withLock { handler = nil }
    }
}

enum InputCaptureDecision: Equatable, Sendable {
    case drop
    case accept
    case acceptAndAnnounceRecovery
}

enum InputCaptureConfigurationChange: Equatable, Sendable {
    case validate(epoch: UInt64)
    case ignore

    var validationEpoch: UInt64? {
        guard case let .validate(epoch) = self else { return nil }
        return epoch
    }
}

final class InputCaptureGate: @unchecked Sendable {
    private enum State {
        case closed
        case open(epoch: UInt64)
        case suspended(epoch: UInt64)
        case retired
    }

    private let lock = NSLock()
    private var state = State.closed
    private var nextConfigurationEpoch: UInt64 = 0
    private var lastAcceptedEpoch: UInt64?
    private var shouldAnnounceRecovery: Bool

    init(announcesRecovery: Bool) {
        shouldAnnounceRecovery = announcesRecovery
    }

    var isAwaitingConfigurationValidation: Bool {
        lock.withLock {
            guard case .suspended = state else { return false }
            return true
        }
    }

    var configurationEpoch: UInt64 {
        lock.withLock { nextConfigurationEpoch }
    }

    @discardableResult
    func open() -> Bool {
        lock.withLock {
            guard case .closed = state else { return false }
            state = .open(epoch: nextConfigurationEpoch)
            return true
        }
    }

    func open(afterVerifyingConfigurationEpoch epoch: UInt64) -> Bool {
        lock.withLock {
            guard case .closed = state,
                  nextConfigurationEpoch == epoch else { return false }
            state = .open(epoch: epoch)
            return true
        }
    }

    func closeIfOpen() -> Bool {
        lock.withLock {
            guard case .open = state else { return false }
            state = .closed
            return true
        }
    }

    func configurationChanged() -> InputCaptureConfigurationChange {
        lock.withLock {
            switch state {
            case .closed:
                nextConfigurationEpoch &+= 1
                return .ignore
            case .open, .suspended:
                nextConfigurationEpoch &+= 1
                shouldAnnounceRecovery = true
                state = .suspended(epoch: nextConfigurationEpoch)
                return .validate(epoch: nextConfigurationEpoch)
            case .retired:
                return .ignore
            }
        }
    }

    func resume(configurationEpoch: UInt64) -> Bool {
        lock.withLock {
            guard case let .suspended(currentEpoch) = state,
                  currentEpoch == configurationEpoch else {
                return false
            }
            state = .open(epoch: configurationEpoch)
            return true
        }
    }

    func retireSuspension(configurationEpoch: UInt64) -> Bool {
        lock.withLock {
            guard case let .suspended(currentEpoch) = state,
                  currentEpoch == configurationEpoch else {
                return false
            }
            state = .retired
            return true
        }
    }

    func retireIfNoBuffer(configurationEpoch: UInt64) -> Bool {
        lock.withLock {
            guard case let .open(currentEpoch) = state,
                  currentEpoch == configurationEpoch,
                  lastAcceptedEpoch != configurationEpoch else {
                return false
            }
            state = .retired
            return true
        }
    }

    @discardableResult
    func retire() -> Bool {
        lock.withLock {
            guard case .retired = state else {
                state = .retired
                return true
            }
            return false
        }
    }

    func consume(frameLength: AVAudioFrameCount) -> InputCaptureDecision {
        lock.withLock {
            guard case let .open(epoch) = state,
                  frameLength > 0 else { return .drop }
            lastAcceptedEpoch = epoch
            guard shouldAnnounceRecovery else { return .accept }
            shouldAnnounceRecovery = false
            return .acceptAndAnnounceRecovery
        }
    }
}

protocol MicCaptureRetirementResource: AnyObject, Sendable {
    var retirementID: UUID { get }
    func beginRetirement(completion: @escaping @Sendable () -> Void)
}

final class MicCaptureRetirementPool<
    Resource: MicCaptureRetirementResource
>: @unchecked Sendable {
    private let lock = NSLock()
    private var resources: [UUID: Resource] = [:]

    var retainedCount: Int {
        lock.withLock { resources.count }
    }

    func retire(_ resource: Resource) {
        let wasInserted = lock.withLock {
            resources.updateValue(
                resource,
                forKey: resource.retirementID
            ) == nil
        }
        guard wasInserted else { return }
        resource.beginRetirement { [weak self] in
            self?.release(resource.retirementID)
        }
    }

    private func release(_ id: UUID) {
        _ = lock.withLock { resources.removeValue(forKey: id) }
    }
}
