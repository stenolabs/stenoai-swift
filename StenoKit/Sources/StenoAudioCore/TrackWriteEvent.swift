@preconcurrency import AVFAudio
import Foundation

/// Silence occupies one queue slot regardless of gap duration. The writer
/// materializes bounded chunks, so a wake-up cannot flood the ring with silence.
public enum TrackWriteEvent: @unchecked Sendable {
    case buffer(OwnedAudioBuffer)
    case silence(frames: AVAudioFramePosition, format: AVAudioFormat, chunkSize: AVAudioFrameCount)

    func write(to writer: any AudioTrackWriting) async throws -> AudioLevels {
        switch self {
        case .buffer(let owned):
            let levels = AudioLevelMeter.measure(owned.buffer)
            try await writer.write(owned.buffer)
            return levels
        case let .silence(frames, format, chunkSize):
            var remaining = frames
            while remaining > 0 {
                let count = AVAudioFrameCount(min(remaining, AVAudioFramePosition(chunkSize)))
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else {
                    throw CocoaError(.fileWriteOutOfSpace)
                }
                buffer.frameLength = count
                for part in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
                    if let data = part.mData { memset(data, 0, Int(part.mDataByteSize)) }
                }
                try await writer.write(buffer)
                remaining -= AVAudioFramePosition(count)
            }
            return .silence
        }
    }
}
