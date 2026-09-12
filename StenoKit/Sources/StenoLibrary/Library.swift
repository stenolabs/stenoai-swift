import CryptoKit
import Darwin
import Foundation
import StenoDomain

package enum LibraryMeetingMutationCheckpoint: Equatable, Sendable {
    case afterExclusiveTransactionBeforeRead
    case afterMeetingTrashMove(MeetingID)
}

package typealias LibraryMeetingMutationAction = @Sendable (
    LibraryMeetingMutationCheckpoint,
    LibraryMutationTransaction
) throws -> Void

package enum RecoverableMeetingTrashResult: Equatable, Sendable {
    case trashed(URL)
    case commitOutcomeUncertain
}

package struct MediaAssetFileOperations: Sendable {
    package let rename: @Sendable (URL, URL) throws -> Void
    package let copy: @Sendable (URL, URL) throws -> Void
    package let synchronizeFile: @Sendable (URL) throws -> Void
    package let synchronizeDirectory: @Sendable (URL) throws -> Void
    package let remove: @Sendable (URL) throws -> Void

    package init(
        rename: @escaping @Sendable (URL, URL) throws -> Void,
        copy: @escaping @Sendable (URL, URL) throws -> Void,
        synchronizeFile: @escaping @Sendable (URL) throws -> Void,
        synchronizeDirectory: @escaping @Sendable (URL) throws -> Void,
        remove: @escaping @Sendable (URL) throws -> Void
    ) {
        self.rename = rename
        self.copy = copy
        self.synchronizeFile = synchronizeFile
        self.synchronizeDirectory = synchronizeDirectory
        self.remove = remove
    }

    package static let live = MediaAssetFileOperations(
        rename: { source, destination in
            let result = source.path.withCString { sourcePath in
                destination.path.withCString { destinationPath in
                    Darwin.rename(sourcePath, destinationPath)
                }
            }
            guard result == 0 else {
                throw POSIXFailure(operation: "rename media", code: errno)
            }
        },
        copy: { source, destination in
            try FileManager.default.copyItem(at: source, to: destination)
        },
        synchronizeFile: { try AtomicFile.synchronizeFile($0) },
        synchronizeDirectory: { try AtomicFile.synchronizeDirectory($0) },
        remove: { try FileManager.default.removeItem(at: $0) }
    )
}

public struct MediaAssetTransferRollbackError: Error, LocalizedError, Sendable {
    public let orphanedDestination: URL
    public let transferErrorDescription: String
    public let rollbackErrorDescription: String

    public init(
        orphanedDestination: URL,
        transferError: any Error,
        rollbackError: any Error
    ) {
        self.orphanedDestination = orphanedDestination
        transferErrorDescription = transferError.localizedDescription
        rollbackErrorDescription = rollbackError.localizedDescription
    }

    public var errorDescription: String? {
        "The media transfer failed and its rollback also failed. The recording remains stored at \(orphanedDestination.path). Transfer error: \(transferErrorDescription) Rollback error: \(rollbackErrorDescription)"
    }
}

public struct MediaAssetTransferRollbackDurabilityError:
    Error,
    LocalizedError,
    Sendable
{
    public let restoredSource: URL
    public let formerDestination: URL
    public let transferErrorDescription: String
    public let synchronizationErrorDescription: String

    public init(
        restoredSource: URL,
        formerDestination: URL,
        transferError: any Error,
        synchronizationError: any Error
    ) {
        self.restoredSource = restoredSource
        self.formerDestination = formerDestination
        transferErrorDescription = transferError.localizedDescription
        synchronizationErrorDescription = synchronizationError.localizedDescription
    }

    public var errorDescription: String? {
        "The media transfer failed and the restored source path could not be made durable. The recording was restored to \(restoredSource.path), but after a power loss it may instead remain at \(formerDestination.path). Transfer error: \(transferErrorDescription) Synchronization error: \(synchronizationErrorDescription)"
    }
}

public struct LibraryMetadata: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let libraryID: UUID
    public let createdAt: Date

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        libraryID: UUID = UUIDv7Generator.shared.generate(),
        createdAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.libraryID = libraryID
        self.createdAt = createdAt
    }
}

public actor Library {
    public nonisolated let layout: LibraryLayout
    public nonisolated let openingMediaRecoveryReport: MediaAssetRecoveryReport
    private let metadata: LibraryMetadata
    private nonisolated let meetingMutationAction: LibraryMeetingMutationAction
    private var meetingChangeContinuations: [
        UUID: AsyncStream<MeetingID>.Continuation
    ] = [:]

    public static func open(at root: URL) throws -> Library {
        try Library(root: root, meetingMutationAction: { _, _ in })
    }

    package static func open(
        at root: URL,
        mutationAction: @escaping LibraryMeetingMutationAction
    ) throws -> Library {
        try Library(root: root, meetingMutationAction: mutationAction)
    }

    private init(
        root: URL,
        meetingMutationAction: @escaping LibraryMeetingMutationAction
    ) throws {
        let layout = LibraryLayout(root: root)
        self.layout = layout
        self.meetingMutationAction = meetingMutationAction

        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        let rootExists = fileManager.fileExists(
            atPath: layout.root.path,
            isDirectory: &isDirectory
        )

        if rootExists {
            guard isDirectory.boolValue else {
                throw CocoaError(.fileWriteFileExists)
            }
        } else {
            try fileManager.createDirectory(
                at: layout.root,
                withIntermediateDirectories: true
            )
        }

        if fileManager.fileExists(atPath: layout.libraryMetadata.path) {
            metadata = try JSONDocumentStore.read(
                LibraryMetadata.self,
                from: layout.libraryMetadata,
                currentSchemaVersion: LibraryMetadata.currentSchemaVersion,
                schemaVersion: \.schemaVersion
            )
        } else {
            let existingContents = try fileManager.contentsOfDirectory(
                at: layout.root,
                includingPropertiesForKeys: nil
            )
            guard existingContents.isEmpty else {
                throw LibraryError.missingLibraryMetadata(layout.libraryMetadata)
            }
            let newMetadata = LibraryMetadata()
            try JSONDocumentStore.write(newMetadata, to: layout.libraryMetadata)
            metadata = newMetadata
        }

        for directory in [
            layout.meetingsDirectory,
            layout.identityDirectory,
            layout.jobsDirectory,
            layout.exportsDirectory,
        ] {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }

        openingMediaRecoveryReport = try LibraryMutationCoordination
            .withExclusiveAccess(layout: layout) {
            try RevisionAppendRecovery.recoverAll(layout: layout)
            return try MediaAssetRecovery.recoverAll(layout: layout)
        }
    }

    public func libraryMetadata() -> LibraryMetadata {
        metadata
    }

    /// Führt mehrere package-interne Mutationen unter genau einem exklusiven
    /// Bibliotheks-Lock aus. Der isolierte Empfänger verhindert, dass ein
    /// Aufrufer darin in einen zweiten Actor-Sprung oder Lock gerät.
    package func withExclusiveMutationTransaction<Result: Sendable>(
        _ body: @Sendable (isolated Library, LibraryMutationTransaction) throws -> Result
    ) throws -> Result {
        try LibraryMutationCoordination.withExclusiveTransaction(layout: layout) { transaction in
            try body(self, transaction)
        }
    }

    public func createMeeting(
        title: String,
        status: Meeting.Status,
        createdAt: Date = Date(),
        metadata: MeetingMetadata? = nil,
        sourceLocale: MeetingSourceLocale? = nil,
        transcriptionPlan: TranscriptionPlan? = nil
    ) throws -> Meeting {
        let meeting = Meeting(
            title: title,
            createdAt: createdAt,
            status: status,
            metadata: metadata,
            sourceLocale: sourceLocale,
            transcriptionPlan: transcriptionPlan
        )
        try LibraryMutationCoordination.withExclusiveAccess(layout: layout) {
            try createMeetingDirectories(meeting.id)
            try JSONDocumentStore.write(meeting, to: layout.meetingMetadata(meeting.id))
        }
        return meeting
    }

    public func loadMeeting(_ meetingID: MeetingID) throws -> Meeting {
        try Self.loadMeeting(meetingID, layout: layout)
    }

    package nonisolated func loadMeeting(
        _ meetingID: MeetingID,
        transaction: LibraryMutationTransaction
    ) throws -> Meeting {
        try transaction.validate(layout: layout)
        return try Self.loadMeeting(meetingID, layout: layout)
    }

    private nonisolated static func loadMeeting(
        _ meetingID: MeetingID,
        layout: LibraryLayout
    ) throws -> Meeting {
        let url = layout.meetingMetadata(meetingID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LibraryError.meetingNotFound(meetingID)
        }
        return try JSONDocumentStore.read(
            Meeting.self,
            from: url,
            currentSchemaVersion: Meeting.currentSchemaVersion,
            schemaVersion: \.schemaVersion
        )
    }

    public func listMeetings() throws -> [Meeting] {
        let directories = try FileManager.default.contentsOfDirectory(
            at: layout.meetingsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        let meetings = try directories.compactMap { directory -> Meeting? in
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { return nil }
            let document = directory.appendingPathComponent("meeting.json")
            guard FileManager.default.fileExists(atPath: document.path) else { return nil }
            return try JSONDocumentStore.read(
                Meeting.self,
                from: document,
                currentSchemaVersion: Meeting.currentSchemaVersion,
                schemaVersion: \.schemaVersion
            )
        }
        return meetings.sorted {
            if $0.createdAt == $1.createdAt { return $0.id > $1.id }
            return $0.createdAt > $1.createdAt
        }
    }

    /// Meldet persistierte Statusaenderungen als Invalidierungssignal.
    /// Konsumenten laden das Meeting danach erneut, statt einen moeglicherweise
    /// ueberholten Payload in ihren Anzeigezustand zu uebernehmen.
    public func meetingChanges() -> AsyncStream<MeetingID> {
        let token = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: MeetingID.self)
        meetingChangeContinuations[token] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeMeetingChangeContinuation(token) }
        }
        return stream
    }

    public func updateMeetingStatus(
        _ meetingID: MeetingID,
        to status: Meeting.Status
    ) throws -> Meeting {
        let result = try LibraryMutationCoordination.withExclusiveTransaction(
            layout: layout
        ) { transaction in
            let previous = try loadMeeting(meetingID, transaction: transaction)
            let meeting = try updateMeetingStatus(
                meetingID,
                to: status,
                transaction: transaction
            )
            return (meeting, previous.status != meeting.status)
        }
        if result.1 {
            publishMeetingChange(meetingID)
        }
        return result.0
    }

    package nonisolated func updateMeetingStatus(
        _ meetingID: MeetingID,
        to status: Meeting.Status,
        transaction: LibraryMutationTransaction
    ) throws -> Meeting {
        try transaction.validate(layout: layout)
        var meeting = try Self.loadMeeting(meetingID, layout: layout)
        guard meeting.status != status else { return meeting }
        meeting.status = status
        try JSONDocumentStore.write(meeting, to: layout.meetingMetadata(meetingID))
        return meeting
    }

    private func withMeetingMutation<Result>(
        _ body: (LibraryMutationTransaction) throws -> Result
    ) throws -> Result {
        try LibraryMutationCoordination.withExclusiveTransaction(
            layout: layout
        ) { transaction in
            try meetingMutationAction(
                .afterExclusiveTransactionBeforeRead,
                transaction
            )
            return try body(transaction)
        }
    }

    private nonisolated func writeMeeting(
        _ meeting: Meeting,
        transaction: LibraryMutationTransaction
    ) throws {
        try transaction.validate(layout: layout)
        try JSONDocumentStore.write(
            meeting,
            to: layout.meetingMetadata(meeting.id)
        )
    }

    private func removeMeetingChangeContinuation(_ token: UUID) {
        meetingChangeContinuations.removeValue(forKey: token)
    }

    package func publishMeetingChange(_ meetingID: MeetingID) {
        for continuation in meetingChangeContinuations.values {
            continuation.yield(meetingID)
        }
    }

    /// Teilnehmerliste ist meeting-skopiert, nicht run-skopiert: Anwesenheit
    /// bleibt wahr, egal wie oft neu diarisiert wird (Alt-Invariante).

    /// Records which tracks this recording never got.
    ///
    /// Written once when the recording ends, so everything that later presents
    /// the meeting - and above all a generated report - can say that a side of
    /// the conversation is missing instead of silently leaving it out.
    @discardableResult
    public func updateUnrecordedTracks(
        _ meetingID: MeetingID,
        to tracks: [MediaAsset.Kind]
    ) throws -> Meeting {
        let result = try LibraryMutationCoordination.withExclusiveTransaction(
            layout: layout
        ) { transaction in
            try transaction.validate(layout: layout)
            var meeting = try Self.loadMeeting(meetingID, layout: layout)
            guard meeting.unrecordedTracks != tracks else {
                return (meeting, false)
            }
            meeting.unrecordedTracks = tracks
            try JSONDocumentStore.write(
                meeting,
                to: layout.meetingMetadata(meetingID)
            )
            return (meeting, true)
        }
        if result.1 {
            publishMeetingChange(meetingID)
        }
        return result.0
    }

    public func updateMeetingParticipants(
        _ meetingID: MeetingID,
        participantIDs: [PersonID]
    ) throws -> Meeting {
        try withMeetingMutation { transaction in
            var meeting = try loadMeeting(meetingID, transaction: transaction)
            meeting.participantIDs = participantIDs
            try writeMeeting(meeting, transaction: transaction)
            return meeting
        }
    }

    package nonisolated func updateMeetingParticipants(
        _ meetingID: MeetingID,
        participantIDs: [PersonID],
        transaction: LibraryMutationTransaction
    ) throws -> Meeting {
        try transaction.validate(layout: layout)
        var meeting = try loadMeeting(meetingID, transaction: transaction)
        meeting.participantIDs = participantIDs
        try writeMeeting(meeting, transaction: transaction)
        return meeting
    }

    /// Vom Benutzer ergänzte Anwesende ohne Sprachbeleg. Personen, die bereits
    /// über einen bestätigten Redebeitrag als Teilnehmer geführt werden,
    /// werden hier nicht doppelt gehalten.
    @discardableResult
    public func updateAdditionalMeetingParticipants(
        _ meetingID: MeetingID,
        participantIDs: [PersonID]
    ) throws -> Meeting {
        try withMeetingMutation { transaction in
            var meeting = try loadMeeting(meetingID, transaction: transaction)
            var seen: Set<PersonID> = Set(meeting.participantIDs)
            meeting.additionalParticipantIDs = participantIDs.filter {
                seen.insert($0).inserted
            }
            try writeMeeting(meeting, transaction: transaction)
            return meeting
        }
    }

    /// Legt das Meeting in einen Ordner oder nimmt es heraus (nil).
    /// Geprueft wird hier nichts: ob es den Ordner gibt, weiss der
    /// `FolderStore`, und eine ins Leere zeigende Kennung gilt ueberall wie
    /// "nicht einsortiert".
    @discardableResult
    public func setMeetingFolder(
        _ meetingID: MeetingID,
        folderID: FolderID?
    ) throws -> Meeting {
        guard let meeting = try setMeetingFolders(
            Set([meetingID]),
            folderID: folderID
        ).first else {
            throw LibraryError.meetingNotFound(meetingID)
        }
        return meeting
    }

    @discardableResult
    public func setMeetingFolders(
        _ meetingIDs: Set<MeetingID>,
        folderID: FolderID?
    ) throws -> [Meeting] {
        try withMeetingMutation { transaction in
            let originals = try meetingIDs.sorted().map {
                try loadMeeting($0, transaction: transaction)
            }
            return try Self.writeMeetingFolderBatch(
                originals: originals,
                folderID: folderID,
                write: { meeting in
                    try writeMeeting(meeting, transaction: transaction)
                },
                restore: { meeting in
                    try writeMeeting(meeting, transaction: transaction)
                }
            )
        }
    }

    static func writeMeetingFolderBatch(
        originals: [Meeting],
        folderID: FolderID?,
        write: (Meeting) throws -> Void,
        restore: (Meeting) throws -> Void
    ) throws -> [Meeting] {
        let originals = originals.sorted { $0.id < $1.id }
        var updated: [Meeting] = []
        var writtenOriginals: [Meeting] = []
        do {
            for original in originals {
                var meeting = original
                meeting.folderID = folderID
                try write(meeting)
                updated.append(meeting)
                writtenOriginals.append(original)
            }
            return updated
        } catch {
            var restorationFailures: [MeetingID] = []
            for original in writtenOriginals.reversed() {
                do {
                    try restore(original)
                } catch {
                    restorationFailures.append(original.id)
                }
            }
            throw MeetingFolderBatchError(
                reason: String(describing: error),
                restorationFailures: restorationFailures
            )
        }
    }

    public func renameMeeting(
        _ meetingID: MeetingID,
        to title: String
    ) throws -> Meeting {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LibraryError.invalidMeetingTitle }
        return try withMeetingMutation { transaction in
            var renamed = try loadMeeting(meetingID, transaction: transaction)
            renamed.title = trimmed
            try writeMeeting(renamed, transaction: transaction)
            return renamed
        }
    }

    /// Pinnt die gewählten ASR-Provider atomar im Meeting.
    @discardableResult
    public func setTranscriptionPlan(
        _ plan: TranscriptionPlan,
        for meetingID: MeetingID
    ) throws -> Meeting {
        try withMeetingMutation { transaction in
            var meeting = try loadMeeting(meetingID, transaction: transaction)
            meeting.transcriptionPlan = plan
            try writeMeeting(meeting, transaction: transaction)
            return meeting
        }
    }

    /// Pinnt die fuer dieses Meeting gewaehlte Report-Vorlage atomar
    /// (nil hebt die Pinning auf). Das globale Default greift nur, wenn
    /// hier nichts gepinnt ist.
    @discardableResult
    public func setPinnedTemplate(
        _ templateID: String?,
        for meetingID: MeetingID
    ) throws -> Meeting {
        try withMeetingMutation { transaction in
            let meeting = try loadMeeting(meetingID, transaction: transaction)
            // `metadata` is a let property, so the pinned copy is
            // reconstructed through the memberwise init.
            let updated = Meeting(
                schemaVersion: meeting.schemaVersion,
                id: meeting.id,
                title: meeting.title,
                createdAt: meeting.createdAt,
                status: meeting.status,
                participantIDs: meeting.participantIDs,
                additionalParticipantIDs: meeting.additionalParticipantIDs,
                folderID: meeting.folderID,
                metadata: (meeting.metadata ?? MeetingMetadata())
                    .withPinnedTemplateID(templateID),
                sourceLocale: meeting.sourceLocale,
                transcriptionPlan: meeting.transcriptionPlan
            )
            try writeMeeting(updated, transaction: transaction)
            return updated
        }
    }

    /// Verschiebt den kompletten Meeting-Ordner in den Papierkorb statt hart
    /// zu löschen: Originale sind besonders geschützt, ein Fehlgriff bleibt
    /// über den Papierkorb wiederherstellbar. Liefert den Papierkorb-Ort.
    @discardableResult
    public func trashMeeting(_ meetingID: MeetingID) throws -> URL? {
        let directory = layout.meetingDirectory(meetingID)
        var trashedURL: NSURL?
        try LibraryMutationCoordination.withExclusiveAccess(layout: layout) {
            guard FileManager.default.fileExists(atPath: directory.path) else {
                throw LibraryError.meetingNotFound(meetingID)
            }
            #if os(iOS)
            trashedURL = try LibraryTrashStore(layout: layout).move(meetingID) as NSURL
            #else
            try FileManager.default.trashItem(at: directory, resultingItemURL: &trashedURL)
            #endif
        }
        return trashedURL as URL?
    }

    /// Package-interne Variante für Lebenszyklen, die Besitzprüfung und genau
    /// einen recoverable Trash-Commit unter demselben Root-Lock ausführen.
    package nonisolated func trashMeeting(
        _ meetingID: MeetingID,
        expectedProcessingGenerationID: MeetingTransferGenerationID?,
        transaction: LibraryMutationTransaction
    ) throws -> RecoverableMeetingTrashResult {
        try transaction.validate(layout: layout)
        let meeting = try loadMeeting(meetingID, transaction: transaction)
        guard meeting.processingGenerationID == expectedProcessingGenerationID else {
            throw LibraryError.meetingNotFound(meetingID)
        }
        let source = layout.meetingDirectory(meetingID)
        let sourceVolume = try source.resourceValues(
            forKeys: [.volumeIdentifierKey]
        ).volumeIdentifier.map(String.init(describing:))
        var destination: NSURL?
        do {
            #if os(iOS)
            destination = try LibraryTrashStore(layout: layout).move(meetingID) as NSURL
            #else
            try FileManager.default.trashItem(
                at: source,
                resultingItemURL: &destination
            )
            #endif
            try meetingMutationAction(
                .afterMeetingTrashMove(meetingID),
                transaction
            )
        } catch {
            if !FileManager.default.fileExists(atPath: source.path) {
                return .commitOutcomeUncertain
            }
            throw error
        }
        guard !FileManager.default.fileExists(atPath: source.path),
              let destination = destination as URL?,
              FileManager.default.fileExists(atPath: destination.path),
              try destination.resourceValues(forKeys: [.volumeIdentifierKey])
                .volumeIdentifier.map(String.init(describing:)) == sourceVolume
        else {
            return .commitOutcomeUncertain
        }
        return .trashed(destination)
    }

    public func setMeetingParticipants(
        _ meetingID: MeetingID,
        participantIDs: [PersonID]
    ) throws -> Meeting {
        try withMeetingMutation { transaction in
            var meeting = try loadMeeting(meetingID, transaction: transaction)
            var seen: Set<PersonID> = []
            meeting.participantIDs = participantIDs.filter {
                seen.insert($0).inserted
            }
            try writeMeeting(meeting, transaction: transaction)
            return meeting
        }
    }

    public func registerMediaAsset(
        for meetingID: MeetingID,
        sourceURL: URL,
        kind: MediaAsset.Kind,
        sampleRate: Double,
        duration: TimeInterval
    ) throws -> MediaAsset {
        try registerMediaAsset(
            for: meetingID,
            sourceURL: sourceURL,
            kind: kind,
            sampleRate: sampleRate,
            duration: duration,
            consumesSource: false,
            fileOperations: .live
        )
    }

    package func registerCapturedMediaAsset(
        for meetingID: MeetingID,
        sourceURL: URL,
        kind: MediaAsset.Kind,
        sampleRate: Double,
        duration: TimeInterval,
        fileOperations: MediaAssetFileOperations = .live
    ) throws -> MediaAsset {
        try registerMediaAsset(
            for: meetingID,
            sourceURL: sourceURL,
            kind: kind,
            sampleRate: sampleRate,
            duration: duration,
            consumesSource: true,
            fileOperations: fileOperations
        )
    }

    private func registerMediaAsset(
        for meetingID: MeetingID,
        sourceURL: URL,
        kind: MediaAsset.Kind,
        sampleRate: Double,
        duration: TimeInterval,
        consumesSource: Bool,
        fileOperations: MediaAssetFileOperations
    ) throws -> MediaAsset {
        _ = try loadMeeting(meetingID)

        let provenanceKey: String
        if kind == .imported {
            provenanceKey = try sha256(of: sourceURL)
        } else {
            // Angehaengte Aufnahmen ("Continue recording") registrieren
            // weitere Spuren desselben Typs im selben Meeting. Die
            // fortlaufende Nummer im Schluessel haelt sie auseinander,
            // waehrend die erste Spur den historischen Schluessel behaelt.
            let sequence = RecordedTrackProvenanceKey.nextSequence(
                for: meetingID,
                kind: kind,
                in: try Self.listMediaAssets(
                    meetingID: meetingID,
                    layout: layout
                )
            )
            provenanceKey = RecordedTrackProvenanceKey.make(
                meetingID: meetingID,
                kind: kind,
                sequence: sequence
            )
        }

        // Nur importierte Schluessel sind global eindeutig; aufgezeichnete
        // Schluessel tragen die Meeting-ID und kollidieren nie ueber Meetings.
        if kind == .imported,
           let duplicate = try findMediaAsset(provenanceKey: provenanceKey) {
            throw LibraryError.duplicateProvenance(
                key: provenanceKey,
                existingMeetingID: duplicate.meetingID
            )
        }

        let assetID = MediaAssetID()
        let pathExtension = sourceURL.pathExtension.isEmpty
            ? (kind == .imported ? "bin" : "caf")
            : sourceURL.pathExtension.lowercased()
        let fileName = consumesSource && kind != .imported
            ? "\(assetID)-\(kind.rawValue).\(pathExtension)"
            : "\(assetID).\(pathExtension)"
        let asset = MediaAsset(
            id: assetID,
            meetingID: meetingID,
            kind: kind,
            sampleRate: sampleRate,
            duration: duration,
            provenanceKey: provenanceKey,
            fileName: fileName
        )
        let destination = layout.mediaFile(meetingID, fileName: fileName)
        try LibraryMutationCoordination.withExclusiveAccess(layout: layout) {
            let transfer = try transferMediaFile(
                from: sourceURL,
                to: destination,
                consumesSource: consumesSource,
                fileOperations: fileOperations
            )
            do {
                try JSONDocumentStore.write(
                    asset,
                    to: layout.mediaMetadata(meetingID, assetID: assetID)
                )
            } catch {
                try? rollbackMediaTransfer(
                    transfer,
                    sourceURL: sourceURL,
                    destination: destination,
                    fileOperations: fileOperations
                )
                throw error
            }
            if transfer == .copiedAndConsumesSource {
                try fileOperations.remove(sourceURL)
                try fileOperations.synchronizeDirectory(
                    sourceURL.deletingLastPathComponent()
                )
            }
        }
        return asset
    }

    private enum MediaFileTransfer: Equatable {
        case copiedSourcePreserved
        case copiedAndConsumesSource
        case renamed
    }

    private nonisolated func transferMediaFile(
        from sourceURL: URL,
        to destination: URL,
        consumesSource: Bool,
        fileOperations: MediaAssetFileOperations
    ) throws -> MediaFileTransfer {
        guard consumesSource else {
            try fileOperations.copy(sourceURL, destination)
            return .copiedSourcePreserved
        }

        do {
            try fileOperations.rename(sourceURL, destination)
            do {
                try fileOperations.synchronizeDirectory(
                    destination.deletingLastPathComponent()
                )
                if sourceURL.deletingLastPathComponent()
                    != destination.deletingLastPathComponent() {
                    try fileOperations.synchronizeDirectory(
                        sourceURL.deletingLastPathComponent()
                    )
                }
            } catch {
                let transferError = error
                do {
                    try fileOperations.rename(destination, sourceURL)
                } catch {
                    throw MediaAssetTransferRollbackError(
                        orphanedDestination: destination,
                        transferError: transferError,
                        rollbackError: error
                    )
                }
                do {
                    try fileOperations.synchronizeDirectory(
                        sourceURL.deletingLastPathComponent()
                    )
                    if sourceURL.deletingLastPathComponent()
                        != destination.deletingLastPathComponent() {
                        try fileOperations.synchronizeDirectory(
                            destination.deletingLastPathComponent()
                        )
                    }
                } catch {
                    throw MediaAssetTransferRollbackDurabilityError(
                        restoredSource: sourceURL,
                        formerDestination: destination,
                        transferError: transferError,
                        synchronizationError: error
                    )
                }
                throw transferError
            }
            return .renamed
        } catch let error as POSIXFailure where error.code == EXDEV {
            try fileOperations.copy(sourceURL, destination)
            do {
                try fileOperations.synchronizeFile(destination)
                try fileOperations.synchronizeDirectory(
                    destination.deletingLastPathComponent()
                )
            } catch {
                try? fileOperations.remove(destination)
                throw error
            }
            return .copiedAndConsumesSource
        }
    }

    private nonisolated func rollbackMediaTransfer(
        _ transfer: MediaFileTransfer,
        sourceURL: URL,
        destination: URL,
        fileOperations: MediaAssetFileOperations
    ) throws {
        switch transfer {
        case .copiedSourcePreserved, .copiedAndConsumesSource:
            try fileOperations.remove(destination)
            try fileOperations.synchronizeDirectory(
                destination.deletingLastPathComponent()
            )
        case .renamed:
            try fileOperations.rename(destination, sourceURL)
            try fileOperations.synchronizeDirectory(
                sourceURL.deletingLastPathComponent()
            )
            if sourceURL.deletingLastPathComponent()
                != destination.deletingLastPathComponent() {
                try fileOperations.synchronizeDirectory(
                    destination.deletingLastPathComponent()
                )
            }
        }
    }

    public func loadMediaAsset(
        _ assetID: MediaAssetID,
        meetingID: MeetingID
    ) throws -> MediaAsset {
        let url = layout.mediaMetadata(meetingID, assetID: assetID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LibraryError.mediaAssetNotFound(assetID, meetingID: meetingID)
        }
        return try JSONDocumentStore.read(
            MediaAsset.self,
            from: url,
            currentSchemaVersion: MediaAsset.currentSchemaVersion,
            schemaVersion: \.schemaVersion
        )
    }

    public func listMediaAssets(
        meetingID: MeetingID
    ) throws -> [MediaAsset] {
        try Self.listMediaAssets(meetingID: meetingID, layout: layout)
    }

    package nonisolated func listMediaAssets(
        meetingID: MeetingID,
        transaction: LibraryMutationTransaction
    ) throws -> [MediaAsset] {
        try transaction.validate(layout: layout)
        return try Self.listMediaAssets(meetingID: meetingID, layout: layout)
    }

    private nonisolated static func listMediaAssets(
        meetingID: MeetingID,
        layout: LibraryLayout
    ) throws -> [MediaAsset] {
        _ = try loadMeeting(meetingID, layout: layout)
        let documents = try FileManager.default.contentsOfDirectory(
            at: layout.mediaDirectory(meetingID),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return try documents
            .filter { $0.pathExtension == "json" }
            .map {
                try JSONDocumentStore.read(
                    MediaAsset.self,
                    from: $0,
                    currentSchemaVersion: MediaAsset.currentSchemaVersion,
                    schemaVersion: \.schemaVersion
                )
            }
            .sorted {
                if $0.kind == $1.kind { return $0.id < $1.id }
                return $0.kind.rawValue < $1.kind.rawValue
            }
    }

    private func createMeetingDirectories(_ meetingID: MeetingID) throws {
        for directory in [
            layout.meetingDirectory(meetingID),
            layout.mediaDirectory(meetingID),
            layout.runsDirectory(meetingID),
            layout.revisionsDirectory(meetingID),
            layout.notesDirectory(meetingID),
            layout.reportsDirectory(meetingID),
        ] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
    }

    private func findMediaAsset(provenanceKey: String) throws -> MediaAsset? {
        let meetings = try listMeetings()
        for meeting in meetings {
            let documents = try FileManager.default.contentsOfDirectory(
                at: layout.mediaDirectory(meeting.id),
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            for document in documents
            where document.pathExtension == "json" {
                let asset = try JSONDocumentStore.read(
                    MediaAsset.self,
                    from: document,
                    currentSchemaVersion: MediaAsset.currentSchemaVersion,
                    schemaVersion: \.schemaVersion
                )
                if asset.provenanceKey == provenanceKey { return asset }
            }
        }
        return nil
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
