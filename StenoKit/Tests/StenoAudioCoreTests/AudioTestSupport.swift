@preconcurrency import AVFAudio
import Foundation
@testable import StenoAudioCore

func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("StenoMacAudioTests-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: true
    )
    return url
}

func syntheticBuffer(
    sampleRate: Double = 8_000,
    channels: AVAudioChannelCount = 1,
    frames: AVAudioFrameCount = 4_000,
    amplitude: Float = 0.5
) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: channels,
        interleaved: false
    )!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for channel in 0..<Int(channels) {
        let samples = buffer.floatChannelData![channel]
        for frame in 0..<Int(frames) {
            samples[frame] = frame.isMultiple(of: 2) ? amplitude : -amplitude
        }
    }
    return buffer
}

actor FakeAudioSource: AudioSource {
    nonisolated let track: AudioTrack
    nonisolated let format: AVAudioFormat
    private var handler: AudioBufferHandler?
    private var eventHandler: AudioSourceEventHandler?
    private let lifecycle: SourceLifecycleLog?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(
        track: AudioTrack,
        format: AVAudioFormat = syntheticBuffer().format,
        lifecycle: SourceLifecycleLog? = nil
    ) {
        self.track = track
        self.format = format
        self.lifecycle = lifecycle
    }

    func prepare() throws -> AVAudioFormat {
        lifecycle?.append("prepare-\(track.rawValue)")
        return format
    }

    func start(bufferHandler: @escaping AudioBufferHandler) {
        lifecycle?.append("start-\(track.rawValue)")
        handler = bufferHandler
        startCount += 1
    }

    func start(
        bufferHandler: @escaping AudioBufferHandler,
        eventHandler: @escaping AudioSourceEventHandler
    ) {
        lifecycle?.append("start-\(track.rawValue)")
        handler = bufferHandler
        self.eventHandler = eventHandler
        startCount += 1
    }

    func stop() {
        stopCount += 1
        handler = nil
        eventHandler = nil
    }

    func emit(_ buffer: AVAudioPCMBuffer) async {
        handler?(buffer)
        await Task.yield()
    }

    func emitEvent(_ event: AudioSourceEvent) async {
        eventHandler?(event)
        await Task.yield()
    }
}

final class SourceLifecycleLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [String] = []

    var events: [String] {
        lock.withLock { storedEvents }
    }

    func append(_ event: String) {
        lock.withLock { storedEvents.append(event) }
    }
}
