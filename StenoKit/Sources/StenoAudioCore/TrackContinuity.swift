@preconcurrency import AVFAudio
import Darwin
import Foundation

public actor TrackContinuity {
    public private(set) var status: RecordingTrackStatus

    private let format: AVAudioFormat
    private let sessionStart: ContinuousClock.Instant
    private let writerContinuation: AsyncStream<TrackWriteEvent>.Continuation
    private let liveContinuation: AsyncStream<LiveAudioEvent>.Continuation
    private let stallTimeout: Duration
    private let maximumSilenceFrames: AVAudioFrameCount
    private let writerOverflowHandler: @Sendable () -> Void

    private var writtenFrames: AVAudioFramePosition = 0
    private var lastSourceCallbackAt: ContinuousClock.Instant?
    private var activeGapReason: TrackGapReason?
    private var needsHostRealignment: Bool
    private var isFinished = false

    public init(
        format: AVAudioFormat,
        sessionStart: ContinuousClock.Instant,
        writerContinuation: AsyncStream<TrackWriteEvent>.Continuation,
        liveContinuation: AsyncStream<LiveAudioEvent>.Continuation,
        stallTimeout: Duration = .seconds(2),
        maximumSilenceDuration: Duration = .milliseconds(250),
        alignFirstBufferToSessionStart: Bool = false,
        writerOverflowHandler: @escaping @Sendable () -> Void
    ) {
        precondition(format.sampleRate > 0)
        precondition(maximumSilenceDuration > .zero)
        self.format = format
        self.sessionStart = sessionStart
        self.writerContinuation = writerContinuation
        self.liveContinuation = liveContinuation
        self.stallTimeout = stallTimeout
        self.maximumSilenceFrames = max(
            1,
            AVAudioFrameCount(
                durationSeconds(maximumSilenceDuration) * format.sampleRate
            )
        )
        needsHostRealignment = alignFirstBufferToSessionStart
        self.writerOverflowHandler = writerOverflowHandler
        self.status = RecordingTrackStatus()
    }

    public func receive(
        _ buffer: sending AVAudioPCMBuffer,
        at instant: ContinuousClock.Instant
    ) {
        guard !isFinished else { return }
        lastSourceCallbackAt = instant

        if status.sourceStalled {
            fillSilence(until: instant)
            status.sourceStalled = false
            reconcileGap(at: instant)
        }

        guard status.isPassingRealAudio else { return }
        guard isCompatible(buffer.format) else { return }

        var ownedBuffer = buffer
        if needsHostRealignment {
            let targetFrame = targetFrame(at: instant)
            if writtenFrames < targetFrame {
                fillSilence(toFrame: targetFrame)
            } else if writtenFrames > targetFrame {
                let overlap = writtenFrames - targetFrame
                guard overlap < AVAudioFramePosition(buffer.frameLength),
                      let trimmed = copy(
                          buffer,
                          droppingInitialFrames: AVAudioFrameCount(overlap)
                      ) else {
                    return
                }
                ownedBuffer = trimmed
            }
            guard writtenFrames >= targetFrame else { return }
            needsHostRealignment = false
        }

        writeRealBuffer(ownedBuffer)
    }

    public func setUserPaused(
        _ paused: Bool,
        at instant: ContinuousClock.Instant
    ) {
        guard !isFinished, status.userPaused != paused else { return }
        if !paused {
            fillSilence(until: instant)
        }
        status.userPaused = paused
        reconcileGap(at: instant)
    }

    public func setDeviceAvailable(
        _ available: Bool,
        deviceName: String?,
        at instant: ContinuousClock.Instant
    ) {
        guard !isFinished else { return }
        if let deviceName {
            status.deviceName = deviceName
        }
        guard status.deviceAvailable != available else { return }
        if available {
            fillSilence(until: instant)
            status.deviceAvailable = true
            status.sourceStalled = true
        } else {
            status.deviceAvailable = false
            status.sourceStalled = false
        }
        reconcileGap(at: instant)
    }

    public func tick(at instant: ContinuousClock.Instant) {
        guard !isFinished else { return }
        detectStall(at: instant)
        if activeGapReason != nil {
            fillSilence(until: instant)
        }
    }

    /// End an abandoned track without manufacturing a recording of silence.
    public func discard() {
        guard !isFinished else { return }
        isFinished = true
        writerContinuation.finish()
        liveContinuation.finish()
    }

    public func finish(at instant: ContinuousClock.Instant) {
        guard !isFinished else { return }
        fillSilence(until: instant)
        isFinished = true
        writerContinuation.finish()
        liveContinuation.finish()
    }

    private func detectStall(at instant: ContinuousClock.Instant) {
        guard status.deviceAvailable, !status.sourceStalled else { return }
        let lastActivity = lastSourceCallbackAt ?? sessionStart
        guard lastActivity.duration(to: instant) >= stallTimeout else { return }
        status.sourceStalled = true
        reconcileGap(at: instant)
    }

    private func reconcileGap(at instant: ContinuousClock.Instant) {
        let reason = effectiveGapReason
        switch (activeGapReason, reason) {
        case (nil, let reason?):
            activeGapReason = reason
            liveContinuation.yield(
                .gapStarted(at: writtenDuration, reason: reason)
            )
        case (.some, nil):
            fillSilence(until: instant)
            activeGapReason = nil
            needsHostRealignment = true
            liveContinuation.yield(.gapEnded(at: writtenDuration))
        case (.some, .some), (nil, nil):
            break
        }
    }

    private var effectiveGapReason: TrackGapReason? {
        if status.userPaused { return .userPaused }
        if !status.deviceAvailable { return .deviceUnavailable }
        if status.sourceStalled { return .sourceStalled }
        return nil
    }

    private var writtenDuration: TimeInterval {
        Double(writtenFrames) / format.sampleRate
    }

    private func targetFrame(
        at instant: ContinuousClock.Instant
    ) -> AVAudioFramePosition {
        let elapsed = max(0, durationSeconds(sessionStart.duration(to: instant)))
        return AVAudioFramePosition((elapsed * format.sampleRate).rounded(.down))
    }

    private func fillSilence(until instant: ContinuousClock.Instant) {
        fillSilence(toFrame: targetFrame(at: instant))
    }

    private func fillSilence(toFrame targetFrame: AVAudioFramePosition) {
        guard writtenFrames < targetFrame else { return }
        let frames = targetFrame - writtenFrames
        switch writerContinuation.yield(.silence(frames: frames, format: format, chunkSize: maximumSilenceFrames)) {
        case .enqueued:
            writtenFrames = targetFrame
        case .dropped:
            writerOverflowHandler()
        case .terminated:
            break
        @unknown default:
            break
        }
    }

    private func writeRealBuffer(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        if let liveCopy = AudioBufferTransfer.copy(buffer) {
            liveContinuation.yield(.buffer(OwnedAudioBuffer(buffer: liveCopy)))
        }
        if yieldToWriter(buffer, isSilence: false) {
            writtenFrames += AVAudioFramePosition(buffer.frameLength)
        }
    }

    private func yieldToWriter(
        _ buffer: sending AVAudioPCMBuffer,
        isSilence: Bool
    ) -> Bool {
        switch writerContinuation.yield(.buffer(OwnedAudioBuffer(buffer: buffer))) {
        case .dropped:
            if !isSilence { writerOverflowHandler() }
            return false
        case .enqueued:
            return true
        case .terminated:
            return false
        @unknown default:
            return false
        }
    }

    private func isCompatible(_ other: AVAudioFormat) -> Bool {
        other.sampleRate == format.sampleRate
            && other.channelCount == format.channelCount
            && other.commonFormat == format.commonFormat
            && other.isInterleaved == format.isInterleaved
    }

    private func copy(
        _ source: AVAudioPCMBuffer,
        droppingInitialFrames droppedFrames: AVAudioFrameCount
    ) -> AVAudioPCMBuffer? {
        guard droppedFrames < source.frameLength else { return nil }
        let remainingFrames = source.frameLength - droppedFrames
        guard let destination = AVAudioPCMBuffer(
            pcmFormat: source.format,
            frameCapacity: remainingFrames
        ) else {
            return nil
        }
        destination.frameLength = remainingFrames
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(
            source.mutableAudioBufferList
        )
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(
            destination.mutableAudioBufferList
        )
        guard sourceBuffers.count == destinationBuffers.count else { return nil }
        for index in sourceBuffers.indices {
            let sourceBuffer = sourceBuffers[index]
            let destinationBuffer = destinationBuffers[index]
            guard source.frameLength > 0,
                  let sourceData = sourceBuffer.mData,
                  let destinationData = destinationBuffer.mData else {
                return nil
            }
            let bytesPerFrame = Int(sourceBuffer.mDataByteSize)
                / Int(source.frameLength)
            let sourceOffset = Int(droppedFrames) * bytesPerFrame
            let byteCount = Int(remainingFrames) * bytesPerFrame
            memcpy(
                destinationData,
                sourceData.advanced(by: sourceOffset),
                byteCount
            )
            destinationBuffers[index].mDataByteSize = UInt32(byteCount)
        }
        return destination
    }
}

private func durationSeconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds)
        + Double(components.attoseconds) / 1_000_000_000_000_000_000
}
