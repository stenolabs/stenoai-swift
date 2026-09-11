import Foundation
import StenoDomain
import StenoExchange
import StenoPipeline

extension AppModel {
    func recoverMeetingTransferExportsAtStartup() {
        guard meetingTransferSharing.currentSession == nil else { return }
        do {
            let warnings = try meetingTransferSharing.recoverAbandonedExports(
                parentDirectory: meetingTransferTemporaryDirectory()
            )
            if let warning = warnings.first {
                report(verbatim: warning)
            }
        } catch {
            report(verbatim: error.localizedDescription)
        }
    }

    func meetingTransferPreview(_ meetingID: MeetingID) async throws
        -> MeetingTransferExportPreview
    {
        guard let runtime else {
            throw MeetingTransferExportCleanupError.runtimeUnavailable
        }
        return try await MeetingTransferExportService(
            library: runtime.library
        ).preview(meetingID: meetingID)
    }

    func prepareMeetingTransferExport(
        meetingID: MeetingID,
        selectedAudioAssetIDs: Set<MediaAssetID>
    ) async throws -> MeetingTransferSharingSession {
        guard let runtime else {
            throw MeetingTransferExportCleanupError.runtimeUnavailable
        }
        let selection = MeetingTransferExportSelection(
            meetingID: meetingID,
            selectedAudioAssetIDs: selectedAudioAssetIDs
        )
        let sourceAppVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String
        return try await meetingTransferSharing.prepareExport(
            parentDirectory: meetingTransferTemporaryDirectory(),
            selection: selection
        ) { root in
            try await MeetingTransferExportService(
                library: runtime.library
            ).export(
                meetingID: meetingID,
                selectedAudioAssetIDs: selectedAudioAssetIDs,
                temporaryRoot: root,
                sourceAppVersion: sourceAppVersion
            )
        }
    }

    func requestMeetingTransferImport() {
        guard runtime != nil else { return }
        wantsMeetingTransferImport = true
    }

    /// Cold-start document opens can arrive before `bootstrap()` has built the
    /// shared service. The queue is intentionally bounded to one item and uses
    /// latest-wins semantics, matching the single import sheet.
    func meetingTransferClientDidBecomeReady() {
        startPendingMeetingTransferIfPossible()
    }

    func previewMeetingPackage(at externalURL: URL) {
        pendingMeetingTransferURL = externalURL
        guard meetingTransferClient != nil else { return }

        switch meetingTransferImportState {
        case .preparing, .importing:
            requestMeetingTransferCancellation()
        case .preview:
            scheduleMeetingTransferDiscard(completeCommittedResult: false)
        case .failed:
            meetingTransferImportState = nil
            startPendingMeetingTransferIfPossible()
        case .cleanupRequired, .completed, .recoveryRequired:
            // The current durable outcome must be handled before a queued URL
            // may replace it.
            break
        case nil:
            startPendingMeetingTransferIfPossible()
        }
    }

    func importMeetingPackage(choice: MeetingTransferProcessingChoice) {
        guard let client = meetingTransferClient,
              meetingTransferOperation == nil,
              case .preview(let presentation) = meetingTransferImportState,
              ownedMeetingTransferSessionID == presentation.sessionID else {
            return
        }
        let operationID = UUID()
        meetingTransferOperationID = operationID
        meetingTransferCancellationRequested = false
        meetingTransferImportState = .importing(presentation, nil)

        meetingTransferOperation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { completeMeetingTransferOperation(operationID) }
            do {
                let result = try await client.importPrepared(
                    presentation.sessionID,
                    choice,
                    progressHandler(operationID: operationID)
                )
                guard meetingTransferOperationID == operationID else { return }
                ownedMeetingTransferSessionID = nil
                committedMeetingTransferResultAwaitingCleanup = nil
                if meetingTransferCancellationRequested {
                    switch result {
                    case .pendingRecovery(let meetingID):
                        meetingTransferImportState = .recoveryRequired(meetingID)
                    case .imported, .alreadyPresent:
                        meetingTransferImportState = .completed(result)
                    }
                } else {
                    await finishMeetingTransferImport(result)
                }
            } catch let error as MeetingTransferImportError {
                guard meetingTransferOperationID == operationID else { return }
                if case .cleanupRequired(let sessionID, let result) = error {
                    ownedMeetingTransferSessionID = sessionID
                    committedMeetingTransferResultAwaitingCleanup = result
                    showCleanupRequired(
                        sessionID: sessionID,
                        committedResult: result,
                        error: error
                    )
                    return
                }
                await finishFailedImport(
                    error,
                    presentation: presentation,
                    client: client,
                    operationID: operationID
                )
            } catch {
                await finishFailedImport(
                    error,
                    presentation: presentation,
                    client: client,
                    operationID: operationID
                )
            }
        }
    }

    func closeMeetingTransferImport() {
        switch meetingTransferImportState {
        case .preparing, .importing:
            requestMeetingTransferCancellation()
        case .preview:
            scheduleMeetingTransferDiscard(completeCommittedResult: false)
        case .cleanupRequired:
            scheduleMeetingTransferDiscard(completeCommittedResult: true)
        case .completed(let result):
            scheduleMeetingTransferCompletion(result)
        case .recoveryRequired, .failed:
            guard meetingTransferOperation == nil else { return }
            meetingTransferImportState = nil
            startPendingMeetingTransferIfPossible()
        case nil:
            startPendingMeetingTransferIfPossible()
        }
    }

    func retryMeetingTransferCleanup() {
        guard meetingTransferImportState?.cleanupSessionID != nil else { return }
        scheduleMeetingTransferDiscard(completeCommittedResult: true)
    }

    func openExistingMeetingFromTransferPreview() {
        guard case .preview(let presentation) = meetingTransferImportState,
              case .alreadyPresent(let meetingID) = presentation.disposition else {
            return
        }
        selectedMeetingID = meetingID
        closeMeetingTransferImport()
    }

    func loadMeetingTransferDetail(
        meetingID: MeetingID
    ) async -> MeetingTransferDetailPresentation? {
        guard let client = meetingTransferDetailClient else { return nil }
        do {
            return try await client.load(meetingID)
        } catch {
            report(verbatim: Self.message("The imported meeting status could not be read.", error))
            return nil
        }
    }

    @discardableResult
    func retryImportedMeetingProcessing(
        meetingID: MeetingID,
        localeIdentifier: String,
        modelsReady: Bool
    ) async -> Bool {
        guard let client = meetingTransferDetailClient else { return false }
        do {
            guard let detail = try await client.load(meetingID),
                  detail.hasAudio,
                  detail.processingStatus != .recoveryRequired,
                  let generationID = detail.receipt.importGenerationID else {
                return false
            }
            try await client.requestManualRetry(
                meetingID,
                generationID,
                localeIdentifier,
                modelsReady
            )
            return true
        } catch {
            report(verbatim: Self.message("Processing could not be requested.", error))
            return false
        }
    }

    private func scheduleMeetingTransferDiscard(completeCommittedResult: Bool) {
        guard meetingTransferOperation == nil,
              let client = meetingTransferClient else { return }
        let operationID = UUID()
        meetingTransferOperationID = operationID
        meetingTransferCancellationRequested = false
        let committedResult = committedMeetingTransferResultAwaitingCleanup
        meetingTransferOperation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { completeMeetingTransferOperation(operationID) }
            guard await discardOwnedMeetingTransferSession(
                using: client,
                operationID: operationID
            ) else { return }
            guard meetingTransferOperationID == operationID else { return }
            if completeCommittedResult, let committedResult {
                await finishMeetingTransferImport(committedResult)
            } else {
                meetingTransferImportState = nil
            }
        }
    }

    private func scheduleMeetingTransferCompletion(
        _ result: MeetingTransferImportResult
    ) {
        guard meetingTransferOperation == nil else { return }
        let operationID = UUID()
        meetingTransferOperationID = operationID
        meetingTransferCancellationRequested = false
        meetingTransferOperation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { completeMeetingTransferOperation(operationID) }
            await finishMeetingTransferImport(result)
        }
    }

    private func requestMeetingTransferCancellation() {
        meetingTransferCancellationRequested = true
        meetingTransferOperation?.cancel()
    }

    private func startPendingMeetingTransferIfPossible() {
        guard meetingTransferOperation == nil,
              meetingTransferImportState == nil,
              let client = meetingTransferClient,
              let externalURL = pendingMeetingTransferURL else { return }

        // Remove the only retained external URL before the asynchronous
        // preparation starts. The task captures it only until the private
        // snapshot call returns and security-scoped access is balanced.
        pendingMeetingTransferURL = nil
        let operationID = UUID()
        meetingTransferOperationID = operationID
        meetingTransferCancellationRequested = false
        meetingTransferImportState = .preparing(nil)
        let securityScope = meetingTransferSecurityScope

        meetingTransferOperation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { completeMeetingTransferOperation(operationID) }

            let accessing = securityScope.startAccessing(externalURL)
            let outcome: Result<MeetingTransferImportPresentation, Error>
            do {
                outcome = .success(try await client.prepareImport(
                    externalURL,
                    progressHandler(operationID: operationID)
                ))
            } catch {
                outcome = .failure(error)
            }
            if accessing { securityScope.stopAccessing(externalURL) }

            guard meetingTransferOperationID == operationID else { return }
            switch outcome {
            case .success(let presentation):
                ownedMeetingTransferSessionID = presentation.sessionID
                if meetingTransferCancellationRequested || Task.isCancelled {
                    guard await discardOwnedMeetingTransferSession(
                        using: client,
                        operationID: operationID,
                        fallbackSessionID: presentation.sessionID
                    ) else { return }
                    meetingTransferImportState = nil
                } else {
                    meetingTransferImportState = .preview(presentation)
                }
            case .failure(let error as MeetingTransferImportError):
                if case .preparationCleanupRequired(let sessionID) = error {
                    ownedMeetingTransferSessionID = sessionID
                    showCleanupRequired(
                        sessionID: sessionID,
                        committedResult: nil,
                        error: error
                    )
                } else if meetingTransferCancellationRequested {
                    meetingTransferImportState = nil
                } else {
                    meetingTransferImportState = .failed(
                        Self.message("The meeting package could not be prepared.", error)
                    )
                }
            case .failure(let error):
                if meetingTransferCancellationRequested || error is CancellationError {
                    meetingTransferImportState = nil
                } else {
                    meetingTransferImportState = .failed(
                        Self.message("The meeting package could not be prepared.", error)
                    )
                }
            }
        }
    }

    private func completeMeetingTransferOperation(_ operationID: UUID) {
        guard meetingTransferOperationID == operationID else { return }
        meetingTransferOperation = nil
        meetingTransferCancellationRequested = false
        if meetingTransferImportState == nil {
            startPendingMeetingTransferIfPossible()
        }
    }

    private func finishFailedImport(
        _ error: Error,
        presentation: MeetingTransferImportPresentation,
        client: MeetingTransferImportClient,
        operationID: UUID
    ) async {
        let wasCancelled = error is CancellationError
        guard await discardOwnedMeetingTransferSession(
            using: client,
            operationID: operationID,
            fallbackSessionID: presentation.sessionID,
            failureMessage: Self.message("The import failed and cleanup must be retried.", error)
        ) else { return }
        guard meetingTransferOperationID == operationID else { return }
        meetingTransferImportState = wasCancelled
            ? nil
            : .failed(Self.message("The meeting package could not be imported.", error))
    }

    private func discardOwnedMeetingTransferSession(
        using client: MeetingTransferImportClient,
        operationID: UUID,
        fallbackSessionID: UUID? = nil,
        failureMessage: String = "The private import copy could not be removed. Try cleanup again."
    ) async -> Bool {
        guard meetingTransferOperationID == operationID else { return false }
        guard let sessionID = ownedMeetingTransferSessionID ?? fallbackSessionID else {
            committedMeetingTransferResultAwaitingCleanup = nil
            return true
        }
        do {
            try await client.discardPrepared(sessionID)
        } catch MeetingTransferImportError.sessionNotFound(let missing)
            where missing == sessionID {
            // A completed service operation already removed its own session.
        } catch {
            ownedMeetingTransferSessionID = sessionID
            guard meetingTransferOperationID == operationID else { return false }
            showCleanupRequired(
                sessionID: sessionID,
                committedResult: committedMeetingTransferResultAwaitingCleanup,
                message: failureMessage
            )
            return false
        }
        guard meetingTransferOperationID == operationID else { return false }
        ownedMeetingTransferSessionID = nil
        committedMeetingTransferResultAwaitingCleanup = nil
        return true
    }

    private func finishMeetingTransferImport(
        _ result: MeetingTransferImportResult
    ) async {
        switch result {
        case .imported(let meetingID):
            selectedMeetingID = meetingID
            meetingTransferImportState = nil
            report(
                "Meeting imported. The received unencrypted file may still remain in Downloads and can be included in search indexing or backups.",
                isError: false
            )
            await refreshMeetings()
        case .alreadyPresent(let meetingID):
            selectedMeetingID = meetingID
            meetingTransferImportState = nil
            report("This meeting was already present. Nothing was changed.", isError: false)
            await refreshMeetings()
        case .pendingRecovery(let meetingID):
            meetingTransferImportState = .recoveryRequired(meetingID)
        }
    }

    private func progressHandler(
        operationID: UUID
    ) -> MeetingTransferImportClient.Progress {
        { [weak self] progress in
            Task { @MainActor in
                guard let self,
                      self.meetingTransferOperationID == operationID else { return }
                switch self.meetingTransferImportState {
                case .preparing:
                    self.meetingTransferImportState = .preparing(progress)
                case .importing(let presentation, _):
                    self.meetingTransferImportState = .importing(presentation, progress)
                case .preview, .cleanupRequired, .completed, .recoveryRequired, .failed, nil:
                    break
                }
            }
        }
    }

    private func showCleanupRequired(
        sessionID: UUID,
        committedResult: MeetingTransferImportResult?,
        error: Error
    ) {
        showCleanupRequired(
            sessionID: sessionID,
            committedResult: committedResult,
            message: Self.message("The private import copy could not be removed.", error)
        )
    }

    private func showCleanupRequired(
        sessionID: UUID,
        committedResult: MeetingTransferImportResult?,
        message: String
    ) {
        meetingTransferImportState = .cleanupRequired(
            sessionID: sessionID,
            committedResult: committedResult,
            message: message
        )
    }
}
