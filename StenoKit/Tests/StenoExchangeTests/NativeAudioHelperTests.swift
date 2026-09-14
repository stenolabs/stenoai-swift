@preconcurrency import AVFAudio
import AudioToolbox
import CryptoKit
import Darwin
import Foundation
import StenoAudioEncoding
import Testing

@Suite("Native transfer helper")
struct NativeAudioHelperTests {
    @Test("WAV uses the same native AAC encoder and hashes both files", arguments: [1, 2])
    func wave(channels: Int) throws {
        let root = try helperTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source.wav"), output = root.appending(path: "output.caf")
        try helperPCMFile(at: source, sampleRate: 48_000, channelCount: UInt32(channels), frameCount: 48_013)
        let before = try Data(contentsOf: source)
        let result = try convertHelper(source, output)
        #expect(result.codec == "aac")
        #expect(result.operation == "encoded-aac")
        #expect(result.frameCount == 48_013)
        #expect(result.channelCount == channels)
        #expect(result.sourceSHA256 == helperSHA256(before))
        #expect(result.outputSHA256 == helperSHA256(try Data(contentsOf: output)))
        #expect(try Data(contentsOf: source) == before)
        let decoded = try AVAudioFile(forReading: output)
        #expect(decoded.length == result.frameCount)
        #expect(decoded.processingFormat.channelCount == UInt32(channels))
    }

    @Test("native Opus remux preserves packets and decoded timing including pre-skip and end trim")
    func opusTiming() throws {
        let root = try helperTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let encoded = root.appending(path: "tone.caf")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        do {
            let file = try AVAudioFile(forWriting: encoded, settings: [
                AVFormatIDKey: kAudioFormatOpus, AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 96_000])
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_013))
            buffer.frameLength = 96_013
            for channel in 0..<2 {
                for frame in 0..<96_013 {
                    let t = Double(frame) / 48_000
                    buffer.floatChannelData![channel][frame] = t < 0.1 ? 0 : Float(sin(t * 2 * .pi * Double(440 + channel * 220))) * 0.2
                }
            }
            try file.write(from: buffer)
        }
        let native = try helperPackets(encoded)
        #expect(native.priming > 0)
        #expect(native.remainder > 0)
        let source = root.appending(path: "tone.webm"), output = root.appending(path: "remux.caf")
        try helperWebM(packets: native.packets, preSkip: UInt16(native.priming),
            discardPadding: Int64(native.remainder) * 1_000_000_000 / 48_000).write(to: source)
        let original = try Data(contentsOf: source)
        let result = try convertHelper(source, output)
        #expect(result.codec == "opus")
        #expect(result.operation == "repackaged-opus")
        #expect(result.frameCount == 96_013)
        #expect(result.bitRate == nil)
        #expect(try Data(contentsOf: source) == original)
        let repackaged = try helperPackets(output)
        #expect(repackaged.packets == native.packets)
        #expect(repackaged.priming == native.priming)
        #expect(repackaged.remainder == native.remainder)
        let a = try helperDecode(encoded), b = try helperDecode(output)
        #expect(a.count == b.count)
        for channel in 0..<2 {
            #expect(a[channel].count == 96_013)
            #expect(a[channel].count == b[channel].count)
            let error = zip(a[channel], b[channel]).reduce(0.0) { $0 + abs(Double($1.0 - $1.1)) }
            #expect(error / Double(a[channel].count) < 0.00001)
        }
    }

    @Test("capture gaps, overlap, start offset, nonfinal trim, negative trim, lacing and truncation fail explicitly")
    func rejectsUnsupportedWebM() throws {
        let root = try helperTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let packets = Array(repeating: Data([0xF8, 0xFF, 0xFE]), count: 4)
        let cases: [(String, Data)] = [
            ("gap", helperWebM(packets: packets, timestamps: [0, 20, 200, 220])),
            ("overlap", helperWebM(packets: packets, timestamps: [0, 20, 20, 40])),
            ("offset", helperWebM(packets: packets, timestamps: [10, 30, 50, 70])),
            ("trim-before-end", helperWebM(packets: packets, discardPadding: 10_000_000, trimIndex: 1)),
            ("negative-trim", helperWebM(packets: packets, discardPadding: -10_000_000)),
            ("lacing", helperWebM(packets: packets, flags: 0x82)),
            ("truncated", Data(helperWebM(packets: packets).dropLast())),
            ("codec-delay", helperWebM(packets: packets, preSkip: 312, codecDelay: 0)),
        ]
        for (name, bytes) in cases {
            let source = root.appending(path: name + ".webm"), output = root.appending(path: name + ".caf")
            try bytes.write(to: source)
            #expect(throws: WebMOpusReaderError.self) { _ = try convertHelper(source, output) }
            #expect(try Data(contentsOf: source) == bytes)
            // The CLI parent owns this path; there is no child-side pathname cleanup.
            try FileManager.default.removeItem(at: output)
        }
    }

    @Test("streaming accepts more than one million valid Opus packets")
    func longOpusStream() throws {
        let root = try helperTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "long.webm")
        let packet = Data([0xF8, 0xFF, 0xFE])
        let count = 1_000_001
        try helperWebM(packets: Array(repeating: packet, count: count), knownClusterSize: true).write(to: source)
        let fd = open(source.path, O_RDONLY | O_NOFOLLOW)
        #expect(fd >= 0)
        defer { close(fd) }
        var received = 0
        let summary = try WebMOpusReader.stream(from: fd, onHeader: { _ in }, onPacket: { bytes, frames in
            guard bytes == packet, frames == 960 else { throw CocoaError(.fileReadCorruptFile) }
            received += 1
        })
        #expect(received == count)
        #expect(summary.packetCount == count)
        #expect(summary.validFrameCount == Int64(count) * 960)
    }

    @Test("streaming remux stops on cancellation and source mutation cannot succeed")
    func cancellationAndMutation() throws {
        let root = try helperTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source.webm")
        try helperWebM(packets: Array(repeating: Data([0xF8, 0xFF, 0xFE]), count: 100)).write(to: source)
        var checks = 0
        #expect(throws: CancellationError.self) {
            _ = try convertHelper(source, root.appending(path: "cancel.caf")) {
                checks += 1
                if checks == 50 { throw CancellationError() }
            }
        }
        #expect(checks == 50)
        checks = 0
        #expect(throws: (any Error).self) {
            _ = try convertHelper(source, root.appending(path: "mutated.caf")) {
                checks += 1
                if checks == 50 {
                    let fd = open(source.path, O_WRONLY)
                    defer { close(fd) }
                    var byte: UInt8 = 0
                    _ = pwrite(fd, &byte, 1, 0)
                }
            }
        }
    }
}

private func convertHelper(_ source: URL, _ output: URL,
                           checkCancellation: @escaping () throws -> Void = {}) throws -> TransferAudioConverter.Result {
    let inputFD = open(source.path, O_RDONLY | O_NOFOLLOW)
    let outputFD = open(output.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    defer { close(inputFD); close(outputFD) }
    return try TransferAudioConverter.convert(source: inputFD, destination: outputFD, checkCancellation: checkCancellation)
}

private func helperDecode(_ url: URL) throws -> [[Float]] {
    let file = try AVAudioFile(forReading: url)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192))
    var channels = [[Float]](repeating: [], count: Int(file.processingFormat.channelCount))
    var position: Int64 = 0
    while position < file.length {
        try file.read(into: buffer, frameCount: UInt32(min(8192, file.length - position)))
        guard buffer.frameLength > 0 else { break }
        for channel in channels.indices {
            channels[channel].append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![channel], count: Int(buffer.frameLength)))
        }
        position += Int64(buffer.frameLength)
    }
    return channels
}

private func helperPackets(_ url: URL) throws -> (packets: [Data], priming: Int32, remainder: Int32) {
    var opened: AudioFileID?
    #expect(AudioFileOpenURL(url as CFURL, .readPermission, 0, &opened) == noErr)
    let file = try #require(opened)
    defer { AudioFileClose(file) }
    var table = AudioFilePacketTableInfo()
    var size = UInt32(MemoryLayout.size(ofValue: table))
    #expect(AudioFileGetProperty(file, kAudioFilePropertyPacketTableInfo, &size, &table) == noErr)
    var count: UInt64 = 0
    size = UInt32(MemoryLayout.size(ofValue: count))
    #expect(AudioFileGetProperty(file, kAudioFilePropertyAudioDataPacketCount, &size, &count) == noErr)
    var packets: [Data] = []
    for index in 0..<count {
        var bytes = Data(count: 65_536)
        var byteCount = UInt32(bytes.count), packetCount: UInt32 = 1
        var description = AudioStreamPacketDescription()
        let status = bytes.withUnsafeMutableBytes {
            AudioFileReadPacketData(file, false, &byteCount, &description, Int64(index), &packetCount, $0.baseAddress)
        }
        #expect(status == noErr)
        #expect(packetCount == 1)
        packets.append(bytes.prefix(Int(byteCount)))
    }
    return (packets, table.mPrimingFrames, table.mRemainderFrames)
}

private func helperWebM(packets: [Data], preSkip: UInt16 = 0, discardPadding: Int64 = 0,
                        timestamps: [Int]? = nil, trimIndex: Int? = nil,
                        flags: UInt8 = 0x80, codecDelay: UInt64? = nil, knownClusterSize: Bool = false) -> Data {
    func e(_ id: [UInt8], _ payload: Data) -> Data {
        var size = 1
        while payload.count >= (1 << (7 * size)) - 1 { size += 1 }
        let value = UInt64(payload.count) | (UInt64(1) << (7 * size))
        let encoded = (0..<size).reversed().map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
        return Data(id + encoded) + payload
    }
    func uint(_ value: UInt64) -> Data {
        var value = value.bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
    var cookie = Data("OpusHead".utf8)
    cookie.append(contentsOf: [1, 2, UInt8(truncatingIfNeeded: preSkip), UInt8(preSkip >> 8), 0x80, 0xBB, 0, 0, 0, 0, 0])
    var rate = Double(48_000).bitPattern.bigEndian
    let rateData = withUnsafeBytes(of: &rate) { Data($0) }
    let track = e([0xD7], Data([1])) + e([0x83], Data([2])) + e([0x86], Data("A_OPUS".utf8))
        + e([0x63, 0xA2], cookie) + e([0x56, 0xAA], uint(codecDelay ?? UInt64(preSkip) * 1_000_000_000 / 48_000))
        + e([0xE1], e([0xB5], rateData) + e([0x9F], Data([2])))
    var body = e([0x16, 0x54, 0xAE, 0x6B], e([0xAE], track))
    // Unknown-size Segment and Clusters match the MediaRecorder streaming shape.
    for (index, packet) in packets.enumerated() {
        var cluster = e([0xE7], uint(UInt64(timestamps?[index] ?? index * 20)))
        let block = Data([0x81, 0, 0, flags]) + packet
        if discardPadding != 0, index == (trimIndex ?? packets.count - 1) {
            cluster += e([0xA0], e([0xA1], block) + e([0x75, 0xA2], uint(UInt64(bitPattern: discardPadding))))
        } else { cluster += e([0xA3], block) }
        if knownClusterSize {
            body += e([0x1F, 0x43, 0xB6, 0x75], cluster)
        } else {
            body += Data([0x1F, 0x43, 0xB6, 0x75, 0x01]) + Data(repeating: 0xFF, count: 7) + cluster
        }
    }
    return e([0x1A, 0x45, 0xDF, 0xA3], e([0x42, 0x82], Data("webm".utf8)))
        + Data([0x18, 0x53, 0x80, 0x67, 0x01]) + Data(repeating: 0xFF, count: 7) + body
}

private func helperTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "NativeAudioHelperTests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func helperSHA256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func helperPCMFile(at url: URL, sampleRate: Double, channelCount: UInt32, frameCount: UInt32) throws {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channelCount))
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
    buffer.frameLength = frameCount
    for channel in 0..<Int(channelCount) {
        for frame in 0..<Int(frameCount) {
            buffer.floatChannelData![channel][frame] = Float(sin(Double(frame) * 2 * .pi * Double(440 + 220 * channel) / sampleRate)) * 0.2
        }
    }
    try file.write(from: buffer)
}
