import Foundation
import Darwin
import CryptoKit
import StenoDomain
import Testing
@testable import StenoDemo

#if canImport(AVFoundation)
import AVFoundation
#endif

private struct DemoScript: Decodable {
    let schemaVersion: Int
    let datasetID: String
    let datasetVersion: String
    let rendering: ScriptRendering
    let meetings: [ScriptMeeting]
}

private struct ScriptRendering: Decodable {
    let platform: String
    let sampleRate: Int
    let pcmFormat: String
    let noiseScale: Double
    let noiseW: Double
    let fixedPointFractionBits: Int
    let generator: String
    let generatorCommit: String
    let sourcePatchSHA256: String
    let voice: String
    let voiceRepositoryRevision: String
    let speakers: [ScriptSpeaker]
}

private struct ScriptSpeaker: Decodable, Equatable {
    let label: String
    let speakerReferenceID: UUID
    let modelIndex: Int
    let modelSpeakerID: String
    let gainDB: Double
    let gainNumerator: Int
}

private struct ScriptMeeting: Decodable {
    let itemID: String
    let segments: [ScriptSegment]
}

private struct ScriptSegment: Decodable {
    let start: Double
    let startFrame: Int
    let gainDB: Double
    let gainNumerator: Int
    let speaker: String
    let modelIndex: Int
    let text: String
}

private struct StrictRTTMEntry: Equatable {
    let start: Double
    let duration: Double
    let speakerToken: String

    var end: Double { start + duration }
}

private enum FixtureValidationError: Error, Equatable {
    case scriptMeetingIDs
    case rttmFieldCount(Int)
    case rttmToken
    case rttmItem
    case rttmChannel
    case rttmNumber
    case rttmStart
    case rttmDuration
    case rttmNA
    case rttmSpeaker
    case bundleFileType(String)
    case bundleExecutable(String)
    case bundleSignature(String)
}

private func validateScriptMeetingIDs(_ meetings: [ScriptMeeting], expected: Set<String>) throws {
    let itemIDs = meetings.map(\.itemID)
    guard itemIDs.count == expected.count,
          Set(itemIDs).count == itemIDs.count,
          Set(itemIDs) == expected else {
        throw FixtureValidationError.scriptMeetingIDs
    }
}

private func parseStrictRTTM(
    _ line: Substring,
    itemID: String,
    expectedSpeaker: String
) throws -> StrictRTTMEntry {
    let fields = line.split(whereSeparator: \.isWhitespace)
    guard fields.count == 10 else { throw FixtureValidationError.rttmFieldCount(fields.count) }
    guard fields[0] == "SPEAKER" else { throw FixtureValidationError.rttmToken }
    guard fields[1] == Substring(itemID) else { throw FixtureValidationError.rttmItem }
    guard fields[2] == "1" else { throw FixtureValidationError.rttmChannel }
    guard let start = Double(fields[3]), let duration = Double(fields[4]),
          start.isFinite, duration.isFinite else {
        throw FixtureValidationError.rttmNumber
    }
    guard start >= 0 else { throw FixtureValidationError.rttmStart }
    guard duration > 0 else { throw FixtureValidationError.rttmDuration }
    guard fields[5] == "<NA>", fields[6] == "<NA>",
          fields[8] == "<NA>", fields[9] == "<NA>" else {
        throw FixtureValidationError.rttmNA
    }
    guard fields[7] == Substring(expectedSpeaker) else { throw FixtureValidationError.rttmSpeaker }
    return StrictRTTMEntry(start: start, duration: duration, speakerToken: String(fields[7]))
}

private func overlapStatistics(_ entries: [StrictRTTMEntry]) -> (union: Double, peak: Int) {
    let events = entries.flatMap { [($0.start, 1), ($0.end, -1)] }.sorted {
        if $0.0 != $1.0 { return $0.0 < $1.0 }
        return $0.1 < $1.1
    }
    var active = 0
    var peak = 0
    var union = 0.0
    for index in events.indices {
        active += events[index].1
        peak = max(peak, active)
        if index + 1 < events.count, active > 1 {
            union += events[index + 1].0 - events[index].0
        }
    }
    return (union, peak)
}

private func littleEndianUInt16(_ data: Data, at offset: Int) throws -> UInt16 {
    guard data.count >= offset + 2 else { throw FixtureValidationError.bundleSignature("wav") }
    return UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
}

private func littleEndianUInt32(_ data: Data, at offset: Int) throws -> UInt32 {
    guard data.count >= offset + 4 else { throw FixtureValidationError.bundleSignature("wav") }
    return UInt32(data[offset])
        | UInt32(data[offset + 1]) << 8
        | UInt32(data[offset + 2]) << 16
        | UInt32(data[offset + 3]) << 24
}

private func validateCanonicalPCM16WAV(_ data: Data, sampleRate: Int) throws -> Int64 {
    guard data.count >= 44,
          data[0..<4] == Data("RIFF".utf8),
          data[8..<16] == Data("WAVEfmt ".utf8),
          try littleEndianUInt32(data, at: 4) == UInt32(data.count - 8),
          try littleEndianUInt32(data, at: 16) == 16,
          try littleEndianUInt16(data, at: 20) == 1,
          try littleEndianUInt16(data, at: 22) == 1,
          try littleEndianUInt32(data, at: 24) == UInt32(sampleRate),
          try littleEndianUInt32(data, at: 28) == UInt32(sampleRate * 2),
          try littleEndianUInt16(data, at: 32) == 2,
          try littleEndianUInt16(data, at: 34) == 16,
          data[36..<40] == Data("data".utf8),
          try littleEndianUInt32(data, at: 40) == UInt32(data.count - 44),
          (data.count - 44).isMultiple(of: 2) else {
        throw FixtureValidationError.bundleSignature("wav")
    }
    return Int64((data.count - 44) / 2)
}

private func validateSafeResourceSignature(_ data: Data, descriptor: DemoResourceDescriptor) throws {
    let prefix = Array(data.prefix(4))
    let forbiddenPrefixes: Set<[UInt8]> = [
        [0xcf, 0xfa, 0xed, 0xfe], [0xfe, 0xed, 0xfa, 0xcf],
        [0xca, 0xfe, 0xba, 0xbe], [0xbe, 0xba, 0xfe, 0xca],
        [0x7f, 0x45, 0x4c, 0x46], [0x50, 0x4b, 0x03, 0x04],
    ]
    guard !forbiddenPrefixes.contains(prefix), !data.starts(with: [0x1f, 0x8b]) else {
        throw FixtureValidationError.bundleSignature(descriptor.relativePath)
    }
    if data.count >= 262, data[257..<262] == Data("ustar".utf8) {
        throw FixtureValidationError.bundleSignature(descriptor.relativePath)
    }
    switch descriptor.kind {
    case .audio:
        guard descriptor.relativePath.hasSuffix(".wav") else {
            throw FixtureValidationError.bundleSignature(descriptor.relativePath)
        }
    case .transcript:
        guard descriptor.relativePath.hasSuffix(".json"),
              (try? JSONSerialization.jsonObject(with: data)) != nil else {
            throw FixtureValidationError.bundleSignature(descriptor.relativePath)
        }
    case .note, .report, .attribution:
        guard descriptor.relativePath.hasSuffix(".md"),
              String(data: data, encoding: .utf8) != nil, !data.contains(0) else {
            throw FixtureValidationError.bundleSignature(descriptor.relativePath)
        }
    case .referenceTranscript:
        guard descriptor.relativePath.hasSuffix(".txt"),
              String(data: data, encoding: .utf8) != nil, !data.contains(0) else {
            throw FixtureValidationError.bundleSignature(descriptor.relativePath)
        }
    case .referenceTimeline:
        guard descriptor.relativePath.hasSuffix(".rttm"),
              String(data: data, encoding: .utf8) != nil, !data.contains(0) else {
            throw FixtureValidationError.bundleSignature(descriptor.relativePath)
        }
    }
}

@Suite("Demo manifest")
struct DemoManifestTests {
    @Test("a complete temporary manifest and its resources verify")
    func completeTemporaryManifestVerifies() throws {
        try withTemporaryDemoDataset { root, manifest in
            let resources = try DemoResourceBundle(rootURL: root).verifiedResources(for: manifest)

            #expect(resources.count == 17)
            #expect(resources["transcript-projektauftakt"]?.lastPathComponent == "transcript.json")
        }
    }

    @Test("manifest validation requires one complete, closed resource graph per fixed item")
    func rejectsIncompleteAndUnreferencedBlueprintResources() throws {
        try withTemporaryDemoDataset { _, manifest in
            var missingReference = manifest
            missingReference.meetings[0].runs[0].resourceIDs.removeAll {
                $0 == "reference-rttm-projektauftakt"
            }
            try expectError(.invalidMeetingBlueprint(
                itemID: "projektauftakt",
                reason: "expected exactly one referenceTimeline resource"
            )) {
                try missingReference.validate()
            }

            var duplicateReference = manifest
            duplicateReference.meetings[1].runs[0].resourceIDs.append("attribution")
            try expectError(.invalidMeetingBlueprint(
                itemID: "wochenrunde",
                reason: "duplicate run resource ID attribution"
            )) {
                try duplicateReference.validate()
            }

            var orphan = manifest
            orphan.resources.append(DemoResourceDescriptor(
                id: "orphan",
                kind: .note,
                relativePath: "orphan.md",
                byteCount: 0,
                sha256: String(repeating: "0", count: 64)
            ))
            try expectError(.unreferencedResource(id: "orphan")) {
                try orphan.validate()
            }
        }
    }

    @Test("verified text snapshots and transcript speakers satisfy the install blueprint")
    func rejectsInvalidUTF8AndRuntimeSpeakerReferences() throws {
        try withTemporaryDemoDataset { root, manifest in
            let noteURL = root.appending(path: "projektauftakt/notes.md")
            try Data([0xff, 0xfe]).write(to: noteURL)
            let changed = try manifestWithResourceDigests(manifest, from: root)
            try expectError(.invalidUTF8(resourceID: "notes-projektauftakt")) {
                _ = try DemoResourceBundle(rootURL: root).verifiedResources(for: changed)
            }
        }

        try withTemporaryDemoDataset { root, manifest in
            let meeting = manifest.meetings[0]
            let transcriptURL = root.appending(path: "projektauftakt/transcript.json")
            let transcript = TranscriptRevision(
                id: meeting.transcript.id,
                meetingID: meeting.id,
                createdAt: fixedUTCDate(meeting.transcript.createdAtUTC),
                origin: .demo(DemoProvenance(
                    datasetID: manifest.datasetID,
                    datasetVersion: manifest.datasetVersion,
                    itemID: meeting.itemID
                )),
                turns: [TranscriptTurn(
                    speaker: .cluster(runID: meeting.runs[0].id, clusterID: "speaker"),
                    start: 0,
                    end: 1,
                    segments: []
                )]
            )
            try writeTranscript(transcript, to: transcriptURL)
            let changed = try manifestWithResourceDigests(manifest, from: root)
            try expectError(.invalidTranscript(resourceID: meeting.transcript.resourceID)) {
                _ = try DemoResourceBundle(rootURL: root).verifiedResources(for: changed)
            }
        }
    }

    @Test("manifest validation rejects every malformed structural field")
    func rejectsMalformedStructuralFields() throws {
        try withTemporaryDemoDataset { _, manifest in
            var wrongSchema = manifest
            wrongSchema.schemaVersion = 2
            try expectError(.unsupportedSchemaVersion(2)) {
                try wrongSchema.validate()
            }

            var wrongDataset = manifest
            wrongDataset.datasetID = "different-dataset"
            try expectError(.unexpectedDatasetID("different-dataset")) {
                try wrongDataset.validate()
            }

            var emptyVersion = manifest
            emptyVersion.datasetVersion = " "
            try expectError(.emptyDatasetVersion) {
                try emptyVersion.validate()
            }

            var tooFewMeetings = manifest
            tooFewMeetings.meetings.removeLast()
            try expectError(.invalidMeetingCount(2)) {
                try tooFewMeetings.validate()
            }

            var duplicateMeeting = manifest
            duplicateMeeting.meetings[1].id = duplicateMeeting.meetings[0].id
            try expectError(.duplicateIdentifier(kind: "meeting", value: duplicateMeeting.meetings[0].id.description)) {
                try duplicateMeeting.validate()
            }

            var duplicateRevision = manifest
            duplicateRevision.meetings[1].transcript.id = duplicateRevision.meetings[0].transcript.id
            try expectError(.duplicateIdentifier(kind: "revision", value: duplicateRevision.meetings[0].transcript.id.description)) {
                try duplicateRevision.validate()
            }

            var duplicateMedia = manifest
            duplicateMedia.meetings[1].audio.mediaAssetID = duplicateMedia.meetings[0].audio.mediaAssetID
            try expectError(.duplicateIdentifier(kind: "media", value: duplicateMedia.meetings[0].audio.mediaAssetID.description)) {
                try duplicateMedia.validate()
            }

            var duplicateRun = manifest
            duplicateRun.meetings[1].runs[0].id = duplicateRun.meetings[0].runs[0].id
            try expectError(.duplicateIdentifier(kind: "run", value: duplicateRun.meetings[0].runs[0].id.description)) {
                try duplicateRun.validate()
            }

            var duplicateItem = manifest
            duplicateItem.meetings[1].itemID = duplicateItem.meetings[0].itemID
            try expectError(.duplicateIdentifier(kind: "item", value: duplicateItem.meetings[0].itemID)) {
                try duplicateItem.validate()
            }

            var duplicateResource = manifest
            duplicateResource.resources[1].id = duplicateResource.resources[0].id
            try expectError(.duplicateIdentifier(kind: "resource", value: duplicateResource.resources[0].id)) {
                try duplicateResource.validate()
            }

            var invalidDate = manifest
            invalidDate.meetings[0].createdAtUTC = "2026-08-23T12:00:00+02:00"
            try expectError(.invalidUTCDate("2026-08-23T12:00:00+02:00")) {
                try invalidDate.validate()
            }

            var invalidTitle = manifest
            invalidTitle.meetings[0].title = "Projektauftakt"
            try expectError(.invalidDemoTitle("Projektauftakt")) {
                try invalidTitle.validate()
            }

            var invalidSampleRate = manifest
            invalidSampleRate.meetings[0].audio.sampleRate = 0
            try expectError(.invalidSampleRate(invalidSampleRate.meetings[0].audio.mediaAssetID)) {
                try invalidSampleRate.validate()
            }

            var invalidDuration = manifest
            invalidDuration.meetings[0].audio.duration = 0
            try expectError(.invalidDuration(invalidDuration.meetings[0].audio.mediaAssetID)) {
                try invalidDuration.validate()
            }
        }
    }

    @Test("manifest validation requires the fixed UTC dates for every stable item")
    func rejectsUnexpectedFixedUTCDates() throws {
        try withTemporaryDemoDataset { _, manifest in
            var wrongMeetingDate = manifest
            wrongMeetingDate.meetings[0].createdAtUTC = "2026-08-24T12:00:00Z"
            try expectError(.unexpectedFixedUTCDate(
                itemID: "projektauftakt",
                field: "meeting",
                actual: "2026-08-24T12:00:00Z"
            )) {
                try wrongMeetingDate.validate()
            }

            var wrongTranscriptDate = manifest
            wrongTranscriptDate.meetings[1].transcript.createdAtUTC = "2026-08-24T12:01:00Z"
            try expectError(.unexpectedFixedUTCDate(
                itemID: "wochenrunde",
                field: "transcript",
                actual: "2026-08-24T12:01:00Z"
            )) {
                try wrongTranscriptDate.validate()
            }

            var unknownItem = manifest
            unknownItem.meetings[2].itemID = "unbekannt"
            try expectError(.unknownDemoItemID("unbekannt")) {
                try unknownItem.validate()
            }
        }
    }

    @Test("manifest validation requires the fixed meeting IDs and rejects malformed references")
    func rejectsUnexpectedMeetingIDsAndMalformedReferences() throws {
        try withTemporaryDemoDataset { _, manifest in
            var wrongMeetingID = manifest
            let unexpectedID = MeetingID(
                rawValue: UUID(uuidString: "00000000-0000-7000-8000-000000000099")!
            )
            wrongMeetingID.meetings[0].id = unexpectedID
            try expectError(.unexpectedFixedMeetingID(
                itemID: "projektauftakt",
                actual: unexpectedID
            )) {
                try wrongMeetingID.validate()
            }

            var invalidGenerator = manifest
            invalidGenerator.generator.generator = ""
            try expectError(.invalidGeneratorProvenance) {
                try invalidGenerator.validate()
            }

            var invalidSHA256 = manifest
            invalidSHA256.resources[0].sha256 = "not-a-sha256"
            try expectError(.invalidSHA256(id: invalidSHA256.resources[0].id)) {
                try invalidSHA256.validate()
            }

            var negativeByteCount = manifest
            negativeByteCount.resources[0].byteCount = -1
            try expectError(.invalidResourceDescriptor(negativeByteCount.resources[0].id)) {
                try negativeByteCount.validate()
            }

            var unknownResource = manifest
            unknownResource.meetings[0].audio.resourceID = "missing-audio"
            try expectError(.unknownResourceID("missing-audio")) {
                try unknownResource.validate()
            }

            var wrongResourceKind = manifest
            let transcriptResourceID = wrongResourceKind.meetings[0].transcript.resourceID
            let index = wrongResourceKind.resources.firstIndex { $0.id == transcriptResourceID }!
            wrongResourceKind.resources[index].kind = .note
            try expectError(.unexpectedResourceKind(
                id: transcriptResourceID,
                expected: .transcript,
                actual: .note
            )) {
                try wrongResourceKind.validate()
            }
        }
    }

    @Test("resource verification rejects transcript schema and creation-time mismatches")
    func rejectsTranscriptSchemaAndCreationTimeMismatches() throws {
        try withTemporaryDemoDataset { root, manifest in
            let meeting = manifest.meetings[0]
            let transcriptURL = root.appending(path: "projektauftakt/transcript.json")
            let wrongSchema = TranscriptRevision(
                schemaVersion: 2,
                id: meeting.transcript.id,
                meetingID: meeting.id,
                createdAt: fixedUTCDate(meeting.transcript.createdAtUTC),
                origin: .demo(DemoProvenance(
                    datasetID: manifest.datasetID,
                    datasetVersion: manifest.datasetVersion,
                    itemID: meeting.itemID
                )),
                turns: []
            )
            try writeTranscript(wrongSchema, to: transcriptURL)
            let mismatchManifest = try manifestWithResourceDigests(manifest, from: root)
            try expectError(.unsupportedTranscriptSchemaVersion(
                resourceID: meeting.transcript.resourceID,
                actual: 2
            )) {
                _ = try DemoResourceBundle(rootURL: root).verifiedResources(for: mismatchManifest)
            }
        }

        try withTemporaryDemoDataset { root, manifest in
            let meeting = manifest.meetings[1]
            let transcriptURL = root.appending(path: "wochenrunde/transcript.json")
            let wrongCreationTime = TranscriptRevision(
                id: meeting.transcript.id,
                meetingID: meeting.id,
                createdAt: fixedUTCDate("2026-08-23T12:01:00Z"),
                origin: .demo(DemoProvenance(
                    datasetID: manifest.datasetID,
                    datasetVersion: manifest.datasetVersion,
                    itemID: meeting.itemID
                )),
                turns: []
            )
            try writeTranscript(wrongCreationTime, to: transcriptURL)
            let mismatchManifest = try manifestWithResourceDigests(manifest, from: root)
            try expectError(.unexpectedTranscriptCreatedAt(
                resourceID: meeting.transcript.resourceID
            )) {
                _ = try DemoResourceBundle(rootURL: root).verifiedResources(for: mismatchManifest)
            }
        }

        try withTemporaryDemoDataset { root, manifest in
            let transcriptURL = root.appending(path: "projektauftakt/transcript.json")
            try Data("not JSON".utf8).write(to: transcriptURL)
            let mismatchManifest = try manifestWithResourceDigests(manifest, from: root)
            try expectError(.invalidTranscript(resourceID: "transcript-projektauftakt")) {
                _ = try DemoResourceBundle(rootURL: root).verifiedResources(for: mismatchManifest)
            }
        }
    }

    @Test("resource verification closes root, component, and final file types")
    func rejectsUnsafeResourceFileTypes() throws {
        try withTemporaryDemoDataset { root, manifest in
            let rootLink = root.deletingLastPathComponent().appending(
                path: "demo-root-link-\(UUID().uuidString)"
            )
            defer { try? FileManager.default.removeItem(at: rootLink) }
            try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: root)
            try expectError(.symbolicLink(rootLink.lastPathComponent)) {
                _ = try DemoResourceBundle(rootURL: rootLink).verifiedResources(for: manifest)
            }
        }

        try withTemporaryDemoDataset { root, manifest in
            let outside = root.deletingLastPathComponent().appending(
                path: "demo-external-\(UUID().uuidString)"
            )
            let linkedDirectory = root.appending(path: "linked-external")
            defer { try? FileManager.default.removeItem(at: outside) }
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: outside)
            var linkedIntermediate = manifest
            linkedIntermediate.resources[0].relativePath = "linked-external/transcript.json"
            try expectError(.symbolicLink("linked-external/transcript.json")) {
                _ = try DemoResourceBundle(rootURL: root).verifiedResources(for: linkedIntermediate)
            }
        }

        try withTemporaryDemoDataset { root, manifest in
            var finalDirectory = manifest
            finalDirectory.resources[0].relativePath = "projektauftakt"
            try expectError(.invalidResourceFileType(
                id: finalDirectory.resources[0].id,
                path: "projektauftakt"
            )) {
                _ = try DemoResourceBundle(rootURL: root).verifiedResources(for: finalDirectory)
            }

            let fifoURL = root.appending(path: "resource.fifo")
            #expect(mkfifo(fifoURL.path, 0o600) == 0)
            var specialFile = manifest
            specialFile.resources[0].relativePath = "resource.fifo"
            try expectError(.invalidResourceFileType(
                id: specialFile.resources[0].id,
                path: "resource.fifo"
            )) {
                _ = try DemoResourceBundle(rootURL: root).verifiedResources(for: specialFile)
            }

            var nestedTraversal = manifest
            nestedTraversal.resources[0].relativePath = "projektauftakt/../../outside"
            try expectError(.invalidResourcePath("projektauftakt/../../outside")) {
                _ = try DemoResourceBundle(rootURL: root).verifiedResources(for: nestedTraversal)
            }
        }
    }

    @Test("manifest verification rejects a final-file swap after metadata inspection")
    func rejectsManifestSwapAfterMetadataInspection() throws {
        try withTemporaryDemoDataset { root, manifest in
            let manifestURL = root.appending(path: "manifest.json")
            let manifestData = try JSONEncoder().encode(manifest)
            try manifestData.write(to: manifestURL)
            let outside = root.deletingLastPathComponent().appending(
                path: "demo-manifest-swap-\(UUID().uuidString)"
            )
            defer { try? FileManager.default.removeItem(at: outside) }
            try manifestData.write(to: outside)
            let swap = DemoBundlePathSwap(
                resourceID: "manifest",
                relativePath: "manifest.json",
                componentIndex: 0,
                sourceURL: manifestURL,
                destinationURL: outside
            )
            let bundle = DemoResourceBundle(rootURL: root, checkpoint: swap.call)

            try expectError(.manifestReadFailed(path: "manifest.json")) {
                _ = try bundle.loadVerifiedDataset()
            }
            #expect(swap.didSwap)
            #expect(try Data(contentsOf: outside) == manifestData)
        }
    }

    @Test("resource verification rejects an intermediate-directory swap after metadata inspection")
    func rejectsIntermediateDirectorySwapAfterMetadataInspection() throws {
        try withTemporaryDemoDataset { root, manifest in
            let source = root.appending(path: "projektauftakt", directoryHint: .isDirectory)
            let moved = root.appending(
                path: "projektauftakt-original",
                directoryHint: .isDirectory
            )
            let swap = DemoBundlePathSwap(
                resourceID: "transcript-projektauftakt",
                relativePath: "projektauftakt/transcript.json",
                componentIndex: 0,
                sourceURL: source,
                destinationURL: moved,
                moveSourceToDestination: true
            )
            let bundle = DemoResourceBundle(rootURL: root, checkpoint: swap.call)

            try expectError(.resourceReadFailed(
                id: "transcript-projektauftakt",
                path: "projektauftakt/transcript.json"
            )) {
                _ = try bundle.verifiedResources(for: manifest)
            }
            #expect(swap.didSwap)
        }
    }

    @Test("resource verification reads every install resource exactly once")
    func readsEveryResourceOnlyOnce() throws {
        try withTemporaryDemoDataset { root, manifest in
            let reader = TranscriptReadSpy()
            let bundle = DemoResourceBundle(rootURL: root, dataReader: reader.read)

            _ = try bundle.verifiedResources(for: manifest)

            #expect(reader.transcriptReadCount == 3)
            #expect(reader.resourceReadCounts.count == manifest.resources.count)
            #expect(reader.resourceReadCounts.values.allSatisfy { $0 == 1 })
        }
    }

    @Test("resource verification reports injected data read failures precisely")
    func reportsInjectedResourceReadFailures() throws {
        try withTemporaryDemoDataset { root, manifest in
            let bundle = DemoResourceBundle(rootURL: root, dataReader: { source in
                if source.url.lastPathComponent == "notes.md" {
                    throw InjectedDataReadError.forced
                }
                return try source.read()
            })
            try expectError(.resourceReadFailed(
                id: "notes-projektauftakt",
                path: "projektauftakt/notes.md"
            )) {
                _ = try bundle.verifiedResources(for: manifest)
            }
        }
    }

    @Test("manifest loading preserves structural errors and maps only read failures")
    func preservesManifestStructuralErrorsAndMapsReadFailures() throws {
        try withTemporaryDemoDataset { root, manifest in
            let regularRoot = root.appending(path: "not-a-directory")
            try Data("root".utf8).write(to: regularRoot)
            try expectError(.invalidBundleRoot(path: regularRoot.path)) {
                _ = try DemoResourceBundle(rootURL: regularRoot).loadAndVerifyManifest()
            }

            let blocker = root.appending(path: "blocker")
            try Data("not-a-directory".utf8).write(to: blocker)
            var intermediateFile = manifest
            intermediateFile.resources[0].relativePath = "blocker/transcript.json"
            try expectError(.invalidResourceDirectoryComponent("blocker/transcript.json")) {
                _ = try DemoResourceBundle(rootURL: root).verifiedResources(for: intermediateFile)
            }

            let manifestURL = root.appending(path: "manifest.json")
            try JSONEncoder().encode(manifest).write(to: manifestURL)
            let failingManifestReader = DemoResourceBundle(rootURL: root, dataReader: { source in
                if source.url.lastPathComponent == "manifest.json" {
                    throw InjectedDataReadError.forced
                }
                return try source.read()
            })
            try expectError(.manifestReadFailed(path: "manifest.json")) {
                _ = try failingManifestReader.loadAndVerifyManifest()
            }
        }
    }

    @Test("manifest loading distinguishes valid data from invalid manifest bytes")
    func loadsManifestWithManifestSpecificErrors() throws {
        try withTemporaryDemoDataset { root, manifest in
            let manifestURL = root.appending(path: "manifest.json")
            try JSONEncoder().encode(manifest).write(to: manifestURL)
            let loaded = try DemoResourceBundle(rootURL: root).loadAndVerifyManifest()
            #expect(loaded == manifest)

            try Data("not JSON".utf8).write(to: manifestURL)
            try expectError(.invalidManifest(path: "manifest.json")) {
                _ = try DemoResourceBundle(rootURL: root).loadAndVerifyManifest()
            }
        }
    }

    @Test("resource verification rejects paths, links, content changes, and missing files")
    func rejectsInvalidResources() throws {
        try withTemporaryDemoDataset { root, manifest in
            let bundle = DemoResourceBundle(rootURL: root)

            var absolutePath = manifest
            absolutePath.resources[0].relativePath = "/tmp/outside"
            try expectError(.invalidResourcePath("/tmp/outside")) {
                _ = try bundle.verifiedResources(for: absolutePath)
            }

            var parentPath = manifest
            parentPath.resources[0].relativePath = "../outside"
            try expectError(.invalidResourcePath("../outside")) {
                _ = try bundle.verifiedResources(for: parentPath)
            }

            var missing = manifest
            missing.resources[0].relativePath = "missing.txt"
            try expectError(.missingResource(id: missing.resources[0].id, path: "missing.txt")) {
                _ = try bundle.verifiedResources(for: missing)
            }

            let linkedPath = root.appending(path: "linked.txt")
            try FileManager.default.createSymbolicLink(
                at: linkedPath,
                withDestinationURL: root.appending(path: "notes.md")
            )
            var linked = manifest
            linked.resources[0].relativePath = "linked.txt"
            try expectError(.symbolicLink("linked.txt")) {
                _ = try bundle.verifiedResources(for: linked)
            }

            let danglingLinkPath = root.appending(path: "dangling-link.txt")
            try FileManager.default.createSymbolicLink(
                at: danglingLinkPath,
                withDestinationURL: root.appending(path: "not-present.txt")
            )
            var danglingLink = manifest
            danglingLink.resources[0].relativePath = "dangling-link.txt"
            try expectError(.symbolicLink("dangling-link.txt")) {
                _ = try bundle.verifiedResources(for: danglingLink)
            }

            let changedURL = root.appending(path: manifest.resources[0].relativePath)
            try Data("changed".utf8).write(to: changedURL)
            try expectError(.wrongByteCount(
                id: manifest.resources[0].id,
                expected: manifest.resources[0].byteCount,
                actual: 7
            )) {
                _ = try bundle.verifiedResources(for: manifest)
            }
        }

        try withTemporaryDemoDataset { root, manifest in
            let path = root.appending(path: manifest.resources[0].relativePath)
            try Data(repeating: 0x42, count: Int(manifest.resources[0].byteCount)).write(to: path)
            try expectError(.wrongSHA256(id: manifest.resources[0].id)) {
                _ = try DemoResourceBundle(rootURL: root).verifiedResources(for: manifest)
            }
        }
    }

    @Test("resource verification rejects transcripts whose identifiers or demo provenance disagree")
    func rejectsTranscriptMismatches() throws {
        try withTemporaryDemoDataset { root, manifest in
            let meeting = manifest.meetings[0]
            let transcriptURL = root.appending(path: "projektauftakt/transcript.json")

            let wrongMeeting = TranscriptRevision(
                id: meeting.transcript.id,
                meetingID: manifest.meetings[1].id,
                createdAt: fixedUTCDate(meeting.transcript.createdAtUTC),
                origin: .demo(DemoProvenance(
                    datasetID: manifest.datasetID,
                    datasetVersion: manifest.datasetVersion,
                    itemID: meeting.itemID
                )),
                turns: []
            )
            try writeTranscript(wrongMeeting, to: transcriptURL)
            let mismatchManifest = try manifestWithResourceDigests(manifest, from: root)
            try expectError(.transcriptMismatch(
                resourceID: meeting.transcript.resourceID,
                field: "meetingID"
            )) {
                _ = try DemoResourceBundle(rootURL: root).verifiedResources(for: mismatchManifest)
            }
        }

        try withTemporaryDemoDataset { root, manifest in
            let meeting = manifest.meetings[0]
            let transcriptURL = root.appending(path: "projektauftakt/transcript.json")
            let wrongRevision = TranscriptRevision(
                id: manifest.meetings[1].transcript.id,
                meetingID: meeting.id,
                createdAt: fixedUTCDate(meeting.transcript.createdAtUTC),
                origin: .demo(DemoProvenance(
                    datasetID: manifest.datasetID,
                    datasetVersion: manifest.datasetVersion,
                    itemID: meeting.itemID
                )),
                turns: []
            )
            try writeTranscript(wrongRevision, to: transcriptURL)
            let mismatchManifest = try manifestWithResourceDigests(manifest, from: root)
            try expectError(.transcriptMismatch(
                resourceID: meeting.transcript.resourceID,
                field: "revisionID"
            )) {
                _ = try DemoResourceBundle(rootURL: root).verifiedResources(for: mismatchManifest)
            }
        }

        try withTemporaryDemoDataset { root, manifest in
            let meeting = manifest.meetings[0]
            let transcriptURL = root.appending(path: "projektauftakt/transcript.json")
            let wrongProvenance = TranscriptRevision(
                id: meeting.transcript.id,
                meetingID: meeting.id,
                createdAt: fixedUTCDate(meeting.transcript.createdAtUTC),
                origin: .demo(DemoProvenance(
                    datasetID: manifest.datasetID,
                    datasetVersion: manifest.datasetVersion,
                    itemID: "different-item"
                )),
                turns: []
            )
            try writeTranscript(wrongProvenance, to: transcriptURL)
            let mismatchManifest = try manifestWithResourceDigests(manifest, from: root)
            try expectError(.transcriptMismatch(
                resourceID: meeting.transcript.resourceID,
                field: "demoProvenance"
            )) {
                _ = try DemoResourceBundle(rootURL: root).verifiedResources(for: mismatchManifest)
            }
        }
    }

    @Test("the bundled fixture verifies every byte, opens audio, and excludes generator inputs")
    func bundledFixtureVerifiesAndContainsOnlyRedistributableOutputs() throws {
        let bundle = try DemoResourceBundle.bundled()
        let manifest = try bundle.loadAndVerifyManifest()
        let resources = try bundle.verifiedResources(for: manifest)
        #expect(resources.count == manifest.resources.count)
        let resourcePaths = manifest.resources.map(\.relativePath)
        let expectedFiles = Set(resourcePaths).union(["manifest.json"])
        #expect(resourcePaths.count == Set(resourcePaths).count)

        var actualFiles: [String] = []
        let enumerator = try #require(FileManager.default.enumerator(atPath: bundle.rootURL.path))
        while let relativePath = enumerator.nextObject() as? String {
            let url = bundle.rootURL.appending(path: relativePath)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let type = try #require(attributes[.type] as? FileAttributeType)
            if type == .typeDirectory { continue }
            guard type == .typeRegular else { throw FixtureValidationError.bundleFileType(relativePath) }
            let permissions = try #require(attributes[.posixPermissions] as? NSNumber).intValue
            guard permissions & 0o111 == 0 else { throw FixtureValidationError.bundleExecutable(relativePath) }
            actualFiles.append(relativePath)
        }
        #expect(actualFiles.count == Set(actualFiles).count)
        #expect(Set(actualFiles) == expectedFiles)

        let descriptorsByPath = Dictionary(uniqueKeysWithValues: manifest.resources.map { ($0.relativePath, $0) })
        for relativePath in resourcePaths {
            let descriptor = try #require(descriptorsByPath[relativePath])
            let url = bundle.rootURL.appending(path: relativePath)
            let data = try Data(contentsOf: url)
            try validateSafeResourceSignature(data, descriptor: descriptor)
            if descriptor.kind == .audio {
                let meeting = try #require(manifest.meetings.first { $0.audio.resourceID == descriptor.id })
                let integerSampleRate = Int(meeting.audio.sampleRate)
                #expect(Double(integerSampleRate) == meeting.audio.sampleRate)
                let headerFrameCount = try validateCanonicalPCM16WAV(data, sampleRate: integerSampleRate)
                let expectedFrameCount = Int64((meeting.audio.duration * meeting.audio.sampleRate).rounded())
                #expect(headerFrameCount == expectedFrameCount)

                #if canImport(AVFoundation)
                let audio = try AVAudioFile(forReading: url)
                let description = audio.fileFormat.streamDescription.pointee
                #expect(description.mFormatID == kAudioFormatLinearPCM)
                #expect(description.mSampleRate == meeting.audio.sampleRate)
                #expect(description.mChannelsPerFrame == 1)
                #expect(description.mBitsPerChannel == 16)
                #expect(description.mBytesPerFrame == 2)
                #expect(description.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0)
                #expect(description.mFormatFlags & kAudioFormatFlagIsFloat == 0)
                #expect(description.mFormatFlags & kAudioFormatFlagIsBigEndian == 0)
                #expect(audio.length == expectedFrameCount)
                #endif
            }
        }
    }

    @Test("resource signatures reject renamed executables, archives, and models")
    func resourceSignatureAllowlistRejectsBinaryDisguises() throws {
        let bundle = try DemoResourceBundle.bundled()
        let manifest = try bundle.loadAndVerifyManifest()
        let resources = try bundle.verifiedResources(for: manifest)
        let note = try #require(manifest.resources.first { $0.kind == .note })
        var tar = Data(repeating: 0, count: 262)
        tar.replaceSubrange(257..<262, with: Data("ustar".utf8))
        let disguisedBinaries: [Data] = [
            Data([0xcf, 0xfa, 0xed, 0xfe]),
            Data([0x7f, 0x45, 0x4c, 0x46]),
            Data([0x50, 0x4b, 0x03, 0x04]),
            Data([0x1f, 0x8b, 0x08]),
            Data([0x08, 0x03, 0x12, 0x00]),
            tar,
        ]
        for data in disguisedBinaries {
            #expect(throws: FixtureValidationError.self) {
                try validateSafeResourceSignature(data, descriptor: note)
            }
        }
        for descriptor in manifest.resources {
            let resource = try #require(resources[descriptor.id])
            var renamed = descriptor
            renamed.relativePath = "renamed.bin"
            #expect(throws: FixtureValidationError.self) {
                try validateSafeResourceSignature(Data(contentsOf: resource), descriptor: renamed)
            }
        }
    }

    @Test("strict RTTM parsing rejects every malformed field and handles touching turns")
    func strictRTTMValidationMatrix() throws {
        let valid = "SPEAKER item 1 0.000000 1.000000 <NA> <NA> speaker-a <NA> <NA>"
        let malformed = [
            "SPEAKER item 1 0.000000 1.000000 <NA> <NA> speaker-a <NA>",
            valid + " extra",
            "WRONG item 1 0.000000 1.000000 <NA> <NA> speaker-a <NA> <NA>",
            "SPEAKER other 1 0.000000 1.000000 <NA> <NA> speaker-a <NA> <NA>",
            "SPEAKER item 2 0.000000 1.000000 <NA> <NA> speaker-a <NA> <NA>",
            "SPEAKER item 1 nope 1.000000 <NA> <NA> speaker-a <NA> <NA>",
            "SPEAKER item 1 NaN 1.000000 <NA> <NA> speaker-a <NA> <NA>",
            "SPEAKER item 1 inf 1.000000 <NA> <NA> speaker-a <NA> <NA>",
            "SPEAKER item 1 -0.1 1.000000 <NA> <NA> speaker-a <NA> <NA>",
            "SPEAKER item 1 0.000000 nope <NA> <NA> speaker-a <NA> <NA>",
            "SPEAKER item 1 0.000000 NaN <NA> <NA> speaker-a <NA> <NA>",
            "SPEAKER item 1 0.000000 inf <NA> <NA> speaker-a <NA> <NA>",
            "SPEAKER item 1 0.000000 0 <NA> <NA> speaker-a <NA> <NA>",
            "SPEAKER item 1 0.000000 -1 <NA> <NA> speaker-a <NA> <NA>",
            "SPEAKER item 1 0.000000 1.000000 wrong <NA> speaker-a <NA> <NA>",
            "SPEAKER item 1 0.000000 1.000000 <NA> wrong speaker-a <NA> <NA>",
            "SPEAKER item 1 0.000000 1.000000 <NA> <NA> speaker-a wrong <NA>",
            "SPEAKER item 1 0.000000 1.000000 <NA> <NA> speaker-a <NA> wrong",
            "SPEAKER item 1 0.000000 1.000000 <NA> <NA> speaker-b <NA> <NA>",
        ]
        for line in malformed {
            #expect(throws: FixtureValidationError.self) {
                try parseStrictRTTM(Substring(line), itemID: "item", expectedSpeaker: "speaker-a")
            }
        }

        let first = try parseStrictRTTM(Substring(valid), itemID: "item", expectedSpeaker: "speaker-a")
        let touching = try parseStrictRTTM(
            "SPEAKER item 1 1.000000 1.000000 <NA> <NA> speaker-a <NA> <NA>",
            itemID: "item",
            expectedSpeaker: "speaker-a"
        )
        let statistics = overlapStatistics([first, touching])
        #expect(statistics.union == 0)
        #expect(statistics.peak == 1)
    }

    @Test("script meetings form one exact unique set")
    func scriptMeetingSetRejectsDuplicatesAdditionsAndMissingItems() throws {
        let expected: Set<String> = ["projektauftakt", "wochenrunde", "produktinterview"]
        let emptySegments: [ScriptSegment] = []
        let valid = expected.sorted().map { ScriptMeeting(itemID: $0, segments: emptySegments) }
        try validateScriptMeetingIDs(valid, expected: expected)
        for invalid in [
            Array(valid.dropLast()),
            valid + [ScriptMeeting(itemID: "extra", segments: emptySegments)],
            [valid[0], valid[0], valid[2]],
        ] {
            #expect(throws: FixtureValidationError.scriptMeetingIDs) {
                try validateScriptMeetingIDs(invalid, expected: expected)
            }
        }
    }

    @Test("the script, transcript, text reference, and RTTM describe the same fixture turns")
    func fixtureResourcesStaySynchronized() throws {
        let repositoryRoot = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scriptURL = repositoryRoot.appending(path: "scripts/demo/demo-script.json")
        let scriptData = try Data(contentsOf: scriptURL)
        let script = try JSONDecoder().decode(DemoScript.self, from: scriptData)
        let bundle = try DemoResourceBundle.bundled()
        let manifest = try bundle.loadAndVerifyManifest()
        let resources = try bundle.verifiedResources(for: manifest)
        let expectedItems = Set(manifest.meetings.map(\.itemID))
        try validateScriptMeetingIDs(script.meetings, expected: expectedItems)
        #expect(script.schemaVersion == 1)
        #expect(script.datasetID == manifest.datasetID)
        #expect(script.datasetVersion == manifest.datasetVersion)
        let scriptDigest = SHA256.hash(data: scriptData).map { String(format: "%02x", $0) }.joined()
        #expect(scriptDigest == manifest.generator.inputScriptSHA256)
        #expect(script.rendering.platform == "macOS arm64 only")
        #expect(script.rendering.sampleRate == 22_050)
        #expect(script.rendering.pcmFormat == "PCM16 mono little-endian")
        #expect(script.rendering.noiseScale == 0)
        #expect(script.rendering.noiseW == 0)
        #expect(script.rendering.fixedPointFractionBits == 16)
        #expect(script.rendering.generator == manifest.generator.generator)
        #expect(script.rendering.generatorCommit == manifest.generator.generatorRevision)
        let sourcePatchURL = repositoryRoot.appending(path: "scripts/demo/espeak-ng-no-sonic.patch")
        let sourcePatchDigest = SHA256.hash(data: try Data(contentsOf: sourcePatchURL)).map { String(format: "%02x", $0) }.joined()
        #expect(sourcePatchDigest == script.rendering.sourcePatchSHA256)
        #expect(script.rendering.voice == manifest.generator.model)
        #expect(script.rendering.voiceRepositoryRevision == manifest.generator.modelRevision)
        #expect(manifest.generator.speakerIDs == script.rendering.speakers.map(\.modelSpeakerID))
        #expect(manifest.generator.mixParameters["sampleRate"] == 22_050)
        #expect(manifest.generator.mixParameters["fixedPointFractionBits"] == 16)

        let expectedSpeakers = [
            ScriptSpeaker(label: "Sprecherin A", speakerReferenceID: UUID(uuidString: "00000000-0000-7000-8000-00000000aa01")!, modelIndex: 0, modelSpeakerID: "2422", gainDB: 0, gainNumerator: 65_536),
            ScriptSpeaker(label: "Sprecher B", speakerReferenceID: UUID(uuidString: "00000000-0000-7000-8000-00000000aa02")!, modelIndex: 1, modelSpeakerID: "4536", gainDB: -1, gainNumerator: 58_409),
            ScriptSpeaker(label: "Sprecherin C", speakerReferenceID: UUID(uuidString: "00000000-0000-7000-8000-00000000aa03")!, modelIndex: 5, modelSpeakerID: "6507", gainDB: -0.5, gainNumerator: 61_870),
        ]
        #expect(script.rendering.speakers == expectedSpeakers)
        for (key, value) in [
            "speakerAGainDB": 0.0, "speakerBGainDB": -1.0, "speakerCGainDB": -0.5,
            "speakerAGainNumerator": 65_536.0, "speakerBGainNumerator": 58_409.0,
            "speakerCGainNumerator": 61_870.0,
        ] {
            #expect(manifest.generator.mixParameters[key] == value)
        }

        let fixedIndices = ["projektauftakt": 1, "wochenrunde": 2, "produktinterview": 3]
        let speakerTokens = ["Sprecherin A": "speaker-a", "Sprecher B": "speaker-b", "Sprecherin C": "speaker-c"]

        for meeting in manifest.meetings {
            let scripted = try #require(script.meetings.first { $0.itemID == meeting.itemID })
            let fixedIndex = try #require(fixedIndices[meeting.itemID])
            #expect(meeting.id.rawValue == UUID(uuidString: String(format: "00000000-0000-7000-8000-%012d", fixedIndex)))
            #expect(meeting.transcript.id.rawValue == UUID(uuidString: String(format: "00000000-0000-7000-8000-%012d", 100 + fixedIndex)))
            #expect(meeting.audio.mediaAssetID.rawValue == UUID(uuidString: String(format: "00000000-0000-7000-8000-%012d", 200 + fixedIndex)))
            #expect(meeting.runs.first?.id.rawValue == UUID(uuidString: String(format: "00000000-0000-7000-8000-%012d", 300 + fixedIndex)))
            let transcriptURL = try #require(resources[meeting.transcript.resourceID])
            let transcript = try JSONDecoder().decode(TranscriptRevision.self, from: Data(contentsOf: transcriptURL))
            #expect(transcript.meetingID == meeting.id)
            #expect(transcript.id == meeting.transcript.id)
            #expect(transcript.createdAt == fixedUTCDate(meeting.transcript.createdAtUTC))
            if case .demo(let provenance) = transcript.origin {
                #expect(provenance == DemoProvenance(datasetID: manifest.datasetID, datasetVersion: manifest.datasetVersion, itemID: meeting.itemID))
            } else {
                Issue.record("Expected demo transcript origin")
            }
            let textURL = try #require(resources["reference-text-\(meeting.itemID)"])
            let rttmURL = try #require(resources["reference-rttm-\(meeting.itemID)"])
            let textLines = try String(contentsOf: textURL, encoding: .utf8).split(separator: "\n").map(String.init)
            let rttmLines = try String(contentsOf: rttmURL, encoding: .utf8).split(separator: "\n")

            #expect(scripted.segments.count == transcript.turns.count)
            #expect(scripted.segments.count == textLines.count)
            #expect(scripted.segments.count == rttmLines.count)
            var parsedRTTM: [StrictRTTMEntry] = []
            for (index, segment) in scripted.segments.enumerated() {
                let scriptSpeaker = try #require(script.rendering.speakers.first { $0.label == segment.speaker })
                #expect(segment.modelIndex == scriptSpeaker.modelIndex)
                #expect(segment.gainDB == scriptSpeaker.gainDB)
                #expect(segment.gainNumerator == scriptSpeaker.gainNumerator)
                #expect(Double(segment.startFrame) / Double(script.rendering.sampleRate) == segment.start)
                let turn = transcript.turns[index]
                let imported: ImportedSpeakerTextLabel
                if case .importedTextLabel(let value)? = turn.speaker {
                    imported = value
                } else {
                    throw DemoLibraryError.invalidTranscript(resourceID: meeting.transcript.resourceID)
                }
                #expect(imported.id == scriptSpeaker.speakerReferenceID)
                #expect(imported.text == scriptSpeaker.label)
                #expect(imported.wasConfirmedAtSource == false)
                #expect(turn.segments.count == 1)
                let transcriptSegment = try #require(turn.segments.first)
                #expect(transcriptSegment.text == segment.text)
                #expect(transcriptSegment.start == turn.start)
                #expect(transcriptSegment.end == turn.end)
                #expect(transcriptSegment.words.isEmpty)
                #expect(textLines[index] == "\(segment.speaker): \(segment.text)")
                #expect(turn.start == segment.start)
                let expectedToken = try #require(speakerTokens[segment.speaker])
                let rttm = try parseStrictRTTM(rttmLines[index], itemID: meeting.itemID, expectedSpeaker: expectedToken)
                parsedRTTM.append(rttm)
                #expect(abs(rttm.start - segment.start) <= 0.000_000_5)
                #expect(abs(rttm.duration - (turn.end - turn.start)) <= 0.000_000_5)
                #expect(abs(rttm.end - turn.end) <= 0.000_001)
            }
            let statistics = overlapStatistics(parsedRTTM)
            if meeting.itemID == "projektauftakt" {
                #expect(abs(statistics.union - 0.329_161) <= 0.000_000_5)
                #expect(statistics.peak == 2)
            } else {
                #expect(statistics.union == 0)
                #expect(statistics.peak == 1)
            }
        }
    }
}

private final class DemoBundlePathSwap: @unchecked Sendable {
    private let lock = NSLock()
    private let resourceID: String
    private let relativePath: String
    private let componentIndex: Int
    private let sourceURL: URL
    private let destinationURL: URL
    private let moveSourceToDestination: Bool
    private var swapped = false

    init(
        resourceID: String,
        relativePath: String,
        componentIndex: Int,
        sourceURL: URL,
        destinationURL: URL,
        moveSourceToDestination: Bool = false
    ) {
        self.resourceID = resourceID
        self.relativePath = relativePath
        self.componentIndex = componentIndex
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
        self.moveSourceToDestination = moveSourceToDestination
    }

    var didSwap: Bool { lock.withLock { swapped } }

    func call(_ checkpoint: DemoResourceBundleCheckpoint) throws {
        guard checkpoint == .afterComponentMetadata(
            resourceID: resourceID,
            relativePath: relativePath,
            componentIndex: componentIndex
        ) else { return }
        let shouldSwap = lock.withLock { () -> Bool in
            guard !swapped else { return false }
            swapped = true
            return true
        }
        guard shouldSwap else { return }
        if moveSourceToDestination {
            try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
        } else {
            try FileManager.default.removeItem(at: sourceURL)
        }
        try FileManager.default.createSymbolicLink(
            at: sourceURL,
            withDestinationURL: destinationURL
        )
    }
}
