import Foundation
import StenoDomain
import StenoIdentity
import StenoLibrary

package enum MeetingReviewPersistenceCheckpoint: Equatable, Sendable {
    case afterNeutralReview
    case afterUnconfirmedReview
    case afterPersons
    case afterParticipants
    case afterFinalReview
}

package typealias MeetingReviewPersistenceAction = @Sendable (
    MeetingReviewPersistenceCheckpoint,
    LibraryMutationTransaction
) throws -> Void

/// Führt Review-Aktionen aus und persistiert sie unter meetingweiter
/// Exklusivität. Evidenzändernde Aktionen schreiben Personenevidenz,
/// Cluster-Zustand und Teilnehmerliste zusammen. `keepGeneric` markiert nur
/// den lokalen Review-Fortschritt und schreibt deshalb ausschließlich
/// review.json.
public struct MeetingReviewController: Sendable {
    public enum Action: Sendable {
        case confirm(personID: PersonID)
        case reassign(personID: PersonID)
        case confirmAsNewPerson(name: String)
        case markMultiple
        case resetToGeneric
        case keepGeneric
    }

    public enum ReviewActionError: Error, Equatable, Sendable {
        case stale
        case rejected(String)
        case demoMeetingCannotCreateVoiceEvidence
    }

    private let library: Library
    private let engine: SpeakerSuggestionEngine
    private let persistenceAction: MeetingReviewPersistenceAction

    public init(
        library: Library,
        engine: SpeakerSuggestionEngine = SpeakerSuggestionEngine()
    ) {
        self.library = library
        self.engine = engine
        persistenceAction = { _, _ in }
    }

    package init(
        library: Library,
        engine: SpeakerSuggestionEngine = SpeakerSuggestionEngine(),
        persistenceCheckpoint: @escaping MeetingReviewPersistenceAction
    ) {
        self.library = library
        self.engine = engine
        persistenceAction = persistenceCheckpoint
    }

    public func perform(
        _ action: Action,
        on cluster: IdentityCluster,
        data: MeetingReviewData,
        meetingID: MeetingID
    ) async throws -> MeetingReviewData {
        let layout = await library.layout
        let meeting = try await library.loadMeeting(meetingID)
        var state = IdentityReviewState(
            meetingID: meetingID,
            currentRunID: data.runID,
            voiceEvidenceMutationPolicy: meeting.isDemo ? .forbidden : .allowed,
            clusters: data.clusters,
            persons: data.persons,
            participantIDs: meeting.participantIDs
        )

        let result: IdentityReviewResult
        do {
            switch action {
            case .confirm(let personID):
                result = try engine.confirm(
                    clusterID: cluster.clusterID,
                    channel: cluster.channel,
                    runID: cluster.runID,
                    as: personID,
                    in: state
                )
            case .reassign(let personID):
                result = try engine.reassign(
                    clusterID: cluster.clusterID,
                    channel: cluster.channel,
                    runID: cluster.runID,
                    to: personID,
                    in: state
                )
            case .confirmAsNewPerson(let name):
                guard cluster.runID == state.currentRunID else {
                    throw ReviewActionError.stale
                }
                guard state.voiceEvidenceMutationPolicy == .allowed else {
                    throw ReviewActionError.demoMeetingCannotCreateVoiceEvidence
                }
                let person = try IdentityStore.makePerson(displayName: name)
                state.persons.append(person)
                result = try engine.confirm(
                    clusterID: cluster.clusterID,
                    channel: cluster.channel,
                    runID: cluster.runID,
                    as: person.id,
                    in: state
                )
            case .markMultiple:
                result = try engine.markMultiple(
                    clusterID: cluster.clusterID,
                    channel: cluster.channel,
                    runID: cluster.runID,
                    in: state
                )
            case .resetToGeneric:
                result = try engine.resetToGeneric(
                    clusterID: cluster.clusterID,
                    channel: cluster.channel,
                    runID: cluster.runID,
                    in: state
                )
            case .keepGeneric:
                result = try engine.keepGeneric(
                    clusterID: cluster.clusterID,
                    channel: cluster.channel,
                    runID: cluster.runID,
                    in: state
                )
            }
        } catch IdentityReviewError.voiceEvidenceForbidden {
            throw ReviewActionError.demoMeetingCannotCreateVoiceEvidence
        }

        switch result.status {
        case .confirmed, .reassigned, .multiple, .generic:
            break
        case .stale:
            throw ReviewActionError.stale
        }

        if case .keepGeneric = action {
            return try persistReviewOnly(
                result,
                replacing: data,
                meetingID: meetingID,
                layout: layout
            )
        }

        let identityStore = try IdentityStore(layout: layout)
        let reviewStore = MeetingReviewStore(layout: layout)
        let finalReview = MeetingReviewDocument(
            runID: data.runID,
            clusters: result.state.clusters
        )
        var neutralClusters = data.clusters
        guard let neutralIndex = neutralClusters.firstIndex(where: {
            $0.meetingID == meetingID
                && $0.runID == cluster.runID
                && $0.channel == cluster.channel
                && ($0.clusterID == cluster.clusterID
                    || $0.mergedFrom.contains(cluster.clusterID))
        }) else {
            throw ReviewActionError.stale
        }
        neutralClusters[neutralIndex].reviewState = .unreviewed
        let neutralReview = MeetingReviewDocument(
            runID: data.runID,
            clusters: neutralClusters
        )

        let personsRevision: UUID
        do {
            // Die Transaktion ist eine flock und kein Mehrdatei-Rollback. Darum
            // wird eine Benennung zuerst neutralisiert und erst nach der neuen
            // Evidenz bestaetigt. Unbestaetigende Aktionen schreiben dagegen
            // ihren sicheren Zustand vor dem Entfernen alter Evidenz.
            personsRevision = try LibraryMutationCoordination.withExclusiveTransaction(
                layout: layout
            ) { transaction in
                let currentIdentity = try IdentityStore.snapshot(
                    layout: layout,
                    transaction: transaction
                )
                guard currentIdentity.revision == data.personsRevision else {
                    throw LibraryError.identityDocumentRevisionConflict
                }
                try reviewStore.save(
                    neutralReview,
                    meetingID: meetingID,
                    transaction: transaction
                )
                try persistenceAction(.afterNeutralReview, transaction)

                switch result.status {
                case .multiple, .generic:
                    try reviewStore.save(
                        finalReview,
                        meetingID: meetingID,
                        transaction: transaction
                    )
                    try persistenceAction(.afterUnconfirmedReview, transaction)
                case .confirmed, .reassigned:
                    break
                case .stale:
                    throw ReviewActionError.stale
                }

                let revision = try identityStore.replacePersons(
                    result.state.persons,
                    expectedRevision: data.personsRevision,
                    transaction: transaction
                )
                try persistenceAction(.afterPersons, transaction)
                _ = try library.updateMeetingParticipants(
                    meetingID,
                    participantIDs: result.state.participantIDs,
                    transaction: transaction
                )
                try persistenceAction(.afterParticipants, transaction)

                switch result.status {
                case .confirmed, .reassigned:
                    try reviewStore.save(
                        finalReview,
                        meetingID: meetingID,
                        transaction: transaction
                    )
                case .multiple, .generic:
                    break
                case .stale:
                    throw ReviewActionError.stale
                }
                try persistenceAction(.afterFinalReview, transaction)
                return revision
            }
        } catch LibraryError.identityDocumentRevisionConflict {
            throw ReviewActionError.stale
        }

        var updated = data
        updated.clusters = result.state.clusters
        updated.persons = result.state.persons
        updated.personsRevision = personsRevision
        updated.suggestions = engine.suggestions(
            for: result.state.clusters,
            people: result.state.persons
        )
        return updated
    }

    private func persistReviewOnly(
        _ result: IdentityReviewResult,
        replacing data: MeetingReviewData,
        meetingID: MeetingID,
        layout: LibraryLayout
    ) throws -> MeetingReviewData {
        let reviewStore = MeetingReviewStore(layout: layout)
        let finalReview = MeetingReviewDocument(
            runID: data.runID,
            clusters: result.state.clusters
        )

        try LibraryMutationCoordination.withExclusiveTransaction(
            layout: layout
        ) { transaction in
            guard let canonical = try MeetingReviewAssembler.load(
                layout: layout,
                engine: engine,
                meetingID: meetingID,
                diarizationRunID: data.runID,
                transaction: transaction
            ), canonical.runID == data.runID,
               canonical.clusters == data.clusters
            else {
                throw ReviewActionError.stale
            }

            try reviewStore.save(
                finalReview,
                meetingID: meetingID,
                transaction: transaction
            )
            try persistenceAction(.afterFinalReview, transaction)
        }

        var updated = data
        updated.clusters = result.state.clusters
        return updated
    }
}
