import Darwin
@preconcurrency import AVFAudio
import Foundation
import Testing
import StenoDomain
@testable import StenoLibrary

@Suite("Library CRUD")
struct LibraryCRUDTests {
    @Test("rename preserves folder and the pinned transcription plan")
    func renamePreservesClassificationAndPlan() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root.appendingPathComponent("Library"))
            let plan = TranscriptionPlan(
                liveProviderID: .apple,
                finalProviderID: .parakeetTDTv3
            )
            let created = try await library.createMeeting(
                title: "Vorher",
                status: .draft,
                transcriptionPlan: plan
            )
            let folderID = FolderID()
            _ = try await library.setMeetingFolder(created.id, folderID: folderID)

            let renamed = try await library.renameMeeting(created.id, to: "Nachher")
            let reloaded = try await library.loadMeeting(created.id)

            #expect(renamed.folderID == folderID)
            #expect(renamed.transcriptionPlan == plan)
            #expect(reloaded.folderID == folderID)
            #expect(reloaded.transcriptionPlan == plan)
        }
    }

    @Test("the pinned transcription plan can be assigned atomically after draft creation")
    func setTranscriptionPlan() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root.appendingPathComponent("Library"))
            let meeting = try await library.createMeeting(title: "Draft", status: .draft)
            let plan = TranscriptionPlan(
                liveProviderID: .apple,
                finalProviderID: .apple
            )

            let updated = try await library.setTranscriptionPlan(plan, for: meeting.id)

            #expect(updated.transcriptionPlan == plan)
            #expect(try await library.loadMeeting(meeting.id).transcriptionPlan == plan)
        }
    }

    @Test("rename preserves every field except the title")
    func renamePreservesEveryFieldExceptTitle() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root.appendingPathComponent("Library"))
            let sourceLocale = try MeetingSourceLocale(
                localeIdentifier: "de-DE",
                origin: .explicit
            )
            let plan = TranscriptionPlan(
                liveProviderID: .parakeetTDTv3,
                finalProviderID: .apple
            )
            let receipt = MeetingTransferReceipt(
                sourceMeetingID: MeetingID(),
                sourceRevisionID: RevisionID(),
                sourcePackageContentDigest: "digest",
                importedAt: Date(timeIntervalSince1970: 1_700_000_000),
                sourceAppVersion: "1.2.3",
                includedCapabilities: [.transcript],
                sourceLocaleIdentifier: "de-DE",
                sourceLocaleOrigin: .explicit,
                importGenerationID: MeetingTransferGenerationID()
            )
            let metadata = MeetingMetadata(
                legacyProvenanceKey: "legacy-key",
                legacyFolders: ["Alt", "Ordner"],
                transferReceipt: receipt
            )
            let created = try await library.createMeeting(
                title: "Vorher",
                status: .ready,
                metadata: metadata,
                sourceLocale: sourceLocale,
                transcriptionPlan: plan
            )
            _ = try await library.setMeetingFolder(created.id, folderID: FolderID())
            _ = try await library.updateMeetingParticipants(
                created.id,
                participantIDs: [PersonID()]
            )
            _ = try await library.updateAdditionalMeetingParticipants(
                created.id,
                participantIDs: [PersonID()]
            )
            // Occupied on purpose, see the comment below: an empty field would
            // compare equal to an empty field and prove nothing.
            try await library.updateUnrecordedTracks(created.id, to: [.micTrack])
            let before = try await library.loadMeeting(created.id)

            let after = try await library.renameMeeting(created.id, to: "Nachher")

            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let beforeObject = try JSONSerialization.jsonObject(
                with: encoder.encode(before)
            ) as? [String: Any]
            let afterObject = try JSONSerialization.jsonObject(
                with: encoder.encode(after)
            ) as? [String: Any]
            let beforeKeys = try #require(beforeObject).keys
            let afterKeys = try #require(afterObject).keys

            // Der Vergleich taugt nur, solange oben wirklich jedes Feld besetzt
            // ist: ein nil-Feld fehlt in beiden Staenden und wuerde stillschweigend
            // durchgehen. Diese Zahl faellt, sobald ein neues Feld dazukommt, das
            // der Aufbau nicht setzt.
            #expect(Set(beforeKeys).count == 12)
            #expect(Set(beforeKeys) == Set(afterKeys))
            #expect(after.title == "Nachher")
            for key in beforeKeys where key != "title" {
                let beforeValue = try #require(beforeObject)[key]
                let afterValue = try #require(afterObject)[key]
                let beforeData = try JSONSerialization.data(
                    withJSONObject: [beforeValue],
                    options: [.sortedKeys]
                )
                let afterData = try JSONSerialization.data(
                    withJSONObject: [afterValue],
                    options: [.sortedKeys]
                )
                #expect(
                    beforeData == afterData,
                    "Feld \(key) hat sich beim Umbenennen veraendert"
                )
            }
        }
    }

    @Test("every full meeting mutation reads after acquiring one transaction")
    func meetingMutationsReadInsideTransaction() async throws {
        try await withTemporaryDirectory { root in
            let base = try Library.open(at: root)
            let meetings = try await (0..<6).asyncMap { index in
                try await base.createMeeting(
                    title: "Meeting \(index)",
                    status: .ready
                )
            }
            let probe = MeetingMutationTransactionProbe(library: base)
            let library = try Library.open(
                at: root,
                mutationAction: probe.run
            )

            probe.target = meetings[0].id
            let renamed = try await library.renameMeeting(
                meetings[0].id,
                to: "Renamed"
            )
            #expect(renamed.status == .processing)

            probe.target = meetings[1].id
            let updatedParticipants = try await library.updateMeetingParticipants(
                meetings[1].id,
                participantIDs: [PersonID()]
            )
            #expect(updatedParticipants.status == .processing)

            probe.target = meetings[2].id
            let updatedAdditional = try await library.updateAdditionalMeetingParticipants(
                meetings[2].id,
                participantIDs: [PersonID()]
            )
            #expect(updatedAdditional.status == .processing)

            probe.target = meetings[3].id
            let setParticipants = try await library.setMeetingParticipants(
                meetings[3].id,
                participantIDs: [PersonID(), PersonID()]
            )
            #expect(setParticipants.status == .processing)

            probe.target = meetings[4].id
            let moved = try await library.setMeetingFolders(
                Set([meetings[4].id, meetings[5].id]),
                folderID: FolderID()
            )
            #expect(moved.first { $0.id == meetings[4].id }?.status == .processing)
            #expect(probe.checkpointCount == 5)
        }
    }

    @Test("meeting status changes are emitted after persistence")
    func emitsMeetingStatusChanges() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let meeting = try await library.createMeeting(
                title: "Status",
                status: .processing
            )
            let changes = await library.meetingChanges()
            var iterator = changes.makeAsyncIterator()

            _ = try await library.updateMeetingStatus(meeting.id, to: .ready)

            let changedMeetingID = await iterator.next()
            #expect(changedMeetingID == meeting.id)
            #expect(try await library.loadMeeting(meeting.id).status == .ready)
        }
    }

    @Test("writing the same meeting status emits no duplicate event")
    func skipsDuplicateMeetingStatusChanges() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let meeting = try await library.createMeeting(
                title: "Status",
                status: .ready
            )
            let changes = await library.meetingChanges()
            let recorder = MeetingChangeRecorder()
            let consumer = Task {
                for await meetingID in changes {
                    await recorder.append(meetingID)
                }
            }

            _ = try await library.updateMeetingStatus(meeting.id, to: .ready)
            try await Task.sleep(for: .milliseconds(50))
            consumer.cancel()

            #expect(await recorder.values().isEmpty)
        }
    }

    @Test("open creates the versioned library and meeting documents")
    func createAndListMeetings() async throws {
        try await withTemporaryDirectory { directory in
            let root = directory.appendingPathComponent("Library", isDirectory: true)
            let library = try Library.open(at: root)
            let first = try await library.createMeeting(
                title: "Früh",
                status: .ready,
                createdAt: Date(timeIntervalSince1970: 100)
            )
            let second = try await library.createMeeting(
                title: "Spät",
                status: .recording,
                createdAt: Date(timeIntervalSince1970: 200)
            )

            let metadata = try JSONDecoder().decode(
                LibraryMetadata.self,
                from: Data(contentsOf: root.appendingPathComponent("library.json"))
            )
            let meetings = try await library.listMeetings()

            #expect(metadata.schemaVersion == 1)
            #expect(try await library.loadMeeting(first.id) == first)
            #expect(meetings.map(\.id) == [second.id, first.id])
        }
    }

    @Test("meeting creation persists an explicit source locale")
    func createMeetingPersistsSourceLocale() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let sourceLocale = try MeetingSourceLocale(
                localeIdentifier: "de-DE",
                origin: .explicit
            )

            let meeting = try await library.createMeeting(
                title: "iPad-Aufnahme",
                status: .recording,
                sourceLocale: sourceLocale
            )

            #expect(try await library.loadMeeting(meeting.id).sourceLocale == sourceLocale)
        }
    }

    @Test("open clearly rejects an unknown library schema version")
    func rejectUnknownSchema() throws {
        try withTemporaryDirectory { root in
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
            try Data(
                """
                {"schemaVersion":99,"futureFormat":{"isNotDecodableAsVersionOne":true}}
                """.utf8
            ).write(to: root.appendingPathComponent("library.json"))

            do {
                _ = try Library.open(at: root)
                Issue.record("Expected unsupportedSchemaVersion")
            } catch let error as LibraryError {
                guard case .unsupportedSchemaVersion(let document, let found, let supported) = error else {
                    Issue.record("Unexpected error: \(error)")
                    return
                }
                #expect(document.lastPathComponent == "library.json")
                #expect(found == 99)
                #expect(supported == 1)
            }
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("library.json").path))
        }
    }

    @Test("import copies bytes and rejects matching SHA-256 provenance globally")
    func importAndRejectDuplicate() async throws {
        try await withTemporaryDirectory { root in
            let source = root.appendingPathComponent("source.m4a")
            let audio = Data("same audio bytes".utf8)
            try audio.write(to: source)
            let library = try Library.open(at: root.appendingPathComponent("Library"))
            let firstMeeting = try await library.createMeeting(title: "First", status: .ready)
            let secondMeeting = try await library.createMeeting(title: "Second", status: .ready)

            let asset = try await library.registerMediaAsset(
                for: firstMeeting.id,
                sourceURL: source,
                kind: .imported,
                sampleRate: 44_100,
                duration: 3.5
            )
            let copiedURL = library.layout.mediaFile(
                firstMeeting.id,
                fileName: asset.fileName
            )

            #expect(FileManager.default.fileExists(atPath: source.path))
            #expect(try Data(contentsOf: copiedURL) == audio)
            // gitleaks:allow - deterministic digest of a synthetic fixture
            #expect(asset.provenanceKey == "aafe9f6cb200b33109672a43c8ea1e40835484abeb0520632cdc9362ce1f58a1")
            #expect(try await library.loadMediaAsset(asset.id, meetingID: firstMeeting.id) == asset)

            do {
                _ = try await library.registerMediaAsset(
                    for: secondMeeting.id,
                    sourceURL: source,
                    kind: .imported,
                    sampleRate: 44_100,
                    duration: 3.5
                )
                Issue.record("Expected duplicateProvenance")
            } catch let error as LibraryError {
                guard case .duplicateProvenance(_, let existingMeetingID) = error else {
                    Issue.record("Unexpected error: \(error)")
                    return
                }
                #expect(existingMeetingID == firstMeeting.id)
            }
        }
    }

    @Test("recording tracks use meeting and track kind as provenance")
    func recordingProvenance() async throws {
        try await withTemporaryDirectory { root in
            let source = root.appendingPathComponent("track.caf")
            try Data("caf bytes".utf8).write(to: source)
            let library = try Library.open(at: root.appendingPathComponent("Library"))
            let meeting = try await library.createMeeting(title: "Recording", status: .recording)

            let asset = try await library.registerMediaAsset(
                for: meeting.id,
                sourceURL: source,
                kind: .micTrack,
                sampleRate: 48_000,
                duration: 10
            )

            #expect(asset.provenanceKey == "\(meeting.id)/micTrack")
            #expect(asset.fileName.hasSuffix(".caf"))
        }
    }

    @Test("reopening registers a recording CAF stranded before its metadata commit")
    func reopeningRegistersOrphanedRecordingCAF() async throws {
        try await withTemporaryDirectory { root in
            let libraryRoot = root.appendingPathComponent("Library")
            let library = try Library.open(at: libraryRoot)
            let meeting = try await library.createMeeting(
                title: "Interrupted registration",
                status: .recording
            )
            let assetID = MediaAssetID()
            let orphan = library.layout.mediaFile(
                meeting.id,
                fileName: "\(assetID)-micTrack.caf"
            )
            try writeSilentCAF(to: orphan, sampleRate: 16_000, seconds: 0.25)

            let reopened = try Library.open(at: libraryRoot)
            let assets = try await reopened.listMediaAssets(meetingID: meeting.id)
            let asset = try #require(assets.first)

            #expect(assets.count == 1)
            #expect(asset.id == assetID)
            #expect(asset.meetingID == meeting.id)
            #expect(asset.kind == .micTrack)
            #expect(asset.sampleRate == 16_000)
            #expect(abs(asset.duration - 0.25) < 0.001)
            #expect(asset.provenanceKey == "\(meeting.id)/micTrack")
            #expect(asset.fileName == orphan.lastPathComponent)
            #expect(FileManager.default.fileExists(atPath: orphan.path))
        }
    }

    @Test("reopening preserves orphan bytes while recovering the remaining track")
    func reopeningPreservesOrphanedSystemTrack() async throws {
        try await withTemporaryDirectory { root in
            let libraryRoot = root.appendingPathComponent("Library")
            let library = try Library.open(at: libraryRoot)
            let meeting = try await library.createMeeting(
                title: "Interrupted system registration",
                status: .recording
            )
            let microphoneSource = root.appendingPathComponent("microphone.caf")
            try writeSilentCAF(
                to: microphoneSource,
                sampleRate: 16_000,
                seconds: 0.125
            )
            _ = try await library.registerMediaAsset(
                for: meeting.id,
                sourceURL: microphoneSource,
                kind: .micTrack,
                sampleRate: 16_000,
                duration: 0.125
            )
            let orphanID = MediaAssetID()
            let orphan = library.layout.mediaFile(
                meeting.id,
                fileName: "\(orphanID).caf"
            )
            try writeSilentCAF(to: orphan, sampleRate: 24_000, seconds: 0.5)
            let originalBytes = try Data(contentsOf: orphan)

            let reopened = try Library.open(at: libraryRoot)
            let assets = try await reopened.listMediaAssets(meetingID: meeting.id)
            let recovered = try #require(assets.first { $0.id == orphanID })

            #expect(assets.count == 2)
            #expect(recovered.kind == .systemTrack)
            #expect(recovered.provenanceKey == "\(meeting.id)/systemTrack")
            #expect(try Data(contentsOf: orphan) == originalBytes)
            #expect(FileManager.default.fileExists(atPath: orphan.path))
        }
    }

    @Test("legacy recovery also reconstructs microphone after a system track")
    func reopeningPreservesOrphanedMicrophoneTrack() async throws {
        try await withTemporaryDirectory { root in
            let libraryRoot = root.appendingPathComponent("Library")
            let library = try Library.open(at: libraryRoot)
            let meeting = try await library.createMeeting(
                title: "Interrupted microphone registration",
                status: .recording
            )
            let systemSource = root.appendingPathComponent("system.caf")
            try writeSilentCAF(
                to: systemSource,
                sampleRate: 16_000,
                seconds: 0.125
            )
            _ = try await library.registerMediaAsset(
                for: meeting.id,
                sourceURL: systemSource,
                kind: .systemTrack,
                sampleRate: 16_000,
                duration: 0.125
            )
            let orphanID = MediaAssetID()
            let orphan = library.layout.mediaFile(
                meeting.id,
                fileName: "\(orphanID).caf"
            )
            try writeSilentCAF(to: orphan, sampleRate: 24_000, seconds: 0.5)
            let originalBytes = try Data(contentsOf: orphan)

            let reopened = try Library.open(at: libraryRoot)
            let assets = try await reopened.listMediaAssets(meetingID: meeting.id)
            let recovered = try #require(assets.first { $0.id == orphanID })

            #expect(assets.count == 2)
            #expect(recovered.kind == .micTrack)
            #expect(recovered.provenanceKey == "\(meeting.id)/micTrack")
            #expect(try Data(contentsOf: orphan) == originalBytes)
            #expect(FileManager.default.fileExists(atPath: orphan.path))
        }
    }

    @Test("recovery never replaces metadata when an orphan reuses its asset ID")
    func reopeningReportsCollidingAssetIDWithoutReplacingMetadata() async throws {
        try await withTemporaryDirectory { root in
            let libraryRoot = root.appendingPathComponent("Library")
            let library = try Library.open(at: libraryRoot)
            let meeting = try await library.createMeeting(
                title: "Colliding orphan",
                status: .recording
            )
            let microphoneSource = root.appendingPathComponent("microphone.caf")
            try writeSilentCAF(
                to: microphoneSource,
                sampleRate: 16_000,
                seconds: 0.125
            )
            let microphone = try await library.registerMediaAsset(
                for: meeting.id,
                sourceURL: microphoneSource,
                kind: .micTrack,
                sampleRate: 16_000,
                duration: 0.125
            )
            let metadataURL = library.layout.mediaMetadata(
                meeting.id,
                assetID: microphone.id
            )
            let metadataBytes = try Data(contentsOf: metadataURL)
            let orphan = library.layout.mediaFile(
                meeting.id,
                fileName: "\(microphone.id)-systemTrack.caf"
            )
            try writeSilentCAF(to: orphan, sampleRate: 24_000, seconds: 0.5)
            let orphanBytes = try Data(contentsOf: orphan)

            let reopened = try Library.open(at: libraryRoot)

            #expect(reopened.openingMediaRecoveryReport.issues == [
                MediaAssetRecoveryIssue(
                    meetingID: meeting.id,
                    fileName: orphan.lastPathComponent,
                    reason: .notReconstructable
                ),
            ])
            #expect(try await reopened.loadMediaAsset(
                microphone.id,
                meetingID: meeting.id
            ) == microphone)
            #expect(try Data(contentsOf: metadataURL) == metadataBytes)
            #expect(try Data(contentsOf: orphan) == orphanBytes)
        }
    }

    @Test("legacy inference stops when an existing track has no backing file")
    func reopeningDoesNotMisclassifyRenamedMicrophoneAsSystemTrack() async throws {
        try await withTemporaryDirectory { root in
            let libraryRoot = root.appendingPathComponent("Library")
            let library = try Library.open(at: libraryRoot)
            let meeting = try await library.createMeeting(
                title: "Stale microphone metadata",
                status: .recording
            )
            let microphoneSource = root.appendingPathComponent("microphone.caf")
            try writeSilentCAF(
                to: microphoneSource,
                sampleRate: 16_000,
                seconds: 0.25
            )
            let microphone = try await library.registerMediaAsset(
                for: meeting.id,
                sourceURL: microphoneSource,
                kind: .micTrack,
                sampleRate: 16_000,
                duration: 0.25
            )
            let registeredFile = library.layout.mediaFile(
                meeting.id,
                fileName: microphone.fileName
            )
            let renamedID = MediaAssetID()
            let renamedFile = library.layout.mediaFile(
                meeting.id,
                fileName: "\(renamedID).caf"
            )
            try FileManager.default.moveItem(at: registeredFile, to: renamedFile)
            let renamedBytes = try Data(contentsOf: renamedFile)

            let reopened = try Library.open(at: libraryRoot)

            #expect(reopened.openingMediaRecoveryReport.issues == [
                MediaAssetRecoveryIssue(
                    meetingID: meeting.id,
                    fileName: renamedFile.lastPathComponent,
                    reason: .notReconstructable
                ),
            ])
            #expect(try await reopened.listMediaAssets(meetingID: meeting.id) == [
                microphone,
            ])
            #expect(try Data(contentsOf: renamedFile) == renamedBytes)
            #expect(!FileManager.default.fileExists(atPath: library.layout
                .mediaMetadata(meeting.id, assetID: renamedID).path))
        }
    }

    @Test("a bad sidecar does not report healthy registered media as orphaned")
    func reopeningIsolatesMalformedSidecarFromHealthyMedia() async throws {
        try await withTemporaryDirectory { root in
            let libraryRoot = root.appendingPathComponent("Library")
            let library = try Library.open(at: libraryRoot)
            let meeting = try await library.createMeeting(
                title: "Damaged sidecar",
                status: .recording
            )
            let microphoneSource = root.appendingPathComponent("microphone.caf")
            try writeSilentCAF(
                to: microphoneSource,
                sampleRate: 16_000,
                seconds: 0.125
            )
            let microphone = try await library.registerMediaAsset(
                for: meeting.id,
                sourceURL: microphoneSource,
                kind: .micTrack,
                sampleRate: 16_000,
                duration: 0.125
            )
            let damagedID = MediaAssetID()
            try Data("not json".utf8).write(
                to: library.layout.mediaMetadata(meeting.id, assetID: damagedID)
            )
            let orphanID = MediaAssetID()
            let orphan = library.layout.mediaFile(
                meeting.id,
                fileName: "\(orphanID)-systemTrack.caf"
            )
            try writeSilentCAF(to: orphan, sampleRate: 24_000, seconds: 0.5)

            let reopened = try Library.open(at: libraryRoot)

            #expect(reopened.openingMediaRecoveryReport.issues == [
                MediaAssetRecoveryIssue(
                    meetingID: meeting.id,
                    fileName: orphan.lastPathComponent,
                    reason: .notReconstructable
                ),
            ])
            #expect(try await reopened.listMediaAssets(meetingID: meeting.id) == [
                microphone,
            ])
            #expect(FileManager.default.fileExists(atPath: orphan.path))
        }
    }

    @Test("reopening reports an orphan whose track kind cannot be reconstructed")
    func reopeningReportsAmbiguousOrphanWithoutChangingIt() async throws {
        try await withTemporaryDirectory { root in
            let libraryRoot = root.appendingPathComponent("Library")
            let library = try Library.open(at: libraryRoot)
            let meeting = try await library.createMeeting(
                title: "Ambiguous orphan",
                status: .interrupted
            )
            let orphanID = MediaAssetID()
            let orphan = library.layout.mediaFile(
                meeting.id,
                fileName: "\(orphanID).caf"
            )
            try writeSilentCAF(to: orphan, sampleRate: 16_000, seconds: 0.25)
            let originalBytes = try Data(contentsOf: orphan)

            let reopened = try Library.open(at: libraryRoot)

            #expect(reopened.openingMediaRecoveryReport.issues == [
                MediaAssetRecoveryIssue(
                    meetingID: meeting.id,
                    fileName: orphan.lastPathComponent,
                    reason: .notReconstructable
                ),
            ])
            #expect(try await reopened.listMediaAssets(meetingID: meeting.id).isEmpty)
            #expect(try Data(contentsOf: orphan) == originalBytes)
            #expect(FileManager.default.fileExists(atPath: orphan.path))
        }
    }

    @Test("reopening does not mistake quarantined metadata for media")
    func reopeningIgnoresQuarantinedMediaMetadata() async throws {
        try await withTemporaryDirectory { root in
            let libraryRoot = root.appendingPathComponent("Library")
            let library = try Library.open(at: libraryRoot)
            let meeting = try await library.createMeeting(
                title: "Quarantined metadata",
                status: .interrupted
            )
            let quarantine = library.layout.mediaDirectory(meeting.id)
                .appendingPathComponent("\(MediaAssetID()).json.corrupt-123")
            let bytes = Data("damaged metadata".utf8)
            try bytes.write(to: quarantine)

            let reopened = try Library.open(at: libraryRoot)

            #expect(reopened.openingMediaRecoveryReport.issues.isEmpty)
            #expect(try Data(contentsOf: quarantine) == bytes)
        }
    }

    @Test("cross-volume capture fallback syncs the copy before removing its source")
    func capturedMediaEXDEVFallbackIsDurableBeforeRemoval() async throws {
        try await withTemporaryDirectory { root in
            let source = root.appendingPathComponent("capture.caf")
            let bytes = Data("durable capture bytes".utf8)
            try bytes.write(to: source)
            let library = try Library.open(at: root.appendingPathComponent("Library"))
            let meeting = try await library.createMeeting(
                title: "Cross-volume",
                status: .recording
            )
            let operations = FileOperationLog()

            let asset = try await library.registerCapturedMediaAsset(
                for: meeting.id,
                sourceURL: source,
                kind: .micTrack,
                sampleRate: 48_000,
                duration: 10,
                fileOperations: MediaAssetFileOperations(
                    rename: { _, _ in
                        operations.append("rename")
                        throw POSIXFailure(operation: "rename", code: EXDEV)
                    },
                    copy: { source, destination in
                        operations.append("copy")
                        try FileManager.default.copyItem(
                            at: source,
                            to: destination
                        )
                    },
                    synchronizeFile: { _ in
                        operations.append("fsync-file")
                    },
                    synchronizeDirectory: { directory in
                        operations.append(
                            "fsync-directory:\(directory.lastPathComponent)"
                        )
                    },
                    remove: { url in
                        operations.append("remove:\(url.lastPathComponent)")
                        try FileManager.default.removeItem(at: url)
                    }
                )
            )

            let destination = library.layout.mediaFile(
                meeting.id,
                fileName: asset.fileName
            )
            #expect(try Data(contentsOf: destination) == bytes)
            #expect(!FileManager.default.fileExists(atPath: source.path))
            #expect(asset.fileName == "\(asset.id)-micTrack.caf")
            #expect(operations.values == [
                "rename",
                "copy",
                "fsync-file",
                "fsync-directory:media",
                "remove:capture.caf",
                "fsync-directory:\(root.lastPathComponent)",
            ])
        }
    }

    @Test("a failed post-rename rollback reports the orphaned destination")
    func failedRenameRollbackReportsOrphan() async throws {
        try await withTemporaryDirectory { root in
            let source = root.appendingPathComponent("capture.caf")
            try Data("recording".utf8).write(to: source)
            let library = try Library.open(at: root.appendingPathComponent("Library"))
            let meeting = try await library.createMeeting(
                title: "Failed rollback",
                status: .recording
            )
            let renames = FailingRollbackRename()
            let caught: any Error

            do {
                _ = try await library.registerCapturedMediaAsset(
                    for: meeting.id,
                    sourceURL: source,
                    kind: .micTrack,
                    sampleRate: 48_000,
                    duration: 1,
                    fileOperations: MediaAssetFileOperations(
                        rename: renames.call,
                        copy: { _, _ in Issue.record("copy must not run") },
                        synchronizeFile: { _ in },
                        synchronizeDirectory: { _ in
                            throw POSIXFailure(operation: "injected fsync", code: EIO)
                        },
                        remove: { _ in Issue.record("remove must not run") }
                    )
                )
                Issue.record("Expected registration to fail")
                return
            } catch {
                caught = error
            }

            let mediaFiles = try FileManager.default.contentsOfDirectory(
                at: library.layout.mediaDirectory(meeting.id),
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension != "json" }
            let orphan = try #require(mediaFiles.first)
            let rollbackError = try #require(
                caught as? MediaAssetTransferRollbackError
            )
            #expect(mediaFiles.count == 1)
            #expect(!FileManager.default.fileExists(atPath: source.path))
            #expect(
                rollbackError.orphanedDestination.resolvingSymlinksInPath()
                    == orphan.resolvingSymlinksInPath()
            )
            #expect(caught.localizedDescription.contains(
                rollbackError.orphanedDestination.path
            ))
        }
    }

    @Test("a successful post-fsync rollback synchronizes both directories")
    func successfulRenameRollbackIsDurable() async throws {
        try await withTemporaryDirectory { root in
            let source = root.appendingPathComponent("capture.caf")
            try Data("recording".utf8).write(to: source)
            let library = try Library.open(at: root.appendingPathComponent("Library"))
            let meeting = try await library.createMeeting(
                title: "Durable rollback",
                status: .recording
            )
            let operations = SuccessfulRollbackOperations()

            do {
                _ = try await library.registerCapturedMediaAsset(
                    for: meeting.id,
                    sourceURL: source,
                    kind: .micTrack,
                    sampleRate: 48_000,
                    duration: 1,
                    fileOperations: MediaAssetFileOperations(
                        rename: operations.rename,
                        copy: { _, _ in Issue.record("copy must not run") },
                        synchronizeFile: { _ in },
                        synchronizeDirectory: operations.synchronizeDirectory,
                        remove: { _ in Issue.record("remove must not run") }
                    )
                )
                Issue.record("Expected registration to fail")
            } catch let error as POSIXFailure {
                #expect(error.operation == "injected destination fsync")
            }

            #expect(FileManager.default.fileExists(atPath: source.path))
            #expect(operations.values == [
                "rename-1",
                "fsync:media",
                "rename-2",
                "fsync:\(root.lastPathComponent)",
                "fsync:media",
            ])
        }
    }
}

private final class MeetingMutationTransactionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let library: Library
    private var storedTarget: MeetingID?
    private var storedCheckpointCount = 0

    init(library: Library) {
        self.library = library
    }

    var target: MeetingID? {
        get { lock.withLock { storedTarget } }
        set { lock.withLock { storedTarget = newValue } }
    }

    var checkpointCount: Int {
        lock.withLock { storedCheckpointCount }
    }

    func run(
        _ checkpoint: LibraryMeetingMutationCheckpoint,
        _ transaction: LibraryMutationTransaction
    ) throws {
        guard checkpoint == .afterExclusiveTransactionBeforeRead else { return }
        let target = lock.withLock { () -> MeetingID? in
            storedCheckpointCount += 1
            return storedTarget
        }
        guard let target else { return }
        _ = try library.updateMeetingStatus(
            target,
            to: .processing,
            transaction: transaction
        )
    }
}

private extension Range where Element == Int {
    func asyncMap<Result>(
        _ transform: (Int) async throws -> Result
    ) async rethrows -> [Result] {
        var results: [Result] = []
        for value in self {
            results.append(try await transform(value))
        }
        return results
    }
}

private actor MeetingChangeRecorder {
    private var meetingIDs: [MeetingID] = []

    func append(_ meetingID: MeetingID) {
        meetingIDs.append(meetingID)
    }

    func values() -> [MeetingID] {
        meetingIDs
    }
}

private final class FileOperationLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [String] = []

    var values: [String] {
        lock.withLock { storedValues }
    }

    func append(_ value: String) {
        lock.withLock { storedValues.append(value) }
    }
}

private final class FailingRollbackRename: @unchecked Sendable {
    private let lock = NSLock()
    private var invocation = 0

    func call(_ source: URL, _ destination: URL) throws {
        let current = lock.withLock { () -> Int in
            invocation += 1
            return invocation
        }
        if current == 1 {
            try FileManager.default.moveItem(at: source, to: destination)
        } else {
            throw POSIXFailure(operation: "injected rollback rename", code: EIO)
        }
    }
}

private final class SuccessfulRollbackOperations: @unchecked Sendable {
    private let lock = NSLock()
    private var renameCount = 0
    private var synchronizedDirectoryCount = 0
    private var storedValues: [String] = []

    var values: [String] {
        lock.withLock { storedValues }
    }

    func rename(_ source: URL, _ destination: URL) throws {
        lock.withLock {
            renameCount += 1
            storedValues.append("rename-\(renameCount)")
        }
        try FileManager.default.moveItem(at: source, to: destination)
    }

    func synchronizeDirectory(_ directory: URL) throws {
        let shouldFail = lock.withLock { () -> Bool in
            synchronizedDirectoryCount += 1
            storedValues.append("fsync:\(directory.lastPathComponent)")
            return synchronizedDirectoryCount == 1
        }
        if shouldFail {
            throw POSIXFailure(
                operation: "injected destination fsync",
                code: EIO
            )
        }
    }
}

private func writeSilentCAF(
    to url: URL,
    sampleRate: Double,
    seconds: Double
) throws {
    let format = try #require(AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: false
    ))
    let file = try AVAudioFile(
        forWriting: url,
        settings: format.settings,
        commonFormat: .pcmFormatFloat32,
        interleaved: false
    )
    let frameCount = AVAudioFrameCount(sampleRate * seconds)
    let buffer = try #require(AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: frameCount
    ))
    buffer.frameLength = frameCount
    try file.write(from: buffer)
}
