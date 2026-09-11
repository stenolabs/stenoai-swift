import Foundation
import StenoDomain
import StenoIdentity
import StenoLibrary
import Testing
@testable import StenoPipeline

@Suite("Meeting review controller")
struct MeetingReviewControllerTests {
    @Test("transfer preview preserves confirmed names from the corrected displayed run")
    func transferUsesDisplayedRun() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let fixture = try await makeReviewFixture(library: library, isDemo: false)
            let turn = TranscriptTurn(speaker: .cluster(runID: fixture.runID, clusterID: fixture.cluster.clusterID), start: 0, end: 1, segments: [TranscriptSegment(text: "Synthetic text", start: 0, end: 1, words: [])])
            let base = TranscriptRevision(meetingID: fixture.meeting.id, origin: .finalRun(fixture.runID), turns: [turn])
            _ = try await library.appendRevision(base)
            let corrected = TranscriptRevision(meetingID: fixture.meeting.id, origin: .userEdit(base.id), turns: [turn])
            _ = try await library.appendRevision(corrected)
            let newerRun = RunID()
            let newerCluster = reviewCluster(meetingID: fixture.meeting.id, runID: newerRun)
            try seedIdentitySuggestionRun(meetingID: fixture.meeting.id, runID: newerRun, cluster: newerCluster, library: library)
            try MeetingReviewStore(layout: library.layout).save(MeetingReviewDocument(runID: newerRun, clusters: [newerCluster]), meetingID: fixture.meeting.id)
            _ = try await library.appendRevision(TranscriptRevision(meetingID: fixture.meeting.id, origin: .finalRun(newerRun), turns: []))
            #expect(try await library.loadCurrentRevision(meetingID: fixture.meeting.id).id == corrected.id)
            let preview = try await MeetingTransferExportService(library: library).preview(meetingID: fixture.meeting.id)
            #expect(preview.visibleSpeakerLabels.contains("Ada"))
        }
    }

    @Test("returning to an archived run prefers its newly saved current review")
    func archiveRoundTrip() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let meeting = try await library.createMeeting(title: "Synthetic archive", status: .ready)
            let store = MeetingReviewStore(layout: library.layout)
            let a = RunID(), b = RunID()
            var cluster = reviewCluster(meetingID: meeting.id, runID: a)
            let original = MeetingReviewDocument(runID: a, clusters: [cluster])
            let other = MeetingReviewDocument(runID: b, clusters: [])
            try store.save(original, meetingID: meeting.id)
            try store.save(other, meetingID: meeting.id)
            cluster.reviewState = .generic
            let updated = MeetingReviewDocument(runID: a, clusters: [cluster])
            try store.save(updated, meetingID: meeting.id)
            #expect(try store.load(meetingID: meeting.id, runID: a) == updated)
            try store.save(other, meetingID: meeting.id)
            #expect(try store.load(meetingID: meeting.id, runID: a) == updated)
            #expect(try store.load(meetingID: meeting.id, runID: b) == other)
        }
    }

    @Test("a displayed corrected revision keeps its archived review after a newer run")
    func displayedRevisionRetainsReview() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let meeting = try await library.createMeeting(title: "Synthetic revision history", status: .ready)
            let first = RunID(), second = RunID()
            var firstCluster = reviewCluster(meetingID: meeting.id, runID: first)
            firstCluster.reviewState = .generic
            let secondCluster = reviewCluster(meetingID: meeting.id, runID: second)
            try seedIdentitySuggestionRun(meetingID: meeting.id, runID: first, cluster: firstCluster, library: library)
            try seedIdentitySuggestionRun(meetingID: meeting.id, runID: second, cluster: secondCluster, library: library)
            let store = MeetingReviewStore(layout: library.layout)
            try store.save(MeetingReviewDocument(runID: first, clusters: [firstCluster]), meetingID: meeting.id)
            try store.save(MeetingReviewDocument(runID: second, clusters: [secondCluster]), meetingID: meeting.id)
            let revision = TranscriptRevision(meetingID: meeting.id, origin: .userEdit(RevisionID()), turns: [TranscriptTurn(speaker: .cluster(runID: first, clusterID: firstCluster.clusterID), start: 0, end: 1, segments: [])])
            let review = try #require(try await MeetingReviewAssembler.load(library: library, revision: revision))
            #expect(review.runID == first)
            #expect(review.clusters.first?.reviewState == .generic)
            #expect(try store.load(meetingID: meeting.id)?.runID == second)
        }
    }

    @Test("demo meetings reject every voice-evidence action without store changes")
    func demoMeetingVoiceEvidenceActionsFailClosed() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let fixture = try await makeReviewFixture(library: library, isDemo: true)
            let controller = MeetingReviewController(library: library)
            let before = try await persistedSnapshot(
                library: library,
                fixture: fixture
            )
            let actions: [MeetingReviewController.Action] = [
                .confirm(personID: fixture.targetPersonID),
                .reassign(personID: fixture.targetPersonID),
                .confirmAsNewPerson(name: "Demo Person"),
                .markMultiple,
                .resetToGeneric,
            ]

            for action in actions {
                await #expect(
                    throws: MeetingReviewController.ReviewActionError
                        .demoMeetingCannotCreateVoiceEvidence
                ) {
                    _ = try await controller.perform(
                        action,
                        on: fixture.cluster,
                        data: fixture.data,
                        meetingID: fixture.meeting.id
                    )
                }

                let after = try await persistedSnapshot(
                    library: library,
                    fixture: fixture
                )
                #expect(after == before)
                #expect(!after.persons.contains { $0.displayName == "Demo Person" })
            }
        }
    }

    @Test("a stale demo confirmation wins over the voice-evidence policy error")
    func staleDemoConfirmationAsNewPersonRemainsStale() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let fixture = try await makeReviewFixture(library: library, isDemo: true)
            let controller = MeetingReviewController(library: library)
            let before = try await persistedSnapshot(
                library: library,
                fixture: fixture
            )
            let staleData = MeetingReviewData(
                runID: RunID(),
                clusters: fixture.data.clusters,
                suggestions: fixture.data.suggestions,
                resolutions: fixture.data.resolutions,
                persons: fixture.data.persons,
                personsRevision: fixture.data.personsRevision
            )

            await #expect(throws: MeetingReviewController.ReviewActionError.stale) {
                _ = try await controller.perform(
                    .confirmAsNewPerson(name: "Stale Demo Person"),
                    on: fixture.cluster,
                    data: staleData,
                    meetingID: fixture.meeting.id
                )
            }

            let after = try await persistedSnapshot(
                library: library,
                fixture: fixture
            )
            #expect(after == before)
            #expect(!after.persons.contains { $0.displayName == "Stale Demo Person" })
        }
    }

    @Test("demo keep-generic persists only the meeting-local review")
    func demoKeepGenericDoesNotRewriteGlobalIdentityOrMeeting() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let fixture = try await makeReviewFixture(
                library: library,
                isDemo: true,
                clusterIsConfirmed: false
            )
            let controller = MeetingReviewController(library: library)
            let before = try await persistedSnapshot(
                library: library,
                fixture: fixture
            )
            try await Task.sleep(for: .milliseconds(20))

            let updated = try await controller.perform(
                .keepGeneric,
                on: fixture.cluster,
                data: fixture.data,
                meetingID: fixture.meeting.id
            )

            let after = try await persistedSnapshot(
                library: library,
                fixture: fixture
            )
            #expect(updated.clusters[0].reviewState == .generic)
            #expect(updated.personsRevision == fixture.data.personsRevision)
            #expect(updated.persons == fixture.data.persons)
            #expect(after.personsDocument == before.personsDocument)
            #expect(after.meetingDocument == before.meetingDocument)
            #expect(after.personsRevision == before.personsRevision)
            #expect(after.persons == before.persons)
            #expect(after.participantIDs == before.participantIDs)
            #expect(after.prototypes == before.prototypes)
            #expect(after.hardNegatives == before.hardNegatives)
            #expect(after.reviewDocument.data != before.reviewDocument.data)
            #expect(after.reviewDocument.inode != before.reviewDocument.inode)
            #expect(
                after.reviewDocument.modificationDate
                    > before.reviewDocument.modificationDate
            )
            #expect(after.reviewClusters[0].reviewState == .generic)
        }
    }

    @Test("keep-generic rejects a concurrently changed review")
    func keepGenericRejectsConcurrentReviewChange() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let fixture = try await makeReviewFixture(
                library: library,
                isDemo: true,
                clusterIsConfirmed: false
            )
            var concurrentCluster = fixture.cluster
            concurrentCluster.containsMultipleSpeakers = true
            concurrentCluster.reviewState = .multiple
            try MeetingReviewStore(layout: library.layout).save(
                MeetingReviewDocument(
                    runID: fixture.runID,
                    clusters: [concurrentCluster]
                ),
                meetingID: fixture.meeting.id
            )
            let before = try await persistedSnapshot(
                library: library,
                fixture: fixture
            )

            await #expect(throws: MeetingReviewController.ReviewActionError.stale) {
                _ = try await MeetingReviewController(library: library).perform(
                    .keepGeneric,
                    on: fixture.cluster,
                    data: fixture.data,
                    meetingID: fixture.meeting.id
                )
            }

            let after = try await persistedSnapshot(
                library: library,
                fixture: fixture
            )
            #expect(after == before)
            #expect(after.reviewClusters[0].reviewState == .multiple)
        }
    }

    @Test("keep-generic replaces a previous-run review for the canonical run")
    func keepGenericAcceptsCanonicalRunAfterRediarization() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let meeting = try await library.createMeeting(
                title: "Re-diarized review",
                status: .ready
            )
            let previousRunID = RunID()
            let previousCluster = reviewCluster(
                meetingID: meeting.id,
                runID: previousRunID
            )
            try MeetingReviewStore(layout: library.layout).save(
                MeetingReviewDocument(
                    runID: previousRunID,
                    clusters: [previousCluster]
                ),
                meetingID: meeting.id
            )

            let currentRunID = RunID()
            let currentCluster = reviewCluster(
                meetingID: meeting.id,
                runID: currentRunID
            )
            try seedIdentitySuggestionRun(
                meetingID: meeting.id,
                runID: currentRunID,
                cluster: currentCluster,
                library: library
            )
            let current = try #require(try await MeetingReviewAssembler.load(
                library: library,
                meetingID: meeting.id
            ))
            let target = try #require(current.clusters.first)
            #expect(current.runID == currentRunID)
            #expect(target.runID == currentRunID)

            let reviewURL = library.layout.meetingDirectory(meeting.id)
                .appendingPathComponent("review.json")
            let reviewPath = relativePath(of: reviewURL, below: root)
            var beforeNonReview = try rootSnapshot(at: root)
            let previousReviewValue = beforeNonReview.removeValue(forKey: reviewPath)
            let previousReview = try #require(previousReviewValue)

            let updated = try await MeetingReviewController(library: library).perform(
                .keepGeneric,
                on: target,
                data: current,
                meetingID: meeting.id
            )

            var afterNonReview = try rootSnapshot(at: root)
            let currentReviewValue = afterNonReview.removeValue(forKey: reviewPath)
            let currentReview = try #require(currentReviewValue)
            let persisted = try #require(
                try MeetingReviewStore(layout: library.layout).load(meetingID: meeting.id)
            )
            #expect(updated.runID == currentRunID)
            #expect(updated.clusters[0].reviewState == .generic)
            #expect(persisted.runID == currentRunID)
            #expect(persisted.clusters[0].reviewState == .generic)
            #expect(currentReview != previousReview)
            let archivePath = relativePath(of: library.layout.meetingDirectory(meeting.id).appendingPathComponent("review-history/\(previousRunID).json"), below: root)
            let archivedValue = afterNonReview.removeValue(forKey: archivePath)
            let archived = try #require(archivedValue)
            #expect(archived.data == previousReview.data)
            #expect(try MeetingReviewStore(layout: library.layout).load(meetingID: meeting.id, runID: previousRunID)?.clusters == [previousCluster])
            #expect(afterNonReview == beforeNonReview)
        }
    }

    @Test("keep-generic rejects an old caller when no review document exists")
    func keepGenericRejectsOldCallerWithoutPersistedReview() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let meeting = try await library.createMeeting(
                title: "Current review",
                status: .ready
            )
            let currentRunID = RunID()
            let currentCluster = reviewCluster(
                meetingID: meeting.id,
                runID: currentRunID
            )
            try seedIdentitySuggestionRun(
                meetingID: meeting.id,
                runID: currentRunID,
                cluster: currentCluster,
                library: library
            )
            let current = try #require(try await MeetingReviewAssembler.load(
                library: library,
                meetingID: meeting.id
            ))
            #expect(current.runID == currentRunID)

            let previousRunID = RunID()
            let previousCluster = reviewCluster(
                meetingID: meeting.id,
                runID: previousRunID
            )
            let previous = MeetingReviewData(
                runID: previousRunID,
                clusters: [previousCluster],
                suggestions: [],
                resolutions: current.resolutions,
                persons: current.persons,
                personsRevision: current.personsRevision
            )
            let reviewURL = library.layout.meetingDirectory(meeting.id)
                .appendingPathComponent("review.json")
            let reviewPath = relativePath(of: reviewURL, below: root)
            let before = try rootSnapshot(at: root)
            #expect(before[reviewPath] == nil)

            await #expect(throws: MeetingReviewController.ReviewActionError.stale) {
                _ = try await MeetingReviewController(library: library).perform(
                    .keepGeneric,
                    on: previousCluster,
                    data: previous,
                    meetingID: meeting.id
                )
            }

            let after = try rootSnapshot(at: root)
            #expect(after == before)
            #expect(after[reviewPath] == nil)
        }
    }

    @Test("an otherwise identical real meeting still creates voice evidence")
    func realMeetingVoiceEvidenceRemainsAllowed() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let fixture = try await makeReviewFixture(library: library, isDemo: false)
            let controller = MeetingReviewController(library: library)

            _ = try await controller.perform(
                .confirmAsNewPerson(name: "Real Person"),
                on: fixture.cluster,
                data: fixture.data,
                meetingID: fixture.meeting.id
            )

            let stored = try await persistedSnapshot(
                library: library,
                fixture: fixture
            )
            let created = try #require(
                stored.persons.first { $0.displayName == "Real Person" }
            )
            #expect(created.prototypes.contains {
                $0.meetingID == fixture.meeting.id
                    && $0.runID == fixture.runID
                    && $0.clusterID == fixture.cluster.clusterID
            })
            #expect(stored.participantIDs.contains(created.id))
            #expect(stored.reviewClusters[0].reviewState == .confirmed(created.id))
        }
    }

    @Test("a crash during mark-multiple never leaves a named cluster without evidence")
    func partialMarkMultiplePersistenceFailsSafe() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let meeting = try await library.createMeeting(title: "Review", status: .ready)
            let identityStore = try IdentityStore(layout: library.layout)
            let runID = RunID()
            let personID = PersonID()
            let prototype = SpeakerPrototype(
                personID: personID,
                embedding: [1, 0],
                recordingType: .remote,
                channel: "system",
                meetingID: meeting.id,
                runID: runID,
                clusterID: "speaker-1",
                speechDurationSeconds: 30,
                segmentCount: 4,
                source: .userConfirmed
            )
            let person = Person(
                id: personID,
                displayName: "Ada",
                prototypes: [prototype]
            )
            try await replacePersonsForTest([person], in: identityStore)
            let snapshot = try await identityStore.snapshot()
            let cluster = IdentityCluster(
                meetingID: meeting.id,
                runID: runID,
                channel: "system",
                clusterID: "speaker-1",
                recordingType: .remote,
                embedding: [1, 0],
                speechDurationSeconds: 30,
                segmentCount: 4,
                reviewState: .confirmed(personID)
            )
            try MeetingReviewStore(layout: library.layout).save(
                MeetingReviewDocument(runID: runID, clusters: [cluster]),
                meetingID: meeting.id
            )
            _ = try await library.updateMeetingParticipants(
                meeting.id,
                participantIDs: [personID]
            )
            let controller = MeetingReviewController(
                library: library,
                persistenceCheckpoint: { checkpoint, transaction in
                    try transaction.validate(layout: library.layout)
                    guard checkpoint == .afterUnconfirmedReview else { return }
                    throw ReviewPersistenceTestError.injectedCrash
                }
            )

            await #expect(throws: ReviewPersistenceTestError.injectedCrash) {
                _ = try await controller.perform(
                    .markMultiple,
                    on: cluster,
                    data: review(runID: runID, cluster: cluster, snapshot: snapshot),
                    meetingID: meeting.id
                )
            }

            let loadedReview = try MeetingReviewStore(
                layout: library.layout
            ).load(meetingID: meeting.id)
            let storedReview = try #require(loadedReview)
            let storedPerson = try #require(
                try await identityStore.listPersons().first { $0.id == personID }
            )
            #expect(storedReview.clusters[0].reviewState == .multiple)
            #expect(storedReview.clusters[0].containsMultipleSpeakers)
            #expect(storedPerson.prototypes.map(\.id) == [prototype.id])
        }
    }

    @Test("a changed persons document reloads cleanly before the review is retried")
    func stalePersonsDocumentCanBeRetriedAfterReload() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let meeting = try await library.createMeeting(title: "Review", status: .ready)
            let identityStore = try IdentityStore(layout: library.layout)
            let stale = try await identityStore.snapshot()
            let runID = RunID()
            let cluster = IdentityCluster(
                meetingID: meeting.id,
                runID: runID,
                channel: "system",
                clusterID: "speaker-1",
                recordingType: .remote,
                embedding: [1, 0],
                speechDurationSeconds: 30,
                segmentCount: 4
            )
            let staleReview = review(
                runID: runID,
                cluster: cluster,
                snapshot: stale
            )
            _ = try await identityStore.createPerson(displayName: "Grace")
            let controller = MeetingReviewController(library: library)

            await #expect(throws: MeetingReviewController.ReviewActionError.stale) {
                _ = try await controller.perform(
                    .markMultiple,
                    on: cluster,
                    data: staleReview,
                    meetingID: meeting.id
                )
            }

            let reloaded = try await identityStore.snapshot()
            let updated = try await controller.perform(
                .markMultiple,
                on: cluster,
                data: review(runID: runID, cluster: cluster, snapshot: reloaded),
                meetingID: meeting.id
            )

            #expect(updated.clusters[0].reviewState == .multiple)
            #expect(updated.persons.map(\.displayName) == ["Grace"])
            #expect(try await identityStore.listPersons().map(\.displayName) == ["Grace"])
        }
    }

    @Test("a draft meeting and its absent review load under one snapshot")
    func draftMeetingSnapshotHasNoReview() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let meeting = try await library.createMeeting(title: "Draft", status: .draft)

            let snapshot = try await MeetingReviewAssembler.loadMeetingAndReview(
                library: library,
                meetingID: meeting.id
            )

            #expect(snapshot.meeting == meeting)
            #expect(snapshot.review == nil)
        }
    }

    /// The iPad inspector derives its participant list from meeting and
    /// review together (`MeetingParticipantsSection`); a snapshot that could
    /// tear between the two reads could show a confirmed speaker next to
    /// participant IDs from before the confirmation.
    @Test("meeting and review stay coherent after a confirmed review action")
    func meetingAndReviewSnapshotReflectsConfirmedReview() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let meeting = try await library.createMeeting(title: "Review", status: .ready)
            let identityStore = try IdentityStore(layout: library.layout)
            let person = try await identityStore.createPerson(displayName: "Ada")
            let snapshot = try await identityStore.snapshot()
            let runID = RunID()
            let cluster = IdentityCluster(
                meetingID: meeting.id,
                runID: runID,
                channel: MediaAsset.Kind.systemTrack.rawValue,
                clusterID: "speaker-1",
                recordingType: .remote,
                embedding: [1, 0],
                speechDurationSeconds: 30,
                segmentCount: 4
            )
            try seedIdentitySuggestionRun(
                meetingID: meeting.id,
                runID: runID,
                cluster: cluster,
                library: library
            )
            let controller = MeetingReviewController(library: library)
            _ = try await controller.perform(
                .confirm(personID: person.id),
                on: cluster,
                data: review(runID: runID, cluster: cluster, snapshot: snapshot),
                meetingID: meeting.id
            )

            let combined = try await MeetingReviewAssembler.loadMeetingAndReview(
                library: library,
                meetingID: meeting.id
            )

            let confirmedCluster = try #require(
                combined.review?.clusters.first { $0.clusterID == cluster.clusterID }
            )
            #expect(confirmedCluster.reviewState == .confirmed(person.id))
            #expect(combined.meeting.participantIDs.contains(person.id))
        }
    }

    /// Minimal diarization plus finished identity-suggestion run so the
    /// assembler has a canonical run and cluster source. A matching
    /// review.json may overlay that source, but cannot establish it alone.
    private func seedIdentitySuggestionRun(
        meetingID: MeetingID,
        runID: RunID,
        cluster: IdentityCluster,
        library: Library
    ) throws {
        let layout = library.layout
        let diarization = DiarizationArtifact(
            jobID: JobID(),
            sourceRunID: runID,
            revisionID: RevisionID(),
            tracks: [
                DiarizationTrackResult(
                    assetID: MediaAssetID(),
                    assetKind: .systemTrack,
                    engine: EngineDescriptor(name: "Test", version: "1"),
                    segments: [
                        DiarizationRunSegment(clusterID: cluster.clusterID, start: 0, end: 1),
                    ],
                    clusters: [
                        DiarizationClusterResult(
                            clusterID: cluster.clusterID,
                            embedding: cluster.embedding,
                            speechDurationSeconds: cluster.speechDurationSeconds,
                            segmentCount: cluster.segmentCount
                        ),
                    ]
                ),
            ]
        )
        try writeRun(
            ProcessingRun(
                id: runID,
                meetingID: meetingID,
                kind: .diarization,
                engine: EngineDescriptor(name: "Test", version: "1"),
                status: .finished
            ),
            artifact: diarization,
            artifactName: "diarization.json",
            layout: layout
        )
        try writeRun(
            ProcessingRun(
                id: RunID(),
                meetingID: meetingID,
                kind: .identitySuggestion,
                engine: EngineDescriptor(name: "Test", version: "1"),
                status: .finished
            ),
            artifact: IdentitySuggestionArtifact(
                jobID: JobID(),
                sourceRunID: runID,
                clusterResolutions: [
                    IdentityClusterResolution(
                        channel: cluster.channel,
                        sourceClusterID: cluster.clusterID,
                        primaryClusterID: cluster.clusterID
                    ),
                ],
                identityEvidenceFingerprint: "fixture",
                suggestions: []
            ),
            artifactName: "suggestions.json",
            layout: layout
        )
    }

    private func writeRun<Artifact: Encodable>(
        _ run: ProcessingRun,
        artifact: Artifact,
        artifactName: String,
        layout: LibraryLayout
    ) throws {
        let directory = layout.runDirectory(run.meetingID, runID: run.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try AtomicFile.write(encoder.encode(run), to: directory.appendingPathComponent("run.json"))
        try AtomicFile.write(encoder.encode(artifact), to: directory.appendingPathComponent(artifactName))
    }

    private func review(
        runID: RunID,
        cluster: IdentityCluster,
        snapshot: IdentityDocumentSnapshot
    ) -> MeetingReviewData {
        MeetingReviewData(
            runID: runID,
            clusters: [cluster],
            suggestions: [],
            resolutions: [],
            persons: snapshot.persons,
            personsRevision: snapshot.revision
        )
    }

    private func reviewCluster(
        meetingID: MeetingID,
        runID: RunID
    ) -> IdentityCluster {
        IdentityCluster(
            meetingID: meetingID,
            runID: runID,
            channel: MediaAsset.Kind.systemTrack.rawValue,
            clusterID: "speaker-1",
            recordingType: .remote,
            embedding: [1, 0],
            speechDurationSeconds: 30,
            segmentCount: 4
        )
    }

    private func makeReviewFixture(
        library: Library,
        isDemo: Bool,
        clusterIsConfirmed: Bool = true
    ) async throws -> ControllerReviewFixture {
        let metadata = isDemo
            ? MeetingMetadata(demoProvenance: DemoProvenance(
                datasetID: "org.steno.synthetic-demo",
                datasetVersion: "1",
                itemID: "review-policy"
            ))
            : nil
        let meeting = try await library.createMeeting(
            title: "DEMO: Review policy fixture",
            status: .ready,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            metadata: metadata
        )
        let identityStore = try IdentityStore(layout: library.layout)
        let runID = RunID()
        let ownerID = PersonID()
        let targetID = PersonID()
        let cluster = IdentityCluster(
            meetingID: meeting.id,
            runID: runID,
            channel: MediaAsset.Kind.systemTrack.rawValue,
            clusterID: "speaker-1",
            recordingType: .remote,
            embedding: [1, 0],
            speechDurationSeconds: 30,
            segmentCount: 4,
            reviewState: clusterIsConfirmed ? .confirmed(ownerID) : .unreviewed
        )
        let evidenceRunID = clusterIsConfirmed ? runID : RunID()
        let evidenceClusterID = clusterIsConfirmed ? cluster.clusterID : "prior-speaker"
        let prototype = SpeakerPrototype(
            personID: ownerID,
            embedding: cluster.embedding,
            recordingType: cluster.recordingType,
            channel: cluster.channel,
            meetingID: meeting.id,
            runID: evidenceRunID,
            clusterID: evidenceClusterID,
            speechDurationSeconds: cluster.speechDurationSeconds,
            segmentCount: cluster.segmentCount,
            source: .userConfirmed,
            createdAt: Date(timeIntervalSince1970: 1_700_000_001)
        )
        let negative = HardNegative(
            personID: targetID,
            embedding: cluster.embedding,
            recordingType: cluster.recordingType,
            channel: cluster.channel,
            meetingID: meeting.id,
            runID: evidenceRunID,
            clusterID: evidenceClusterID,
            speechDurationSeconds: cluster.speechDurationSeconds,
            segmentCount: cluster.segmentCount,
            source: .userConfirmed,
            createdAt: Date(timeIntervalSince1970: 1_700_000_002)
        )
        let persons = [
            Person(
                id: ownerID,
                displayName: "Ada",
                createdAt: Date(timeIntervalSince1970: 1_700_000_003),
                prototypes: [prototype]
            ),
            Person(
                id: targetID,
                displayName: "Grace",
                createdAt: Date(timeIntervalSince1970: 1_700_000_004),
                hardNegatives: [negative]
            ),
        ]
        try await replacePersonsForTest(persons, in: identityStore)
        let identity = try await identityStore.snapshot()
        try MeetingReviewStore(layout: library.layout).save(
            MeetingReviewDocument(runID: runID, clusters: [cluster]),
            meetingID: meeting.id
        )
        try seedIdentitySuggestionRun(
            meetingID: meeting.id,
            runID: runID,
            cluster: cluster,
            library: library
        )
        _ = try await library.updateMeetingParticipants(
            meeting.id,
            participantIDs: [ownerID]
        )
        return ControllerReviewFixture(
            meeting: meeting,
            identityStore: identityStore,
            runID: runID,
            cluster: cluster,
            targetPersonID: targetID,
            data: review(runID: runID, cluster: cluster, snapshot: identity)
        )
    }

    private func persistedSnapshot(
        library: Library,
        fixture: ControllerReviewFixture
    ) async throws -> PersistedReviewSnapshot {
        let layout = library.layout
        let personsDocument = try Data(contentsOf: layout.persons)
        let meetingDocument = try Data(
            contentsOf: layout.meetingMetadata(fixture.meeting.id)
        )
        let reviewURL = layout.meetingDirectory(fixture.meeting.id)
            .appendingPathComponent("review.json")
        let reviewDocument = try Data(contentsOf: reviewURL)
        let identity = try await fixture.identityStore.snapshot()
        let meeting = try await library.loadMeeting(fixture.meeting.id)
        let review = try #require(
            try MeetingReviewStore(layout: layout).load(meetingID: fixture.meeting.id)
        )
        return PersistedReviewSnapshot(
            personsDocument: try fileSnapshot(
                at: layout.persons,
                data: personsDocument
            ),
            meetingDocument: try fileSnapshot(
                at: layout.meetingMetadata(fixture.meeting.id),
                data: meetingDocument
            ),
            reviewDocument: try fileSnapshot(at: reviewURL, data: reviewDocument),
            personsRevision: identity.revision,
            persons: identity.persons,
            participantIDs: meeting.participantIDs,
            reviewClusters: review.clusters,
            prototypes: identity.persons.flatMap(\.prototypes),
            hardNegatives: identity.persons.flatMap(\.hardNegatives)
        )
    }

    private func fileSnapshot(at url: URL, data: Data) throws -> PersistedFileSnapshot {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return PersistedFileSnapshot(
            data: data,
            inode: try #require(
                (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
            ),
            modificationDate: try #require(attributes[.modificationDate] as? Date)
        )
    }

    private func rootSnapshot(at root: URL) throws -> [String: PersistedFileSnapshot] {
        let root = root.standardizedFileURL
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys
        ) else {
            throw CocoaError(.fileReadUnknown)
        }
        var snapshot: [String: PersistedFileSnapshot] = [:]
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true else { continue }
            snapshot[relativePath(of: url, below: root)] = try fileSnapshot(
                at: url,
                data: Data(contentsOf: url)
            )
        }
        return snapshot
    }

    private func relativePath(of url: URL, below root: URL) -> String {
        url.standardizedFileURL.path.replacingOccurrences(
            of: root.standardizedFileURL.path + "/",
            with: "",
            options: [.anchored]
        )
    }
}

private struct ControllerReviewFixture: Sendable {
    let meeting: Meeting
    let identityStore: IdentityStore
    let runID: RunID
    let cluster: IdentityCluster
    let targetPersonID: PersonID
    let data: MeetingReviewData
}

private struct PersistedReviewSnapshot: Equatable, Sendable {
    let personsDocument: PersistedFileSnapshot
    let meetingDocument: PersistedFileSnapshot
    let reviewDocument: PersistedFileSnapshot
    let personsRevision: UUID?
    let persons: [Person]
    let participantIDs: [PersonID]
    let reviewClusters: [IdentityCluster]
    let prototypes: [SpeakerPrototype]
    let hardNegatives: [HardNegative]
}

private struct PersistedFileSnapshot: Equatable, Sendable {
    let data: Data
    let inode: UInt64
    let modificationDate: Date
}

private enum ReviewPersistenceTestError: Error {
    case injectedCrash
}
