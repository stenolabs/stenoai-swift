@preconcurrency import AVFAudio
import Foundation
import Testing
@testable import StenoAudioCore

@Suite("TrackContinuity")
struct TrackContinuityTests {
    @Test("discarding an unbound late track does not synthesize silence")
    func discardDoesNotPad() async {
        let writer = AsyncStream.makeStream(of: TrackWriteEvent.self)
        let live = AsyncStream.makeStream(of: LiveAudioEvent.self)
        let timeline = TrackContinuity(format: syntheticBuffer().format, sessionStart: .now.advanced(by: .seconds(-600)), writerContinuation: writer.continuation, liveContinuation: live.continuation, alignFirstBufferToSessionStart: true, writerOverflowHandler: {})
        await timeline.discard()
        let captured = await captureWriter(writer.stream)
        #expect(captured.frameCount == 0)
    }

    @Test("a full writer ring reports rejected final silence")
    func finalSilenceOverflowIsVisible() async {
        let writer = AsyncStream.makeStream(of: TrackWriteEvent.self, bufferingPolicy: .bufferingOldest(1))
        let live = AsyncStream.makeStream(of: LiveAudioEvent.self)
        let overflow = OverflowCounter()
        let start = ContinuousClock.now
        let timeline = TrackContinuity(format: syntheticBuffer().format, sessionStart: start, writerContinuation: writer.continuation, liveContinuation: live.continuation, writerOverflowHandler: { overflow.increment() })
        await timeline.receive(syntheticBuffer(), at: start)
        await timeline.finish(at: start.advanced(by: .seconds(1)))
        #expect(overflow.value == 1)
        let captured = await captureWriter(writer.stream)
        #expect(captured.frameCount == 4_000)
    }

    @Test("a long gap and resumed audio fit in two queue slots")
    func longGapPreservesResumedAudio() async {
        let writer = AsyncStream.makeStream(of: TrackWriteEvent.self, bufferingPolicy: .bufferingOldest(2))
        let live = AsyncStream.makeStream(of: LiveAudioEvent.self)
        let overflow = OverflowCounter()
        let start = ContinuousClock.now
        let timeline = TrackContinuity(format: syntheticBuffer().format, sessionStart: start, writerContinuation: writer.continuation, liveContinuation: live.continuation, alignFirstBufferToSessionStart: true, writerOverflowHandler: { overflow.increment() })
        await timeline.receive(syntheticBuffer(), at: start.advanced(by: .seconds(120)))
        await timeline.finish(at: start.advanced(by: .milliseconds(120_500)))
        let capture = await captureWriter(writer.stream)
        #expect(overflow.value == 0)
        #expect(capture.leadingSilentFrames == 960_000)
        #expect(capture.nonSilentBufferCount == 1)
        #expect(capture.frameCount == 964_000)
    }

    @Test("the first buffer preserves silence since the shared session start")
    func firstBufferKeepsTrackAlignment() async throws {
        let fixture = makeFixture(alignFirstBufferToSessionStart: true)

        await fixture.timeline.receive(
            syntheticBuffer(),
            at: fixture.start.advanced(by: .seconds(1))
        )
        await fixture.timeline.finish(
            at: fixture.start.advanced(by: .milliseconds(1_500))
        )

        let writer = await fixture.writer.value
        #expect(writer.frameCount == 12_000)
        #expect(writer.nonSilentBufferCount == 1)
        #expect(writer.leadingSilentFrames == 8_000)
    }

    @Test("a manual pause fills only the writer timeline with silence")
    func manualPauseFillsWriterOnly() async throws {
        let fixture = makeFixture()
        await fixture.timeline.receive(syntheticBuffer(), at: fixture.start)
        await fixture.timeline.setUserPaused(
            true,
            at: fixture.start.advanced(by: .milliseconds(500))
        )
        await fixture.timeline.tick(
            at: fixture.start.advanced(by: .milliseconds(1_500))
        )
        await fixture.timeline.setUserPaused(
            false,
            at: fixture.start.advanced(by: .milliseconds(1_500))
        )
        await fixture.timeline.finish(
            at: fixture.start.advanced(by: .seconds(2))
        )

        let writer = await fixture.writer.value
        let live = await fixture.live.value
        #expect(writer.frameCount == 16_000)
        #expect(writer.nonSilentBufferCount == 1)
        #expect(live.bufferCount == 1)
        #expect(live.gapReasons == [.userPaused])
        #expect(live.gapEndCount == 1)
    }

    @Test("device loss and user pause remain independent")
    func overlappingReasonsDoNotResumeUserPause() async throws {
        let fixture = makeFixture()
        await fixture.timeline.receive(syntheticBuffer(), at: fixture.start)
        await fixture.timeline.setDeviceAvailable(
            false,
            deviceName: "AirPods",
            at: fixture.start.advanced(by: .milliseconds(500))
        )
        await fixture.timeline.setUserPaused(
            true,
            at: fixture.start.advanced(by: .milliseconds(750))
        )
        await fixture.timeline.setDeviceAvailable(
            true,
            deviceName: "AirPods",
            at: fixture.start.advanced(by: .seconds(1))
        )

        let stillPaused = await fixture.timeline.status
        #expect(stillPaused.deviceAvailable)
        #expect(stillPaused.userPaused)
        await fixture.timeline.tick(
            at: fixture.start.advanced(by: .milliseconds(1_500))
        )
        await fixture.timeline.setUserPaused(
            false,
            at: fixture.start.advanced(by: .milliseconds(1_500))
        )
        await fixture.timeline.receive(
            syntheticBuffer(),
            at: fixture.start.advanced(by: .milliseconds(1_500))
        )
        await fixture.timeline.finish(
            at: fixture.start.advanced(by: .seconds(2))
        )

        let writer = await fixture.writer.value
        let live = await fixture.live.value
        #expect(writer.frameCount == 16_000)
        #expect(writer.nonSilentBufferCount == 2)
        #expect(live.bufferCount == 2)
        #expect(live.gapReasons == [.deviceUnavailable])
        #expect(live.gapEndCount == 1)
    }

    @Test("a silent source stall is backfilled from the last buffer end")
    func watchdogStallBackfillsWriterOnly() async throws {
        let fixture = makeFixture(stallTimeout: .seconds(2))
        await fixture.timeline.receive(syntheticBuffer(), at: fixture.start)
        await fixture.timeline.tick(
            at: fixture.start.advanced(by: .milliseconds(2_500))
        )
        let stalled = await fixture.timeline.status
        #expect(stalled.sourceStalled)
        await fixture.timeline.receive(
            syntheticBuffer(),
            at: fixture.start.advanced(by: .milliseconds(2_500))
        )
        await fixture.timeline.finish(
            at: fixture.start.advanced(by: .seconds(3))
        )

        let writer = await fixture.writer.value
        let live = await fixture.live.value
        #expect(writer.frameCount == 24_000)
        #expect(writer.nonSilentBufferCount == 2)
        #expect(live.bufferCount == 2)
        #expect(live.gapReasons == [.sourceStalled])
    }

    @Test("long gaps use bounded silence buffers")
    func boundsSilenceChunks() async throws {
        let fixture = makeFixture(maximumSilenceDuration: .milliseconds(250))
        await fixture.timeline.setUserPaused(true, at: fixture.start)
        await fixture.timeline.tick(
            at: fixture.start.advanced(by: .seconds(5))
        )
        await fixture.timeline.finish(
            at: fixture.start.advanced(by: .seconds(5))
        )

        let writer = await fixture.writer.value
        #expect(writer.frameCount == 40_000)
        #expect(writer.bufferLengths.allSatisfy { $0 <= 2_000 })
        #expect(writer.bufferLengths.count == 20)
    }

    @Test("stopping during a gap fills exactly to the stop instant")
    func stopDuringGap() async throws {
        let fixture = makeFixture()
        await fixture.timeline.receive(syntheticBuffer(), at: fixture.start)
        await fixture.timeline.setDeviceAvailable(
            false,
            deviceName: "AirPods",
            at: fixture.start.advanced(by: .milliseconds(500))
        )
        await fixture.timeline.finish(
            at: fixture.start.advanced(by: .milliseconds(1_750))
        )

        let writer = await fixture.writer.value
        #expect(writer.frameCount == 14_000)
        #expect(writer.nonSilentBufferCount == 1)
    }

    @Test("a returned buffer cannot overwrite silence already written")
    func trimsOverlappingReturnedBuffer() async throws {
        let fixture = makeFixture()
        await fixture.timeline.receive(syntheticBuffer(), at: fixture.start)
        await fixture.timeline.setDeviceAvailable(
            false,
            deviceName: "AirPods",
            at: fixture.start.advanced(by: .milliseconds(500))
        )
        await fixture.timeline.tick(
            at: fixture.start.advanced(by: .milliseconds(1_600))
        )
        await fixture.timeline.setDeviceAvailable(
            true,
            deviceName: "AirPods",
            at: fixture.start.advanced(by: .milliseconds(1_600))
        )
        await fixture.timeline.receive(
            syntheticBuffer(),
            at: fixture.start.advanced(by: .milliseconds(1_500))
        )
        await fixture.timeline.finish(
            at: fixture.start.advanced(by: .seconds(2))
        )

        let writer = await fixture.writer.value
        #expect(writer.frameCount == 16_000)
        #expect(writer.bufferLengths.last == 3_200)
    }

    @Test("a clock jump queues its entire silence without flooding the writer ring")
    func clockJumpDropsSilenceWithoutStopping() async throws {
        let writerPair = AsyncStream.makeStream(
            of: TrackWriteEvent.self,
            bufferingPolicy: .bufferingOldest(1)
        )
        let livePair = AsyncStream.makeStream(of: LiveAudioEvent.self)
        let overflow = OverflowCounter()
        let start = ContinuousClock.now
        let timeline = TrackContinuity(
            format: syntheticBuffer().format,
            sessionStart: start,
            writerContinuation: writerPair.continuation,
            liveContinuation: livePair.continuation,
            stallTimeout: .seconds(300),
            maximumSilenceDuration: .milliseconds(250),
            writerOverflowHandler: { overflow.increment() }
        )
        let afterSleep = start.advanced(by: .seconds(120))

        await timeline.setUserPaused(true, at: start)
        await timeline.tick(at: afterSleep)
        await timeline.setUserPaused(false, at: afterSleep)
        await timeline.finish(at: afterSleep)

        let writer = await captureWriter(writerPair.stream)
        let live = await captureLive(livePair.stream)
        #expect(overflow.value == 0)
        #expect(writer.frameCount == 960_000)
        #expect(live.gapEndTimes == [120])
    }

    @Test("dropped real audio still overflows without advancing writer time")
    func droppedRealAudioStillOverflows() async throws {
        let writerPair = AsyncStream.makeStream(
            of: TrackWriteEvent.self,
            bufferingPolicy: .bufferingOldest(1)
        )
        let livePair = AsyncStream.makeStream(of: LiveAudioEvent.self)
        let overflow = OverflowCounter()
        let start = ContinuousClock.now
        let timeline = TrackContinuity(
            format: syntheticBuffer().format,
            sessionStart: start,
            writerContinuation: writerPair.continuation,
            liveContinuation: livePair.continuation,
            writerOverflowHandler: { overflow.increment() }
        )

        await timeline.receive(syntheticBuffer(), at: start)
        await timeline.receive(
            syntheticBuffer(),
            at: start.advanced(by: .milliseconds(500))
        )
        await timeline.setUserPaused(
            true,
            at: start.advanced(by: .milliseconds(500))
        )
        await timeline.setUserPaused(
            false,
            at: start.advanced(by: .milliseconds(500))
        )
        await timeline.finish(at: start.advanced(by: .milliseconds(500)))

        let writer = await captureWriter(writerPair.stream)
        let live = await captureLive(livePair.stream)
        #expect(overflow.value == 1)
        #expect(writer.frameCount == 4_000)
        #expect(live.gapStartTimes == [0.5])
        #expect(live.gapEndTimes == [0.5])
    }
}

private struct ContinuityFixture: Sendable {
    let start: ContinuousClock.Instant
    let timeline: TrackContinuity
    let writer: Task<WriterCapture, Never>
    let live: Task<LiveCapture, Never>
}

private struct WriterCapture: Sendable {
    let frameCount: Int
    let nonSilentBufferCount: Int
    let bufferLengths: [Int]
    let leadingSilentFrames: Int
}

private struct LiveCapture: Sendable {
    let bufferCount: Int
    let gapReasons: [TrackGapReason]
    let gapEndCount: Int
    let gapStartTimes: [TimeInterval]
    let gapEndTimes: [TimeInterval]
}

private func makeFixture(
    stallTimeout: Duration = .seconds(10),
    maximumSilenceDuration: Duration = .milliseconds(250),
    alignFirstBufferToSessionStart: Bool = false
) -> ContinuityFixture {
    let writerPair = AsyncStream.makeStream(of: TrackWriteEvent.self)
    let livePair = AsyncStream.makeStream(of: LiveAudioEvent.self)
    let start = ContinuousClock.now
    let timeline = TrackContinuity(
        format: syntheticBuffer().format,
        sessionStart: start,
        writerContinuation: writerPair.continuation,
        liveContinuation: livePair.continuation,
        stallTimeout: stallTimeout,
        maximumSilenceDuration: maximumSilenceDuration,
        alignFirstBufferToSessionStart: alignFirstBufferToSessionStart,
        writerOverflowHandler: {}
    )
    let writerStream = writerPair.stream
    let writer = Task {
        var frameCount = 0
        var nonSilentBufferCount = 0
        var bufferLengths: [Int] = []
        var leadingSilentFrames = 0
        var receivedNonSilence = false
        for await event in writerStream {
            for buffer in event.testBuffers {
            frameCount += Int(buffer.frameLength)
            bufferLengths.append(Int(buffer.frameLength))
            if AudioLevelMeter.measure(buffer).peak > 0 {
                nonSilentBufferCount += 1
                receivedNonSilence = true
            } else if !receivedNonSilence {
                leadingSilentFrames += Int(buffer.frameLength)
            }
        }
        }
        return WriterCapture(
            frameCount: frameCount,
            nonSilentBufferCount: nonSilentBufferCount,
            bufferLengths: bufferLengths,
            leadingSilentFrames: leadingSilentFrames
        )
    }
    let liveStream = livePair.stream
    let live = Task {
        await captureLive(liveStream)
    }
    return ContinuityFixture(
        start: start,
        timeline: timeline,
        writer: writer,
        live: live
    )
}

private func captureWriter(
    _ stream: sending AsyncStream<TrackWriteEvent>
) async -> WriterCapture {
    var frameCount = 0
    var nonSilentBufferCount = 0
    var bufferLengths: [Int] = []
    var leadingSilentFrames = 0
    var receivedNonSilence = false
    for await event in stream {
        for buffer in event.testBuffers {
        frameCount += Int(buffer.frameLength)
        bufferLengths.append(Int(buffer.frameLength))
        if AudioLevelMeter.measure(buffer).peak > 0 {
            nonSilentBufferCount += 1
            receivedNonSilence = true
        } else if !receivedNonSilence {
            leadingSilentFrames += Int(buffer.frameLength)
        }
    }
    }
    return WriterCapture(
        frameCount: frameCount,
        nonSilentBufferCount: nonSilentBufferCount,
        bufferLengths: bufferLengths,
        leadingSilentFrames: leadingSilentFrames
    )
}

private func captureLive(
    _ stream: sending AsyncStream<LiveAudioEvent>
) async -> LiveCapture {
    var bufferCount = 0
    var gapReasons: [TrackGapReason] = []
    var gapStartTimes: [TimeInterval] = []
    var gapEndTimes: [TimeInterval] = []
    for await event in stream {
        switch event {
        case .buffer:
            bufferCount += 1
        case let .gapStarted(at, reason):
            gapReasons.append(reason)
            gapStartTimes.append(at)
        case let .gapEnded(at):
            gapEndTimes.append(at)
        }
    }
    return LiveCapture(
        bufferCount: bufferCount,
        gapReasons: gapReasons,
        gapEndCount: gapEndTimes.count,
        gapStartTimes: gapStartTimes,
        gapEndTimes: gapEndTimes
    )
}

private final class OverflowCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() {
        lock.withLock { count += 1 }
    }
}

private extension TrackWriteEvent {
    var testBuffers: [AVAudioPCMBuffer] {
        switch self {
        case .buffer(let owned): return [owned.buffer]
        case let .silence(frames, format, chunkSize):
            var remaining = frames
            var result: [AVAudioPCMBuffer] = []
            while remaining > 0 {
                let count = AVAudioFrameCount(min(remaining, AVAudioFramePosition(chunkSize)))
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
                buffer.frameLength = count
                for part in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
                    if let data = part.mData { memset(data, 0, Int(part.mDataByteSize)) }
                }
                result.append(buffer)
                remaining -= AVAudioFramePosition(count)
            }
            return result
        }
    }
}
