import AudioToolbox
import AVFoundation
import Foundation
import StenoDomain
import Testing
@testable import StenoExchange

@Suite("Opus CAF writer")
struct OpusCAFWriterTests {
    @Test("transfer export preserves Opus bytes and validates a compressed package")
    func transferPreservesOpus() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "opus.caf")
        _ = try OpusCAFWriter.write(WebMOpusAudio(magicCookie: opusCAFCookie,
            sampleRate: 48_000, channelCount: 2, packets: Array(repeating: Data([0xF8, 0xFF, 0xFE]), count: 100)), to: url)
        let original = try Data(contentsOf: url)
        let expected = try MeetingTransferAudioInspector().prepareCAFSource(at: url)
        let export = try MeetingTransferAudioExport(root: root.appending(path: "encoding"))
        defer { try? export.cleanup() }
        let output = try export.prepare(sourceURL: url, expected: expected)
        #expect(output.url == url)
        #expect(output.source.formatID == kAudioFormatOpus)
        #expect(try Data(contentsOf: output.url) == original)
        let document = try MeetingTransferAudioDocument(logicalTrackID: "track-1", kind: .imported,
            byteCount: expected.byteCount, sha256: expected.byteSHA256, sampleRate: expected.sampleRate,
            channelCount: expected.channelCount, duration: expected.duration)
        let content = try MeetingTransferPackageContent(meeting: makeTransferMeeting(), notes: nil, transcript: nil, audio: [document])
        let archive = try await MeetingTransferArchiveWriter().write(content,
            audioSources: [.init(logicalTrackID: "track-1", sourceURL: output.url)], to: root.appending(path: "export"))
        let validated = try await MeetingTransferArchiveReader().validate(at: archive, validationRoot: root.appending(path: "validation"))
        defer { try? validated.close() }
        #expect(validated.audio.first?.byteSHA256 == expected.byteSHA256)
    }

    @Test("repackages synthetic Opus packets into an AVFoundation-readable CAF")
    func writesReadableCAFWithoutChangingPackets() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "synthetic.caf")
        let packets = [
            Data([0xF8, 0xFF, 0xFE]),
            Data([0xF8]),
        ]
        let audio = WebMOpusAudio(
            magicCookie: opusCAFCookie,
            sampleRate: 48_000,
            channelCount: 2,
            packets: packets
        )

        let result = try OpusCAFWriter.write(audio, to: url)
        let asset = AVURLAsset(url: url)

        #expect(result == .repackagedOpus)
        #expect(try await asset.load(.isReadable))
        let stored = try readCAFPackets(at: url)
        #expect(stored.formatID == kAudioFormatOpus)
        #expect(stored.packetLengths == packets.map(\.count))
    }
}

private let opusCAFCookie = Data([
    0x4F, 0x70, 0x75, 0x73, 0x48, 0x65, 0x61, 0x64,
    0x01, 0x02, 0x38, 0x01, 0x80, 0xBB, 0x00, 0x00,
    0x00, 0x00, 0x00,
])

private func readCAFPackets(at url: URL) throws -> (
    formatID: AudioFormatID,
    packetLengths: [Int]
) {
    var audioFile: AudioFileID?
    try requireNoError(AudioFileOpenURL(
        url as CFURL,
        .readPermission,
        0,
        &audioFile
    ))
    let file = try #require(audioFile)
    defer { AudioFileClose(file) }

    var format = AudioStreamBasicDescription()
    var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    try requireNoError(AudioFileGetProperty(
        file,
        kAudioFilePropertyDataFormat,
        &formatSize,
        &format
    ))
    var packetCount: UInt64 = 0
    var packetCountSize = UInt32(MemoryLayout<UInt64>.size)
    try requireNoError(AudioFileGetProperty(
        file,
        kAudioFilePropertyAudioDataPacketCount,
        &packetCountSize,
        &packetCount
    ))
    var maximumPacketSize: UInt32 = 0
    var maximumPacketSizeSize = UInt32(MemoryLayout<UInt32>.size)
    try requireNoError(AudioFileGetProperty(
        file,
        kAudioFilePropertyPacketSizeUpperBound,
        &maximumPacketSizeSize,
        &maximumPacketSize
    ))

    var lengths: [Int] = []
    for packetIndex in 0..<packetCount {
        var buffer = [UInt8](repeating: 0, count: Int(maximumPacketSize))
        var byteCount = maximumPacketSize
        var packetsToRead: UInt32 = 1
        var description = AudioStreamPacketDescription()
        let status = buffer.withUnsafeMutableBytes { bytes in
            AudioFileReadPacketData(
                file,
                false,
                &byteCount,
                &description,
                Int64(packetIndex),
                &packetsToRead,
                bytes.baseAddress
            )
        }
        try requireNoError(status)
        guard packetsToRead == 1 else {
            throw CAFTestError.unexpectedPacketCount(packetsToRead)
        }
        lengths.append(Int(description.mDataByteSize))
    }
    return (format.mFormatID, lengths)
}

private func requireNoError(_ status: OSStatus) throws {
    guard status == noErr else { throw CAFTestError.osStatus(status) }
}

private enum CAFTestError: Error {
    case osStatus(OSStatus)
    case unexpectedPacketCount(UInt32)
}
