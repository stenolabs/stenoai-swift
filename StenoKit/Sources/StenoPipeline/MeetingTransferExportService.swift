import CryptoKit
import Foundation
import StenoDomain
import StenoExchange
import StenoLibrary

public enum MeetingTransferExportError: Error, Equatable, Sendable {
    case audioNotEligible
    case emptyPayload
    case invalidSourceLocale
    case sourceChangedDuringNativeSnapshot
}

enum MeetingTransferExportCheckpoint: Equatable, Sendable {
    case afterAudioPreparation
}

typealias MeetingTransferExportAction = @Sendable (
    MeetingTransferExportCheckpoint
) throws -> Void

public struct MeetingTransferExportPreview: Sendable {
    public let meetingID: MeetingID
    public let title: String
    public let createdAt: Date
    public let includesNotes: Bool
    public let includesTranscript: Bool
    public let visibleSpeakerLabels: [String]
    public let audioTracks: [AudioTrack]
    public let textOnlyIsValid: Bool

    public struct AudioTrack: Sendable {
        public let assetID: MediaAssetID
        public let label: String
        public let byteCount: Int64

        public init(assetID: MediaAssetID, label: String, byteCount: Int64) {
            self.assetID = assetID
            self.label = label
            self.byteCount = byteCount
        }
    }

    public init(
        meetingID: MeetingID,
        title: String,
        createdAt: Date,
        includesNotes: Bool,
        includesTranscript: Bool,
        visibleSpeakerLabels: [String],
        audioTracks: [AudioTrack],
        textOnlyIsValid: Bool
    ) {
        self.meetingID = meetingID
        self.title = title
        self.createdAt = createdAt
        self.includesNotes = includesNotes
        self.includesTranscript = includesTranscript
        self.visibleSpeakerLabels = visibleSpeakerLabels
        self.audioTracks = audioTracks
        self.textOnlyIsValid = textOnlyIsValid
    }
}

public struct MeetingTransferExportResult: Sendable {
    public let packageURL: URL
    public let cleanupRoot: URL
    public let contentDigest: String
    public let capabilities: Set<MeetingTransferCapability>
    public let totalByteCount: Int64

    public init(
        packageURL: URL,
        cleanupRoot: URL,
        contentDigest: String,
        capabilities: Set<MeetingTransferCapability>,
        totalByteCount: Int64
    ) {
        self.packageURL = packageURL
        self.cleanupRoot = cleanupRoot
        self.contentDigest = contentDigest
        self.capabilities = capabilities
        self.totalByteCount = totalByteCount
    }
}

public struct MeetingTransferExportService: Sendable {
    private let library: Library
    private let notesStore: MeetingNotesStore
    private let writer: MeetingTransferArchiveWriter
    private let exportAction: MeetingTransferExportAction

    public init(
        library: Library,
        writer: MeetingTransferArchiveWriter = MeetingTransferArchiveWriter()
    ) {
        self.library = library
        notesStore = MeetingNotesStore(layout: library.layout)
        self.writer = writer
        exportAction = { _ in }
    }

    init(
        library: Library,
        writer: MeetingTransferArchiveWriter = MeetingTransferArchiveWriter(),
        exportCheckpoint: @escaping MeetingTransferExportAction
    ) {
        self.library = library
        notesStore = MeetingNotesStore(layout: library.layout)
        self.writer = writer
        exportAction = exportCheckpoint
    }

    public func preview(meetingID: MeetingID) async throws -> MeetingTransferExportPreview {
        let snapshot = try await loadSnapshot(
            meetingID: meetingID,
            selectedAudioAssetIDsForExport: nil
        )
        return MeetingTransferExportPreview(
            meetingID: snapshot.meeting.id,
            title: snapshot.meeting.title,
            createdAt: snapshot.meeting.createdAt,
            includesNotes: snapshot.notes != nil,
            includesTranscript: snapshot.transcript != nil,
            visibleSpeakerLabels: snapshot.transcript?.speakers.map(\.label) ?? [],
            audioTracks: snapshot.audio.map(\.preview),
            textOnlyIsValid: snapshot.notes != nil || snapshot.transcript != nil
        )
    }

    public func export(
        meetingID: MeetingID,
        selectedAudioAssetIDs: Set<MediaAssetID>,
        temporaryRoot: URL,
        sourceAppVersion: String?,
        progress: @escaping @Sendable (MeetingTransferProgress) -> Void = { _ in }
    ) async throws -> MeetingTransferExportResult {
        try Task.checkCancellation()
        let snapshot = try await loadSnapshot(
            meetingID: meetingID,
            selectedAudioAssetIDsForExport: selectedAudioAssetIDs
        )
        let eligibleIDs = Set(snapshot.audio.map(\.asset.id))
        guard selectedAudioAssetIDs.isSubset(of: eligibleIDs) else {
            throw MeetingTransferExportError.audioNotEligible
        }
        guard selectedAudioAssetIDs.isEmpty
                || Self.hasCleanlyEndedRecording(snapshot.meeting.status)
        else {
            throw MeetingTransferExportError.audioNotEligible
        }

        let selected = snapshot.audio.filter {
            selectedAudioAssetIDs.contains($0.asset.id)
        }
        guard snapshot.notes != nil || snapshot.transcript != nil || !selected.isEmpty else {
            throw MeetingTransferExportError.emptyPayload
        }
        if !selected.isEmpty {
            try exportAction(.afterAudioPreparation)
        }

        let audioExport = selected.isEmpty ? nil : try MeetingTransferAudioExport(root: temporaryRoot)
        defer { try? audioExport?.cleanup() }
        var audioDocuments: [MeetingTransferAudioDocument] = []
        var audioBindings: [MeetingTransferAudioSourceBinding] = []
        for (offset, source) in selected.enumerated() {
            try Task.checkCancellation()
            let logicalTrackID = "track-\(offset + 1)"
            guard let originalSource = source.preparedSource else {
                throw MeetingTransferExportError.audioNotEligible
            }
            let output = try audioExport!.prepare(sourceURL: source.sourceURL, expected: originalSource)
            let preparedSource = output.source
            audioDocuments.append(try MeetingTransferAudioDocument(
                logicalTrackID: logicalTrackID,
                kind: source.asset.kind,
                byteCount: preparedSource.byteCount,
                sha256: preparedSource.byteSHA256,
                sampleRate: preparedSource.sampleRate,
                channelCount: preparedSource.channelCount,
                duration: preparedSource.duration
            ))
            audioBindings.append(MeetingTransferAudioSourceBinding(
                logicalTrackID: logicalTrackID,
                sourceURL: output.url,
                preparedSource: preparedSource
            ))
        }

        let meetingDocument = try MeetingTransferMeetingDocument(
            sourceMeetingID: snapshot.meeting.id,
            title: snapshot.meeting.title,
            createdAt: snapshot.meeting.createdAt,
            sourceStatus: Self.transferSourceStatus(
                localStatus: snapshot.meeting.status,
                includesAudio: !selected.isEmpty
            )
        )
        let content = try MeetingTransferPackageContent(
            meeting: meetingDocument,
            notes: snapshot.notes,
            transcript: snapshot.transcript,
            audio: audioDocuments,
            sourceLocale: snapshot.sourceLocale
        )
        let contentDigest = try Self.contentDigest(
            content: content,
            audioDocuments: audioDocuments
        )
        let packageURL = try await writer.write(
            content,
            audioSources: audioBindings,
            sourceRevisionID: snapshot.transcript == nil ? nil : snapshot.revision?.id,
            sourceAppVersion: sourceAppVersion,
            to: temporaryRoot,
            progress: progress
        )
        try audioExport?.cleanup()
        let values = try packageURL.resourceValues(forKeys: [.fileSizeKey])
        guard let fileSize = values.fileSize else {
            throw MeetingTransferArchiveWriterError.writeFailed
        }
        return MeetingTransferExportResult(
            packageURL: packageURL,
            cleanupRoot: temporaryRoot,
            contentDigest: contentDigest,
            capabilities: content.capabilities,
            totalByteCount: Int64(fileSize)
        )
    }

    func nativeMeetingTransferMatch(
        for package: ValidatedMeetingTransferPackage
    ) async throws -> NativeMeetingTransferMatch {
        let meetingID = package.manifest.sourceMeetingID
        for _ in 0..<2 {
            let before = try await library.nativeMeetingTransferSnapshotToken(
                for: meetingID
            )
            let allAssetIDs = Set(
                try await library.listMediaAssets(meetingID: meetingID).map(\.id)
            )
            let snapshot = try await loadSnapshot(
                meetingID: meetingID,
                selectedAudioAssetIDsForExport: allAssetIDs
            )
            guard let audioDocuments = try Self.matchingAudioDocuments(
                package: package,
                eligible: snapshot.audio
            ) else {
                let after = try await library.nativeMeetingTransferSnapshotToken(
                    for: meetingID
                )
                if before == after {
                    return NativeMeetingTransferMatch(
                        meetingID: meetingID,
                        contentDigest: "",
                        snapshotToken: after
                    )
                }
                continue
            }
            let content = try MeetingTransferPackageContent(
                meeting: try MeetingTransferMeetingDocument(
                    sourceMeetingID: snapshot.meeting.id,
                    title: snapshot.meeting.title,
                    createdAt: snapshot.meeting.createdAt,
                    sourceStatus: Self.transferSourceStatus(
                        localStatus: snapshot.meeting.status,
                        includesAudio: !package.audio.isEmpty
                    )
                ),
                notes: snapshot.notes,
                transcript: snapshot.transcript,
                audio: audioDocuments,
                sourceLocale: snapshot.sourceLocale
            )
            let digest = try Self.contentDigest(
                content: content,
                audioDocuments: audioDocuments
            )
            let after = try await library.nativeMeetingTransferSnapshotToken(
                for: meetingID
            )
            guard before == after else { continue }
            return NativeMeetingTransferMatch(
                meetingID: meetingID,
                contentDigest: digest,
                snapshotToken: after
            )
        }
        throw MeetingTransferExportError.sourceChangedDuringNativeSnapshot
    }

    private static func matchingAudioDocuments(
        package: ValidatedMeetingTransferPackage,
        eligible: [EligibleAudio]
    ) throws -> [MeetingTransferAudioDocument]? {
        guard !package.audio.isEmpty else { return [] }
        var result: [MeetingTransferAudioDocument] = []
        var searchStart = eligible.startIndex
        for (offset, incoming) in package.audio.enumerated() {
            let path = "audio/track-\(offset + 1).caf"
            guard let manifestEntry = package.manifest.entries.first(where: {
                $0.path == path
            }) else {
                return nil
            }
            var matchIndex: Int?
            var index = searchStart
            while index < eligible.endIndex {
                let candidate = eligible[index]
                if let prepared = candidate.preparedSource,
                   candidate.asset.kind == incoming.kind,
                   candidate.byteCount == manifestEntry.byteCount,
                   prepared.byteSHA256 == incoming.byteSHA256,
                   candidate.sampleRate == incoming.sampleRate,
                   candidate.channelCount == incoming.channelCount,
                   candidate.duration == incoming.duration {
                    matchIndex = index
                    break
                }
                index = eligible.index(after: index)
            }
            guard let matchIndex else { return nil }
            let candidate = eligible[matchIndex]
            let prepared = candidate.preparedSource!
            result.append(try MeetingTransferAudioDocument(
                logicalTrackID: "track-\(offset + 1)",
                kind: candidate.asset.kind,
                byteCount: candidate.byteCount,
                sha256: prepared.byteSHA256,
                sampleRate: candidate.sampleRate,
                channelCount: candidate.channelCount,
                duration: candidate.duration
            ))
            searchStart = eligible.index(after: matchIndex)
        }
        return result
    }

    private func loadSnapshot(
        meetingID: MeetingID,
        selectedAudioAssetIDsForExport: Set<MediaAssetID>?
    ) async throws -> ExportSnapshot {
        let meeting = try await library.loadMeeting(meetingID)
        let sourceLocale = try Self.sourceLocale(for: meeting)
        let notes = try await notesStore.notes(meetingID)
        let revision: TranscriptRevision?
        if FileManager.default.fileExists(atPath: library.layout.currentRevision(meetingID).path) {
            revision = try await library.loadCurrentRevision(meetingID: meetingID)
        } else {
            revision = nil
        }
        let transcript: MeetingTransferTranscriptSnapshot?
        if let revision {
            let review = try await MeetingReviewAssembler.load(
                library: library,
                revision: revision
            )
            let persons = if let review {
                review.persons
            } else {
                try await IdentityStore(layout: library.layout).listPersons()
            }
            transcript = try Self.portableTranscript(
                revision,
                review: review,
                persons: persons,
                sourceLocale: sourceLocale
            )
        } else {
            transcript = nil
        }
        let audio = try await eligibleAudio(
            meeting: meeting,
            selectedAudioAssetIDsForExport: selectedAudioAssetIDsForExport
        )
        return ExportSnapshot(
            meeting: meeting,
            notes: notes,
            revision: revision,
            transcript: transcript,
            audio: audio,
            sourceLocale: sourceLocale
        )
    }

    private static func sourceLocale(for meeting: Meeting) throws -> MeetingSourceLocale? {
        guard let receipt = meeting.metadata?.transferReceipt else {
            return meeting.sourceLocale
        }

        let receiptLocale: MeetingSourceLocale?
        switch (receipt.sourceLocaleIdentifier, receipt.sourceLocaleOrigin) {
        case (nil, .absent):
            receiptLocale = nil
        case (.some(let identifier), .explicit), (.some(let identifier), .estimated):
            do {
                receiptLocale = try MeetingSourceLocale(
                    localeIdentifier: identifier,
                    origin: receipt.sourceLocaleOrigin
                )
            } catch {
                throw MeetingTransferExportError.invalidSourceLocale
            }
        default:
            throw MeetingTransferExportError.invalidSourceLocale
        }

        if let persisted = meeting.sourceLocale,
           persisted != receiptLocale {
            throw MeetingTransferExportError.invalidSourceLocale
        }
        return meeting.sourceLocale ?? receiptLocale
    }

    private func eligibleAudio(
        meeting: Meeting,
        selectedAudioAssetIDsForExport: Set<MediaAssetID>?
    ) async throws -> [EligibleAudio] {
        guard Self.hasCleanlyEndedRecording(meeting.status) else {
            return []
        }
        let mediaDirectory = library.layout.mediaDirectory(meeting.id).standardizedFileURL
        let assets = try await library.listMediaAssets(meetingID: meeting.id)
        var result: [EligibleAudio] = []
        for asset in assets {
            if let selection = selectedAudioAssetIDsForExport,
               !selection.contains(asset.id) {
                continue
            }
            guard asset.meetingID == meeting.id,
                  !asset.fileName.isEmpty,
                  asset.fileName != ".",
                  asset.fileName != "..",
                  URL(fileURLWithPath: asset.fileName).lastPathComponent == asset.fileName
            else { continue }
            let sourceURL = library.layout.mediaFile(
                meeting.id,
                fileName: asset.fileName
            ).standardizedFileURL
            guard sourceURL.deletingLastPathComponent() == mediaDirectory else { continue }
            do {
                if selectedAudioAssetIDsForExport != nil {
                    let prepared = try MeetingTransferAudioInspector().prepareCAFSource(
                        at: sourceURL
                    )
                    result.append(EligibleAudio(
                        asset: asset,
                        sourceURL: sourceURL,
                        byteCount: prepared.byteCount,
                        sampleRate: prepared.sampleRate,
                        channelCount: prepared.channelCount,
                        duration: prepared.duration,
                        preparedSource: prepared
                    ))
                } else {
                    let inspection = try MeetingTransferAudioInspector().inspectCAFSource(
                        at: sourceURL
                    )
                    guard inspection.byteCount > 0,
                          inspection.byteCount <= MeetingTransferLimits.maximumAudioBytes
                    else { continue }
                    result.append(EligibleAudio(
                        asset: asset,
                        sourceURL: sourceURL,
                        byteCount: inspection.byteCount,
                        sampleRate: inspection.sampleRate,
                        channelCount: inspection.channelCount,
                        duration: inspection.duration,
                        preparedSource: nil
                    ))
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }
        return result
    }

    private static func hasCleanlyEndedRecording(_ status: Meeting.Status) -> Bool {
        status == .processing || status == .ready
    }

    private static func transferSourceStatus(
        localStatus: Meeting.Status,
        includesAudio: Bool
    ) -> Meeting.Status {
        includesAudio ? .ready : localStatus
    }

    private static func portableTranscript(
        _ revision: TranscriptRevision,
        review: MeetingReviewData?,
        persons: [Person],
        sourceLocale: MeetingSourceLocale?
    ) throws -> MeetingTransferTranscriptSnapshot {
        var speakerIDs: [SpeakerReference: String] = [:]
        var speakers: [MeetingTransferTranscriptSnapshot.Speaker] = []
        var turns: [MeetingTransferTranscriptSnapshot.Turn] = []

        for turn in revision.turns {
            let speakerID: String?
            if let reference = turn.speaker {
                if let existing = speakerIDs[reference] {
                    speakerID = existing
                } else {
                    let id = "speaker-\(speakers.count + 1)"
                    let descriptor = speakerDescriptor(
                        reference,
                        ordinal: speakers.count + 1,
                        review: review,
                        persons: persons
                    )
                    speakers.append(try .init(
                        id: id,
                        label: descriptor.label,
                        kind: descriptor.kind
                    ))
                    speakerIDs[reference] = id
                    speakerID = id
                }
            } else {
                speakerID = nil
            }
            turns.append(.init(
                speakerID: speakerID,
                start: turn.start,
                end: turn.end,
                segments: turn.segments.map { segment in
                    .init(
                        text: segment.text,
                        start: segment.start,
                        end: segment.end,
                        words: segment.words.map {
                            .init(text: $0.text, start: $0.start, end: $0.end)
                        }
                    )
                }
            ))
        }
        return try MeetingTransferTranscriptSnapshot(
            localeIdentifier: sourceLocale?.localeIdentifier,
            localeOrigin: sourceLocale?.origin ?? .absent,
            speakers: speakers,
            turns: turns
        )
    }

    private static func speakerDescriptor(
        _ reference: SpeakerReference,
        ordinal: Int,
        review: MeetingReviewData?,
        persons: [Person]
    ) -> SpeakerDescriptor {
        let confirmedName: String?
        switch reference {
        case .person(let personID):
            confirmedName = persons.first { $0.id == personID }?.displayName
        case .cluster:
            confirmedName = review?.confirmedName(for: reference)
        case .importedTextLabel(let imported):
            confirmedName = imported.wasConfirmedAtSource ? imported.text : nil
        case .channel:
            confirmedName = nil
        }
        let trimmed = confirmedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            return SpeakerDescriptor(label: trimmed, kind: .confirmedDisplayName)
        }
        if case .channel(let raw) = reference {
            let label = ChannelLabel.speakerLabel(raw)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !label.isEmpty {
                return SpeakerDescriptor(label: label, kind: .generic)
            }
        }
        return SpeakerDescriptor(label: "Speaker \(ordinal)", kind: .generic)
    }

    private static func contentDigest(
        content: MeetingTransferPackageContent,
        audioDocuments: [MeetingTransferAudioDocument]
    ) throws -> String {
        var entries: [MeetingTransferManifest.Entry] = []
        func append(path: String, mediaType: String, data: Data) {
            entries.append(.init(
                path: path,
                byteCount: Int64(data.count),
                mediaType: mediaType,
                sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            ))
        }
        append(
            path: "meeting.json",
            mediaType: "application/json",
            data: try content.meeting.encodedData()
        )
        if let notes = content.notes {
            append(path: "notes.md", mediaType: "text/markdown", data: Data(notes.utf8))
        }
        if let transcript = content.transcript {
            append(
                path: "transcript.json",
                mediaType: "application/json",
                data: try transcript.encodedData()
            )
        }
        for (offset, document) in audioDocuments.enumerated() {
            let number = offset + 1
            entries.append(.init(
                path: "audio/track-\(number).caf",
                byteCount: document.byteCount,
                mediaType: "audio/x-caf",
                sha256: document.sha256
            ))
            append(
                path: "audio/track-\(number).json",
                mediaType: "application/json",
                data: try document.encodedData()
            )
        }
        return try MeetingTransferDigest.contentDigest(for: entries)
    }
}

private struct ExportSnapshot: Sendable {
    let meeting: Meeting
    let notes: String?
    let revision: TranscriptRevision?
    let transcript: MeetingTransferTranscriptSnapshot?
    let audio: [EligibleAudio]
    let sourceLocale: MeetingSourceLocale?
}

private struct EligibleAudio: Sendable {
    let asset: MediaAsset
    let sourceURL: URL
    let byteCount: Int64
    let sampleRate: Double
    let channelCount: Int
    let duration: TimeInterval
    let preparedSource: MeetingTransferPreparedCAFSource?

    var preview: MeetingTransferExportPreview.AudioTrack {
        .init(
            assetID: asset.id,
            label: ChannelLabel.trackName(asset.kind.rawValue),
            byteCount: byteCount
        )
    }
}

private struct SpeakerDescriptor: Sendable {
    let label: String
    let kind: MeetingTransferTranscriptSnapshot.Speaker.Kind
}
