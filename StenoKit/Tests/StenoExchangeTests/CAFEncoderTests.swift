@preconcurrency import AVFAudio
import Darwin
import Foundation
import StenoAudioEncoding
import StenoDomain
import Testing
@testable import StenoExchange

@Suite("Native AAC CAF export")
struct CAFEncoderTests {
    @Test("native encode/decode preserves frames and channels", arguments: [1, 2], [8_000.0, 16_000.0, 44_100.0, 48_000.0])
    func roundTrip(channels: Int, rate: Double) async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("source.caf")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: UInt32(channels)))
        func signal(_ frame: Int, _ channel: Int) -> Double {
            let time = Double(frame) / rate
            guard time > 0.15, time < 480_013 / rate - 0.15 else { return 0 }
            return 0.2 * sin(2 * .pi * Double(440 + 220 * channel) * time + 2 * sin(time * 3.7))
        }
        do {
            let file = try AVAudioFile(forWriting: input, settings: format.settings)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480_013))
            buffer.frameLength = 480_013
            for channel in 0..<channels {
                for frame in 0..<480_013 { buffer.floatChannelData![channel][frame] = Float(signal(frame, channel)) }
            }
            try file.write(from: buffer)
        }
        let original = try Data(contentsOf: input)
        let expected = try MeetingTransferAudioInspector().prepareCAFSource(at: input)
        let export = try MeetingTransferAudioExport(root: root.appendingPathComponent("export"))
        defer { try? export.cleanup() }
        let output = try export.prepare(sourceURL: input, expected: expected)
        #expect(output.url != input)
        #expect(output.source.formatID == kAudioFormatMPEG4AAC)
        #expect(output.source.byteCount < expected.byteCount / 4)
        #expect(output.source.sampleRate == rate)
        #expect(output.source.channelCount == channels)
        #expect(abs(output.source.duration - expected.duration) < 1 / rate)
        let file = try AVAudioFile(forReading: output.url)
        #expect(file.length == 480_013)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192))
        var total: Int64 = 0
        var energy = [Double](repeating: 0, count: channels)
        var referenceEnergy = energy
        var dot = energy
        while total < file.length {
            try file.read(into: buffer, frameCount: UInt32(min(8192, file.length - total)))
            #expect(buffer.frameLength > 0)
            guard buffer.frameLength > 0 else { break }
            for channel in 0..<channels {
                for frame in 0..<Int(buffer.frameLength) {
                    let decoded = Double(buffer.floatChannelData![channel][frame])
                    let reference = signal(Int(total) + frame, channel)
                    energy[channel] += decoded * decoded
                    referenceEnergy[channel] += reference * reference
                    dot[channel] += decoded * reference
                }
            }
            total += Int64(buffer.frameLength)
        }
        #expect(total == 480_013)
        for channel in 0..<channels {
            #expect(energy[channel] > 100)
            #expect(dot[channel] / sqrt(energy[channel] * referenceEnergy[channel]) > 0.97)
        }
        #expect(try Data(contentsOf: input) == original)
        let copied = try export.prepare(sourceURL: output.url, expected: output.source)
        #expect(copied.url == output.url)
        #expect(copied.source.byteSHA256 == output.source.byteSHA256)

        let document = try MeetingTransferAudioDocument(logicalTrackID: "track-1", kind: .micTrack,
            byteCount: output.source.byteCount, sha256: output.source.byteSHA256,
            sampleRate: output.source.sampleRate, channelCount: channels, duration: output.source.duration)
        let content = try MeetingTransferPackageContent(meeting: makeTransferMeeting(), notes: nil, transcript: nil, audio: [document])
        let archive = try await MeetingTransferArchiveWriter().write(content,
            audioSources: [.init(logicalTrackID: "track-1", sourceURL: output.url)], to: root.appendingPathComponent("package"))
        let validated = try await MeetingTransferArchiveReader().validate(at: archive, validationRoot: root.appendingPathComponent("validation"))
        #expect(validated.audio.count == 1)
        #expect(validated.audio.first?.byteSHA256 == output.source.byteSHA256)
        try validated.close()
        try export.cleanup()
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("export").path).isEmpty)
    }

    @Test("encoding rejects a replaced prepared source before creating temporary files")
    func changedSource() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("source.caf")
        let replacement = root.appendingPathComponent("replacement.caf")
        try makeTransferCAF(at: input, sampleRate: 48_000, frameCount: 48_000)
        try makeTransferCAF(at: replacement, sampleRate: 48_000, frameCount: 48_000)
        let expected = try MeetingTransferAudioInspector().prepareCAFSource(at: input)
        #expect(expected.byteCount > 32_768)
        #expect(rename(replacement.path, input.path) == 0)
        let outputRoot = root.appendingPathComponent("export")
        let export = try MeetingTransferAudioExport(root: outputRoot)
        defer { try? export.cleanup() }
        #expect(throws: MeetingTransferArchiveWriterError.sourceIdentityMismatch("source.caf")) {
            _ = try export.prepare(sourceURL: input, expected: expected)
        }
        #expect(!FileManager.default.fileExists(atPath: outputRoot.path))
    }

    @Test("cancellation interrupts streaming; caller cleans partial output")
    func cancellation() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("source.caf"), output = root.appendingPathComponent("output.caf")
        try makeTransferCAF(at: input, sampleRate: 48_000, frameCount: 480_000)
        let source = open(input.path, O_RDONLY), destination = open(output.path, O_CREAT | O_EXCL | O_RDWR, 0o600)
        defer { close(source); close(destination) }
        var checks = 0
        #expect(throws: CancellationError.self) {
            _ = try CAFEncoder.encode(source: source, destination: destination) {
                checks += 1
                if checks == 4 { throw CancellationError() }
            }
        }
        #expect(checks == 4)
        #expect(throws: CAFEncoder.Failure.self) { _ = try CAFEncoder.encode(source: source, destination: source) }
    }
}
