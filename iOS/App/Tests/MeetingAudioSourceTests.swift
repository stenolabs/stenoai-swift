import AVFoundation
import Foundation
import StenoDomain
import StenoLibrary
import Testing
@testable import Steno

@Suite("iOS original recording sources")
struct MeetingAudioSourceTests {
    @Test("a saved recording plays without a transcript or duration metadata")
    func recordingWithoutTranscript() async throws {
        let fixture = try await AudioSourceFixture.make()
        defer { fixture.remove() }
        let asset = try fixture.writeAsset(duration: 0)
        let sources = try await MeetingAudioSource.load(in: fixture.library, meetingID: fixture.meeting.id)
        let source = try #require(sources.first)
        #expect(sources.count == 1)
        #expect(source.id == asset.id)
        let audio = try AVAudioPlayer(contentsOf: source.validatedURL())
        #expect(audio.duration > 0)
    }

    @Test("a meeting without registered audio has no playback sources")
    func noRegisteredAudio() async throws {
        let fixture = try await AudioSourceFixture.make()
        defer { fixture.remove() }
        // Unregistered files are never discovered as playback candidates.
        try Data("unregistered".utf8).write(to: fixture.layout.mediaFile(fixture.meeting.id, fileName: "orphan.caf"))
        #expect(try await MeetingAudioSource.load(in: fixture.library, meetingID: fixture.meeting.id).isEmpty)
    }

    @Test("traversal and metadata for another meeting are rejected")
    func invalidMetadata() async throws {
        for variant in 0..<2 {
            let fixture = try await AudioSourceFixture.make()
            defer { fixture.remove() }
            _ = try fixture.writeAsset(
                meetingID: variant == 1 ? MeetingID() : nil,
                fileName: variant == 0 ? "../outside.caf" : "audio.caf",
                writeAudio: false
            )
            await #expect(throws: (any Error).self) {
                try await MeetingAudioSource.load(in: fixture.library, meetingID: fixture.meeting.id)
            }
        }
    }

    @Test("duplicate asset identities are rejected")
    func duplicateIdentity() async throws {
        let fixture = try await AudioSourceFixture.make()
        defer { fixture.remove() }
        let asset = try fixture.writeAsset()
        try JSONEncoder().encode(asset).write(to: fixture.layout.mediaDirectory(fixture.meeting.id).appendingPathComponent("duplicate.json"))
        await #expect(throws: MeetingAudioSourceError.duplicateAsset) {
            try await MeetingAudioSource.load(in: fixture.library, meetingID: fixture.meeting.id)
        }
    }

    @Test("playback revalidates a file replaced with a directory or symbolic link")
    func replacedRecording() async throws {
        for symbolicLink in [false, true] {
            let fixture = try await AudioSourceFixture.make()
            defer { fixture.remove() }
            let asset = try fixture.writeAsset()
            let sources = try await MeetingAudioSource.load(in: fixture.library, meetingID: fixture.meeting.id)
            let source = try #require(sources.first)
            let url = fixture.layout.mediaFile(fixture.meeting.id, fileName: asset.fileName)
            try FileManager.default.removeItem(at: url)
            if symbolicLink {
                let target = fixture.root.appendingPathComponent("outside.caf")
                try Data("outside".utf8).write(to: target)
                try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
            } else {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            }
            #expect(throws: MeetingAudioSourceError.unsafePath) { try source.validatedURL() }
        }
    }

    @Test("a redirected media directory is rejected even when it contains valid audio")
    func symlinkedMediaDirectory() async throws {
        let fixture = try await AudioSourceFixture.make()
        defer { fixture.remove() }
        _ = try fixture.writeAsset()
        let sources = try await MeetingAudioSource.load(in: fixture.library, meetingID: fixture.meeting.id)
        let source = try #require(sources.first)
        let media = fixture.layout.mediaDirectory(fixture.meeting.id)
        let moved = fixture.root.appendingPathComponent("moved-media")
        try FileManager.default.moveItem(at: media, to: moved)
        try FileManager.default.createSymbolicLink(at: media, withDestinationURL: moved)
        #expect(throws: MeetingAudioSourceError.unsafePath) { try source.validatedURL() }
        await #expect(throws: MeetingAudioSourceError.unsafePath) {
            try await MeetingAudioSource.load(in: fixture.library, meetingID: fixture.meeting.id)
        }
    }
}

private struct AudioSourceFixture {
    let root: URL
    let library: Library
    let meeting: Meeting
    var layout: LibraryLayout { library.layout }

    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Steno-AudioSourceTests-\(UUID().uuidString)")
        let library = try Library.open(at: root.appendingPathComponent("Library"))
        let meeting = try await library.createMeeting(title: "Synthetic recording", status: .ready)
        return Self(root: root, library: library, meeting: meeting)
    }

    @discardableResult
    func writeAsset(
        meetingID: MeetingID? = nil, fileName: String = "audio.caf",
        duration: TimeInterval = 0.1, writeAudio: Bool = true
    ) throws -> MediaAsset {
        let asset = MediaAsset(
            meetingID: meetingID ?? meeting.id, kind: .micTrack, sampleRate: 16_000,
            duration: duration, provenanceKey: "synthetic", fileName: fileName
        )
        if writeAudio {
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600))
            buffer.frameLength = 1_600
            let samples = try #require(buffer.floatChannelData)
            samples[0].initialize(repeating: 0, count: 1_600)
            let file = try AVAudioFile(forWriting: layout.mediaFile(meeting.id, fileName: fileName), settings: format.settings)
            try file.write(from: buffer)
        }
        try JSONEncoder().encode(asset).write(to: layout.mediaMetadata(meeting.id, assetID: asset.id))
        return asset
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
