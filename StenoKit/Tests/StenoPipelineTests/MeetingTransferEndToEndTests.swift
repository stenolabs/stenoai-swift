@preconcurrency import AVFAudio
import Foundation
import StenoDomain
import StenoExchange
import StenoLibrary
@testable import StenoPipeline
import Testing

@Suite("MeetingTransferEndToEndTests")
struct MeetingTransferEndToEndTests {
    @Test("compressed multitrack export imports with hashes and immutable originals")
    func compressedMultitrackRoundTrip() async throws {
        try await withTemporaryDirectory { root in
            let source = try await makeTransferSource(at: root, title: "Synthetic AAC transfer",
                includesText: true, includesAudio: false, installsPrivacySentinels: false)
            var ids: Set<MediaAssetID> = []
            var originals: [(URL, Data)] = []
            for channels in [1, 2] {
                let url = root.appending(path: "tone-\(channels).caf")
                let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: UInt32(channels)))
                do {
                    let file = try AVAudioFile(forWriting: url, settings: [
                        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
                        AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 16,
                        AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
                    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480_013))
                    buffer.frameLength = 480_013
                    for channel in 0..<channels {
                        for frame in 0..<480_013 {
                            buffer.floatChannelData![channel][frame] = Float(sin(Double(frame) * 2 * .pi * Double(440 + 220 * channel) / 48_000)) * 0.2
                        }
                    }
                    try file.write(from: buffer)
                }
                let asset = try await source.library.registerMediaAsset(for: source.meeting.id,
                    sourceURL: url, kind: channels == 1 ? .micTrack : .systemTrack,
                    sampleRate: 48_000, duration: 480_013.0 / 48_000)
                ids.insert(asset.id)
                let originalURL = source.library.layout.mediaFile(source.meeting.id, fileName: asset.fileName)
                originals.append((originalURL, try Data(contentsOf: originalURL)))
            }
            let exported = try await MeetingTransferExportService(library: source.library).export(
                meetingID: source.meeting.id, selectedAudioAssetIDs: ids,
                temporaryRoot: root.appending(path: "AACExport"), sourceAppVersion: "synthetic-aac-fixture-v1")
            for (url, bytes) in originals { #expect(try Data(contentsOf: url) == bytes) }
            #expect(exported.totalByteCount < originals.reduce(0) { $0 + $1.1.count } / 4)
            let target = try makeTransferTarget(at: root)
            let service = MeetingTransferImportService(library: target.library, jobStore: target.jobStore)
            let prepared = try await service.prepareImport(at: exported.packageURL)
            #expect(try await service.importPrepared(sessionID: prepared.sessionID, choice: .importOnly) == .imported(source.meeting.id))
            let imported = try await target.library.listMediaAssets(meetingID: source.meeting.id)
            #expect(imported.count == 2)
            #expect(Set(imported.map(\.kind)) == [.micTrack, .systemTrack])
            for asset in imported {
                let file = try AVAudioFile(forReading: target.library.layout.mediaFile(source.meeting.id, fileName: asset.fileName))
                #expect(file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC)
                #expect(file.length == 480_013)
                #expect(file.processingFormat.channelCount == (asset.kind == .micTrack ? 1 : 2))
            }
            let second = try await service.prepareImport(at: exported.packageURL)
            #expect(second.preview.disposition == .alreadyPresent(source.meeting.id))
            try await service.discardPrepared(sessionID: second.sessionID)
            // Lossy derivatives cannot establish byte identity with native originals.
            let originService = MeetingTransferImportService(library: source.library, jobStore: try JobStore(layout: source.library.layout))
            let origin = try await originService.prepareImport(at: exported.packageURL)
            #expect(origin.preview.disposition == .conflict(source.meeting.id))
            try await originService.discardPrepared(sessionID: origin.sessionID)
            if let path = ProcessInfo.processInfo.environment["STENO_AAC_FIXTURE_DIR"] {
                let directory = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let destination = directory.appending(path: "synthetic-aac.stenomeeting")
                try FileManager.default.copyItem(at: exported.packageURL, to: destination)
            }
        }
    }

    @Test("text-only meetings round trip in both device directions without private library data")
    func textOnlyRoundTripsInBothDirections() async throws {
        try await withTemporaryDirectory { root in
            for direction in ["iPad-to-Mac", "Mac-to-iPad"] {
                let directionRoot = root.appending(path: direction)
                let source = try await makeTransferSource(
                    at: directionRoot,
                    title: direction,
                    includesText: true,
                    includesAudio: false,
                    installsPrivacySentinels: true
                )
                let exported = try await exportSource(
                    source,
                    to: directionRoot.appending(path: "Export")
                )
                try assertPrivacySentinelsAreAbsent(
                    from: exported.packageURL,
                    source: source
                )

                let target = try makeTransferTarget(at: directionRoot)
                let service = MeetingTransferImportService(
                    library: target.library,
                    jobStore: target.jobStore
                )
                let prepared = try await service.prepareImport(at: exported.packageURL)
                #expect(prepared.preview.visibleSpeakerLabels == [
                    "Ada Bestätigt", "Bela Sichtbar", "Sprecher Generisch",
                ])
                #expect(try await service.importPrepared(
                    sessionID: prepared.sessionID,
                    choice: .importOnly
                ) == .imported(source.meeting.id))

                try await assertImportedText(
                    in: target.library,
                    meetingID: source.meeting.id,
                    expectedSourceRevisionID: source.revisionID
                )
                let imported = try await target.library.loadMeeting(source.meeting.id)
                #expect(imported.participantIDs.isEmpty)
                #expect(imported.additionalParticipantIDs.isEmpty)
                #expect(imported.folderID == nil)
                #expect(try await target.jobStore.list().isEmpty)
            }
        }
    }

    @Test("combined meeting round trip preserves text and selected original audio")
    func combinedRoundTripPreservesTextAndAudio() async throws {
        try await withTemporaryDirectory { root in
            let source = try await makeTransferSource(
                at: root,
                title: "Kombi",
                includesText: true,
                includesAudio: true,
                installsPrivacySentinels: true
            )
            let exported = try await exportSource(
                source,
                to: root.appending(path: "CombinedExport")
            )
            #expect(exported.capabilities == [.notes, .transcript, .audio])
            try assertPrivacySentinelsAreAbsent(
                from: exported.packageURL,
                source: source
            )

            let target = try makeTransferTarget(at: root)
            let service = MeetingTransferImportService(
                library: target.library,
                jobStore: target.jobStore
            )
            let prepared = try await service.prepareImport(at: exported.packageURL)
            #expect(try await service.importPrepared(
                sessionID: prepared.sessionID,
                choice: .importOnly
            ) == .imported(source.meeting.id))

            try await assertImportedText(
                in: target.library,
                meetingID: source.meeting.id,
                expectedSourceRevisionID: source.revisionID
            )
            let importedAsset = try #require(
                try await target.library.listMediaAssets(meetingID: source.meeting.id).first
            )
            #expect(importedAsset.kind == .micTrack)
            #expect(try Data(contentsOf: target.library.layout.mediaFile(
                source.meeting.id,
                fileName: importedAsset.fileName
            )) == source.audioBytes)
            #expect(try await target.jobStore.list().isEmpty)
        }
    }

    @Test("iPad-style audio package becomes exactly one pinned Mac processing job")
    func audioPackageToMacProcessing() async throws {
        try await withTemporaryDirectory { root in
            let source = try await makeTransferSource(
                at: root,
                title: "iPad-Aufnahme",
                includesText: false,
                includesAudio: true,
                installsPrivacySentinels: true,
                sourceLocale: try MeetingSourceLocale(
                    localeIdentifier: "de-DE",
                    origin: .explicit
                )
            )
            let exported = try await exportSource(
                source,
                to: root.appending(path: "AudioExport")
            )
            try assertPrivacySentinelsAreAbsent(
                from: exported.packageURL,
                source: source
            )
            let values = try exported.packageURL.resourceValues(forKeys: [.isRegularFileKey])
            #expect(values.isRegularFile == true)

            let target = try makeTransferTarget(at: root)
            let service = MeetingTransferImportService(
                library: target.library,
                jobStore: target.jobStore
            )
            let prepared = try await service.prepareImport(at: exported.packageURL)
            #expect(prepared.preview.localeIdentifier == "de-DE")
            #expect(prepared.preview.localeOrigin == .explicit)
            #expect(try await service.importPrepared(
                sessionID: prepared.sessionID,
                choice: .process(
                    localeIdentifier: "de-DE",
                    languageConfirmed: true,
                    modelsReady: true
                )
            ) == .imported(source.meeting.id))

            let stateStore = MeetingTransferStateStore(layout: target.library.layout)
            let reconciler = ImportedMeetingProcessingReconciler(
                library: target.library,
                stateStore: stateStore,
                jobStore: target.jobStore
            )
            try await reconciler.reconcileAll()
            try await reconciler.reconcileAll()
            let jobs = try await target.jobStore.list()
            #expect(jobs.count == 1)
            #expect(jobs[0].localeIdentifier == "de-DE")
            #expect(jobs[0].kind == .finalASR)
            let receipt = try #require(
                try await target.library.loadMeeting(source.meeting.id)
                    .metadata?.transferReceipt
            )
            #expect(receipt.sourceLocaleIdentifier == "de-DE")
            #expect(receipt.sourceLocaleOrigin == .explicit)
            #expect(try await target.library.loadMeeting(source.meeting.id).sourceLocale
                == MeetingSourceLocale(localeIdentifier: "de-DE", origin: .explicit))
            #expect(jobs[0].importGenerationID == receipt.importGenerationID)
            #expect(!FileManager.default.fileExists(
                atPath: target.library.layout.currentRevision(source.meeting.id).path
            ))

            let reexported = try await MeetingTransferExportService(
                library: target.library
            ).export(
                meetingID: source.meeting.id,
                selectedAudioAssetIDs: Set(
                    try await target.library.listMediaAssets(meetingID: source.meeting.id)
                        .map(\.id)
                ),
                temporaryRoot: root.appending(path: "Reexport"),
                sourceAppVersion: "Steno/Reexport"
            )
            let reread = try await MeetingTransferArchiveReader().validate(
                at: reexported.packageURL,
                validationRoot: root.appending(path: "ReexportValidation")
            )
            defer { try? reread.close() }
            #expect(reread.manifest.localeIdentifier == "de-DE")
            #expect(reread.manifest.localeOrigin == .explicit)
        }
    }

    @Test("re-export never upgrades estimated or absent source locale")
    func reexportPreservesNonExplicitLocaleOrigins() async throws {
        try await withTemporaryDirectory { root in
            for (name, sourceLocale, expectedIdentifier, expectedOrigin) in [
                (
                    "Estimated",
                    try MeetingSourceLocale(localeIdentifier: "de-DE", origin: .estimated),
                    Optional("de-DE"),
                    MeetingTransferLocaleOrigin.estimated
                ),
                ("Absent", nil, nil, MeetingTransferLocaleOrigin.absent),
            ] {
                let caseRoot = root.appending(path: name)
                let source = try await makeTransferSource(
                    at: caseRoot,
                    title: name,
                    includesText: false,
                    includesAudio: true,
                    installsPrivacySentinels: false,
                    sourceLocale: sourceLocale
                )
                let exported = try await exportSource(
                    source,
                    to: caseRoot.appending(path: "Export")
                )
                let target = try makeTransferTarget(at: caseRoot)
                let service = MeetingTransferImportService(
                    library: target.library,
                    jobStore: target.jobStore
                )
                let prepared = try await service.prepareImport(at: exported.packageURL)
                #expect(prepared.preview.localeIdentifier == expectedIdentifier)
                #expect(prepared.preview.localeOrigin == expectedOrigin)
                #expect(try await service.importPrepared(
                    sessionID: prepared.sessionID,
                    choice: .importOnly
                ) == .imported(source.meeting.id))

                let selectedAudio = Set(
                    try await target.library.listMediaAssets(meetingID: source.meeting.id)
                        .map(\.id)
                )
                let reexported = try await MeetingTransferExportService(
                    library: target.library
                ).export(
                    meetingID: source.meeting.id,
                    selectedAudioAssetIDs: selectedAudio,
                    temporaryRoot: caseRoot.appending(path: "Reexport"),
                    sourceAppVersion: "Steno/Reexport"
                )
                let reread = try await MeetingTransferArchiveReader().validate(
                    at: reexported.packageURL,
                    validationRoot: caseRoot.appending(path: "Validation")
                )
                #expect(reread.manifest.localeIdentifier == expectedIdentifier)
                #expect(reread.manifest.localeOrigin == expectedOrigin)
                try reread.close()
            }
        }
    }

    @Test("identical reimport is a no-op after local note edits and changed source conflicts")
    func reimportAndConflictRespectOriginalDigest() async throws {
        try await withTemporaryDirectory { root in
            let source = try await makeTransferSource(
                at: root,
                title: "Deduplizierung",
                includesText: true,
                includesAudio: false,
                installsPrivacySentinels: false
            )
            let original = try await exportSource(
                source,
                to: root.appending(path: "OriginalExport")
            )
            let target = try makeTransferTarget(at: root)
            let service = MeetingTransferImportService(
                library: target.library,
                jobStore: target.jobStore
            )
            let first = try await service.prepareImport(at: original.packageURL)
            #expect(try await service.importPrepared(
                sessionID: first.sessionID,
                choice: .importOnly
            ) == .imported(source.meeting.id))

            try await MeetingNotesStore(layout: target.library.layout).setNotes(
                source.meeting.id,
                to: "lokal bearbeitet"
            )
            let duplicate = try await service.prepareImport(at: original.packageURL)
            #expect(duplicate.preview.disposition == .alreadyPresent(source.meeting.id))
            #expect(try await service.importPrepared(
                sessionID: duplicate.sessionID,
                choice: .importOnly
            ) == .alreadyPresent(source.meeting.id))
            #expect(try await MeetingNotesStore(layout: target.library.layout)
                .notes(source.meeting.id) == "lokal bearbeitet")

            try await MeetingNotesStore(layout: source.library.layout).setNotes(
                source.meeting.id,
                to: "abweichende Quelle"
            )
            let changed = try await exportSource(
                source,
                to: root.appending(path: "ChangedExport")
            )
            let conflict = try await service.prepareImport(at: changed.packageURL)
            #expect(conflict.preview.disposition == .conflict(source.meeting.id))
            await #expect(throws: MeetingTransferImportError.conflict(source.meeting.id)) {
                try await service.importPrepared(
                    sessionID: conflict.sessionID,
                    choice: .importOnly
                )
            }
            #expect(try await target.library.listMeetings().count == 1)
            #expect(try await MeetingNotesStore(layout: target.library.layout)
                .notes(source.meeting.id) == "lokal bearbeitet")
        }
    }

    @Test("prepared snapshot ignores external replacement and rejects private mutation")
    func snapshotBoundaryIsStableAndTamperEvident() async throws {
        try await withTemporaryDirectory { root in
            let originalSource = try await makeTransferSource(
                at: root.appending(path: "Original"),
                title: "Original",
                includesText: true,
                includesAudio: false,
                installsPrivacySentinels: false
            )
            let replacementSource = try await makeTransferSource(
                at: root.appending(path: "Replacement"),
                title: "Ersatz",
                includesText: true,
                includesAudio: false,
                installsPrivacySentinels: false
            )
            let original = try await exportSource(
                originalSource,
                to: root.appending(path: "OriginalExport")
            )
            let replacement = try await exportSource(
                replacementSource,
                to: root.appending(path: "ReplacementExport")
            )
            let stableTarget = try makeTransferTarget(at: root.appending(path: "Stable"))
            let stableService = MeetingTransferImportService(
                library: stableTarget.library,
                jobStore: stableTarget.jobStore
            )
            let stablePrepared = try await stableService.prepareImport(at: original.packageURL)
            try FileManager.default.removeItem(at: original.packageURL)
            try FileManager.default.copyItem(at: replacement.packageURL, to: original.packageURL)
            #expect(try await stableService.importPrepared(
                sessionID: stablePrepared.sessionID,
                choice: .importOnly
            ) == .imported(originalSource.meeting.id))
            #expect(try await stableTarget.library.loadMeeting(
                originalSource.meeting.id
            ).title == "Original")
            #expect(try await MeetingNotesStore(layout: stableTarget.library.layout)
                .notes(originalSource.meeting.id) == "Plan\n[00:12:34] Beschluss")

            let tamperedSource = try await makeTransferSource(
                at: root.appending(path: "Tampered"),
                title: "Manipulation",
                includesText: true,
                includesAudio: false,
                installsPrivacySentinels: false
            )
            let tamperedExport = try await exportSource(
                tamperedSource,
                to: root.appending(path: "TamperedExport")
            )
            let tamperedTarget = try makeTransferTarget(at: root.appending(path: "TamperedTarget"))
            let tamperedService = MeetingTransferImportService(
                library: tamperedTarget.library,
                jobStore: tamperedTarget.jobStore,
                importCheckpoint: { checkpoint in
                    guard case .beforeSecondValidation(let snapshotURL) = checkpoint else {
                        return
                    }
                    let handle = try FileHandle(forWritingTo: snapshotURL)
                    defer { try? handle.close() }
                    try handle.seek(toOffset: 0)
                    try handle.write(contentsOf: Data("manipuliert".utf8))
                }
            )
            let tamperedPrepared = try await tamperedService.prepareImport(
                at: tamperedExport.packageURL
            )
            await #expect(throws: MeetingTransferValidationError.self) {
                try await tamperedService.importPrepared(
                    sessionID: tamperedPrepared.sessionID,
                    choice: .importOnly
                )
            }
            #expect(try await tamperedTarget.library.listMeetings().isEmpty)
        }
    }

    @Test("missing model keeps audio and a later manual retry creates one pinned job")
    func missingModelAllowsManualRetry() async throws {
        try await withTemporaryDirectory { root in
            let source = try await makeTransferSource(
                at: root,
                title: "Modell fehlt",
                includesText: false,
                includesAudio: true,
                installsPrivacySentinels: false
            )
            let exported = try await exportSource(
                source,
                to: root.appending(path: "MissingModelExport")
            )
            let target = try makeTransferTarget(at: root)
            let service = MeetingTransferImportService(
                library: target.library,
                jobStore: target.jobStore
            )
            let prepared = try await service.prepareImport(at: exported.packageURL)
            #expect(try await service.importPrepared(
                sessionID: prepared.sessionID,
                choice: .process(
                    localeIdentifier: "de-DE",
                    languageConfirmed: true,
                    modelsReady: false
                )
            ) == .imported(source.meeting.id))

            let stateStore = MeetingTransferStateStore(layout: target.library.layout)
            #expect(try await stateStore.load(source.meeting.id)
                == .awaitingModel(localeIdentifier: "de-DE"))
            #expect(try await target.jobStore.list().isEmpty)
            #expect(try await target.library.listMediaAssets(
                meetingID: source.meeting.id
            ).count == 1)
            let receipt = try #require(
                try await target.library.loadMeeting(source.meeting.id)
                    .metadata?.transferReceipt
            )
            let generationID = try #require(receipt.importGenerationID)
            let reconciler = ImportedMeetingProcessingReconciler(
                library: target.library,
                stateStore: stateStore,
                jobStore: target.jobStore
            )
            _ = try await reconciler.requestManualRetry(
                meetingID: source.meeting.id,
                expectedImportGenerationID: generationID,
                localeIdentifier: "de-DE",
                modelsReady: true
            )
            try await reconciler.reconcileAll()

            let jobs = try await target.jobStore.list()
            #expect(jobs.count == 1)
            #expect(jobs[0].localeIdentifier == "de-DE")
            #expect(jobs[0].importGenerationID == generationID)
        }
    }
}

private struct TransferSource {
    let library: Library
    let meeting: Meeting
    let selectedAudioAssetIDs: Set<MediaAssetID>
    let audioBytes: Data?
    let revisionID: RevisionID?
    let forbiddenTokens: [String]
}

private struct TransferTarget {
    let library: Library
    let jobStore: JobStore
}

private func makeTransferTarget(at root: URL) throws -> TransferTarget {
    let library = try Library.open(at: root.appending(path: "TargetLibrary"))
    return TransferTarget(
        library: library,
        jobStore: try JobStore(layout: library.layout)
    )
}

private func makeTransferSource(
    at root: URL,
    title: String,
    includesText: Bool,
    includesAudio: Bool,
    installsPrivacySentinels: Bool,
    sourceLocale: MeetingSourceLocale? = nil
) async throws -> TransferSource {
    let library = try Library.open(at: root.appending(path: "SourceLibrary"))
    let meeting = try await library.createMeeting(
        title: title,
        status: .ready,
        createdAt: Date(timeIntervalSinceReferenceDate: 7_654),
        sourceLocale: sourceLocale
    )
    var forbiddenTokens: [String] = []
    var revisionID: RevisionID?

    if includesText {
        let runID = RunID()
        let ada = makeSentinelPerson(
            name: "Ada Bestätigt",
            token: "sentinel-ada-private",
            meetingID: meeting.id,
            runID: runID
        )
        let bela = makeSentinelPerson(
            name: "Bela Sichtbar",
            token: "sentinel-bela-private",
            meetingID: meeting.id,
            runID: runID
        )
        let participant = makeSentinelPerson(
            name: "sentinel-participant-name",
            token: "sentinel-participant-private",
            meetingID: meeting.id,
            runID: runID
        )
        try await replacePersonsForTest(
            [ada, bela, participant],
            layout: library.layout
        )
        let folder = try await FolderStore.open(layout: library.layout).createFolder(
            name: "sentinel-folder-name"
        )
        _ = try await library.setMeetingParticipants(
            meeting.id,
            participantIDs: [ada.id, participant.id]
        )
        _ = try await library.setMeetingFolder(meeting.id, folderID: folder.id)
        try await MeetingNotesStore(layout: library.layout).setNotes(
            meeting.id,
            to: "Plan\n[00:12:34] Beschluss"
        )
        let revision = TranscriptRevision(
            meetingID: meeting.id,
            createdAt: Date(timeIntervalSinceReferenceDate: 7_655),
            origin: .finalRun(runID),
            turns: [
                transferTurn(speaker: .person(ada.id), text: "Beschluss", offset: 12),
                transferTurn(speaker: .person(bela.id), text: "Folgepunkt", offset: 14),
                transferTurn(
                    speaker: .channel("Sprecher Generisch"),
                    text: "Offener Punkt",
                    offset: 16
                ),
            ]
        )
        _ = try await library.appendRevision(revision)
        revisionID = revision.id
        forbiddenTokens = [
            "sentinel-ada-private", "sentinel-bela-private",
            "sentinel-participant-private", "sentinel-participant-name",
            "sentinel-folder-name", ada.id.description, bela.id.description,
            participant.id.description, folder.id.description, runID.description,
        ]
        if installsPrivacySentinels {
            forbiddenTokens += try installPrivateArtifacts(
                layout: library.layout,
                meetingID: meeting.id,
                runID: runID
            )
        }
    }

    if installsPrivacySentinels {
        let additionalRunID = RunID()
        let additionalParticipant = makeSentinelPerson(
            name: "sentinel-additional-participant-name",
            token: "sentinel-additional-participant-private",
            meetingID: meeting.id,
            runID: additionalRunID
        )
        let identityStore = try IdentityStore(layout: library.layout)
        var persons = try await identityStore.listPersons()
        persons.append(additionalParticipant)
        try await replacePersonsForTest(persons, in: identityStore)
        _ = try await library.updateAdditionalMeetingParticipants(
            meeting.id,
            participantIDs: [additionalParticipant.id]
        )
        forbiddenTokens += [
            "sentinel-additional-participant-name",
            "sentinel-additional-participant-private",
            additionalParticipant.id.description,
            additionalRunID.description,
        ]
    }

    var selectedAudioAssetIDs: Set<MediaAssetID> = []
    var audioBytes: Data?
    if includesAudio {
        let sourceURL = root.appending(path: "source.caf")
        try FileManager.default.createDirectory(
            at: sourceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try makePipelineTestCAF(at: sourceURL)
        let asset = try await library.registerMediaAsset(
            for: meeting.id,
            sourceURL: sourceURL,
            kind: .micTrack,
            sampleRate: 8_000,
            duration: 0.01
        )
        selectedAudioAssetIDs = [asset.id]
        audioBytes = try Data(contentsOf: library.layout.mediaFile(
            meeting.id,
            fileName: asset.fileName
        ))
    }

    return TransferSource(
        library: library,
        meeting: meeting,
        selectedAudioAssetIDs: selectedAudioAssetIDs,
        audioBytes: audioBytes,
        revisionID: revisionID,
        forbiddenTokens: forbiddenTokens
    )
}

private func exportSource(
    _ source: TransferSource,
    to root: URL
) async throws -> MeetingTransferExportResult {
    try await MeetingTransferExportService(library: source.library).export(
        meetingID: source.meeting.id,
        selectedAudioAssetIDs: source.selectedAudioAssetIDs,
        temporaryRoot: root,
        sourceAppVersion: "Steno/RoundTrip"
    )
}

private func transferTurn(
    speaker: SpeakerReference,
    text: String,
    offset: TimeInterval
) -> TranscriptTurn {
    TranscriptTurn(
        speaker: speaker,
        start: offset,
        end: offset + 1,
        segments: [
            TranscriptSegment(
                text: text,
                start: offset,
                end: offset + 1,
                words: [
                    TranscriptWord(text: text, start: offset + 0.25, end: offset + 0.75),
                ]
            ),
        ]
    )
}

private func makeSentinelPerson(
    name: String,
    token: String,
    meetingID: MeetingID,
    runID: RunID
) -> Person {
    let id = PersonID()
    return Person(
        id: id,
        displayName: name,
        email: "\(token)@example.invalid",
        organization: "\(token)-company",
        prototypes: [
            SpeakerPrototype(
                personID: id,
                embedding: [0.125, 0.25],
                recordingType: .inPerson,
                channel: MediaAsset.Kind.micTrack.rawValue,
                meetingID: meetingID,
                runID: runID,
                clusterID: "\(token)-embedding",
                speechDurationSeconds: 1,
                segmentCount: 1,
                source: .userConfirmed
            ),
        ]
    )
}

private func installPrivateArtifacts(
    layout: LibraryLayout,
    meetingID: MeetingID,
    runID: RunID
) throws -> [String] {
    let artifacts: [(URL, String)] = [
        (
            layout.meetingDirectory(meetingID).appending(path: "review.json"),
            "sentinel-review-document"
        ),
        (layout.runMetadata(meetingID, runID: runID), "sentinel-processing-run"),
        (layout.runDiarization(meetingID, runID: runID), "sentinel-diarization-run"),
        (layout.report(meetingID, runID: runID), "sentinel-report"),
        (layout.jobsDirectory.appending(path: "sentinel-job.bin"), "sentinel-job"),
        (
            layout.captureDirectory(meetingID).appending(path: "sentinel-capture.bin"),
            "sentinel-capture"
        ),
        (layout.root.appending(path: "sentinel-model.bin"), "sentinel-model"),
    ]
    for (url, token) in artifacts {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(token.utf8).write(to: url)
    }
    return artifacts.map { $0.1 }
}

private func assertPrivacySentinelsAreAbsent(
    from packageURL: URL,
    source: TransferSource
) throws {
    let bytes = try Data(contentsOf: packageURL)
    for token in source.forbiddenTokens {
        #expect(bytes.range(of: Data(token.utf8)) == nil)
    }
    if source.revisionID != nil {
        #expect(bytes.range(of: Data("Ada Bestätigt".utf8)) != nil)
        #expect(bytes.range(of: Data("Bela Sichtbar".utf8)) != nil)
        #expect(bytes.range(of: Data("Sprecher Generisch".utf8)) != nil)
    }
}

private func assertImportedText(
    in library: Library,
    meetingID: MeetingID,
    expectedSourceRevisionID: RevisionID?
) async throws {
    #expect(try await MeetingNotesStore(layout: library.layout).notes(meetingID)
        == "Plan\n[00:12:34] Beschluss")
    let revision = try await library.loadCurrentRevision(meetingID: meetingID)
    #expect(revision.origin == .meetingTransfer(
        sourceMeetingID: meetingID,
        sourceRevisionID: expectedSourceRevisionID
    ))
    #expect(revision.turns[0].segments[0].words[0]
        == TranscriptWord(text: "Beschluss", start: 12.25, end: 12.75))
    #expect(revision.turns[1].segments[0].words[0]
        == TranscriptWord(text: "Folgepunkt", start: 14.25, end: 14.75))
    #expect(revision.turns[2].segments[0].words[0]
        == TranscriptWord(text: "Offener Punkt", start: 16.25, end: 16.75))
    let labels = try revision.turns.map { turn -> ImportedSpeakerTextLabel in
        guard case .importedTextLabel(let label) = turn.speaker else {
            throw MeetingTransferEndToEndTestError.expectedImportedSpeakerTextLabel
        }
        return label
    }
    #expect(labels.map { $0.text } == [
        "Ada Bestätigt", "Bela Sichtbar", "Sprecher Generisch",
    ])
    #expect(labels.map { $0.wasConfirmedAtSource } == [true, true, false])
}

private enum MeetingTransferEndToEndTestError: Error {
    case expectedImportedSpeakerTextLabel
}
