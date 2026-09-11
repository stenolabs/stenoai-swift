import AVFAudio
import AVFoundation
import Foundation
import os
import Observation
import Speech
import StenoDomain
import StenoDemo
import StenoExchange
import StenoLibrary
import StenoAudioCore
import StenoMacAudio
import StenoPipeline
import StenoTranscription

struct RecordingLiveTaskSet {
    typealias LiveTask = Task<TranscriptOutput?, Never>

    private var tasks: [LiveTask] = []

    var isEmpty: Bool { tasks.isEmpty }

    mutating func append(_ task: LiveTask) {
        tasks.append(task)
    }

    mutating func takeForStop() -> [LiveTask] {
        let currentTasks = tasks
        tasks = []
        return currentTasks
    }

    mutating func cancelAndDiscard() {
        for task in tasks {
            task.cancel()
        }
        tasks = []
    }
}

struct RecordingStopFollowUp: Equatable {
    let meetingStatusCorrection: Meeting.Status?
    let jobKinds: [Job.Kind]

    static func make(stopFailed: Bool) -> RecordingStopFollowUp {
        RecordingStopFollowUp(
            meetingStatusCorrection: stopFailed ? .interrupted : nil,
            jobKinds: [.finalASR]
        )
    }
}

private struct MicrophoneDiscoveryLoad: Sendable {
    let snapshot: MicrophoneDiscoverySnapshot
    let errorDescription: String?
}

enum AudioExportProgressStream {
    static func make() -> (
        updates: AsyncStream<StereoM4AExportProgress>,
        continuation: AsyncStream<StereoM4AExportProgress>.Continuation
    ) {
        let pair = AsyncStream.makeStream(
            of: StereoM4AExportProgress.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        return (updates: pair.stream, continuation: pair.continuation)
    }
}

struct DemoDataPublicationContext {
    let library: Library
    let folders: FolderStore
    let token: DemoDataPresentationState.StatusToken

    func isCurrent(
        library: Library?,
        folders: FolderStore?,
        token: DemoDataPresentationState.StatusToken
    ) -> Bool {
        library === self.library
            && folders === self.folders
            && token == self.token
    }
}

@MainActor
@Observable
final class AppModel {
    typealias StereoAudioExportPerformer = @MainActor (
        URL,
        URL,
        URL,
        @escaping @MainActor @Sendable (StereoM4AExportProgress) -> Void
    ) async throws -> Void
    typealias MeetingTrasher = @MainActor (
        Library,
        MeetingID
    ) async throws -> URL?
    private static let baselineModelBundleIDs: Set<ModelBundleID> = [
        .appleSpeech,
        .speakerSeparation,
    ]

    private(set) var runtime: PipelineRuntime?
    private(set) var folderStore: FolderStore?
    private(set) var startupState = MacStartupState.opening
    private(set) var startupWarnings: [MacStartupWarning] = []
    private(set) var libraryIssues: [MacLibraryIssue] = []
    private(set) var retryingLibraryIssueIDs: Set<MacLibraryIssue.ID> = []
    private(set) var recoveredMeetingIDs: [MeetingID] = []
    private(set) var isBootstrappingPipeline = false
    private(set) var isSwitchingTranscriptionLanguage = false
    private(set) var isMovingMeetingsToTrash = false

    // Der Dialog besitzt niemals die externe Dokument-URL. Sie lebt nur auf
    // dem Stack des vorbereitenden Tasks, bis StenoKit den privaten Snapshot
    // erzeugt hat. Danach bleiben hier ausschließlich Preview und Session-ID.
    var meetingTransferImportState: MeetingTransferImportFlowState?
    var wantsMeetingTransferImport = false
    @ObservationIgnored
    var meetingTransferClient: MeetingTransferImportClient? {
        didSet {
            if meetingTransferClient != nil {
                meetingTransferClientDidBecomeReady()
            }
        }
    }
    @ObservationIgnored
    var meetingTransferDetailClient: MeetingTransferDetailClient?
    @ObservationIgnored
    private let meetingTransferImportClientWasInjected: Bool
    @ObservationIgnored
    private let meetingTransferDetailClientWasInjected: Bool
    @ObservationIgnored
    var meetingTransferSecurityScope: MeetingTransferSecurityScopedResource
    @ObservationIgnored
    var meetingTransferOperation: Task<Void, Never>?
    @ObservationIgnored
    var meetingTransferOperationID = UUID()
    @ObservationIgnored
    var pendingMeetingTransferURL: URL?
    @ObservationIgnored
    var meetingTransferCancellationRequested = false
    @ObservationIgnored
    var ownedMeetingTransferSessionID: UUID?
    @ObservationIgnored
    var committedMeetingTransferResultAwaitingCleanup: MeetingTransferImportResult?
    @ObservationIgnored
    let meetingTransferSharing: MeetingTransferSharing
    @ObservationIgnored
    let meetingTransferTemporaryDirectory: @Sendable () -> URL
    @ObservationIgnored
    let stereoAudioExportPerformer: StereoAudioExportPerformer
    @ObservationIgnored
    let meetingTrasher: MeetingTrasher
    @ObservationIgnored
    private let languagePreferences: TranscriptionLanguagePreferences
    @ObservationIgnored
    private let recordingPermissionClient: MacRecordingPermissionClient
    @ObservationIgnored
    private let recordingPermissionDefaults: UserDefaults
    @ObservationIgnored
    private let recordingPermissionIdentity: @MainActor () -> String?
    @ObservationIgnored
    private let nativeGemmaRecordingBarrier: any NativeGemmaCoordinator
    @ObservationIgnored
    private var nativeGemmaRecordingBarrierIsHeld = false
    @ObservationIgnored
    private let pipelineStarter: MacPipelineStarter
    @ObservationIgnored
    private let libraryURLOverride: URL?
    @ObservationIgnored
    private let modelCacheDirectoryOverride: URL?
    @ObservationIgnored
    private let supportedLocalesLoader: MacSupportedLocalesLoader
    @ObservationIgnored
    private let meetingListLoader: MacMeetingListLoader
    @ObservationIgnored
    private let folderListLoader: MacFolderListLoader
    @ObservationIgnored
    private var runtimeGeneration: UInt64 = 0
    @ObservationIgnored
    private var meetingRefreshGeneration: UInt64 = 0
    @ObservationIgnored
    private var folderRefreshGeneration: UInt64 = 0
    @ObservationIgnored
    private var libraryIssueRetryCounters: [MacLibraryIssue.ID: UInt64] = [:]
    @ObservationIgnored
    private var activeLibraryIssueRetryGenerations: [MacLibraryIssue.ID: UInt64] = [:]

    let transcriptionModels: TranscriptionModelSettings
    private let injectedTranscriptionRegistry: TranscriptionProviderRegistry?

    /// Wird bei jedem Zugriff aus der aktuellen Wahl gebaut, damit ein
    /// umgelegter Schalter sofort wirkt. Die Registry haelt nur Fabriken,
    /// keine geladenen Modelle - das ist billig. Beim Aufnahmestart wird sie
    /// einmal gezogen und gilt dann fuer den ganzen Lauf.
    var transcriptionRegistry: TranscriptionProviderRegistry {
        injectedTranscriptionRegistry ?? .standard(
            modelDirectory: resolvedModelCacheDirectory,
            experimentalFeatures: transcriptionModels.experimentalFeatures
        )
    }
    let transcriptionCatalog: TranscriptionModelCatalog

    init(
        meetingTransferClient: MeetingTransferImportClient? = nil,
        meetingTransferDetailClient: MeetingTransferDetailClient? = nil,
        meetingTransferSecurityScope: MeetingTransferSecurityScopedResource = .live,
        meetingTransferSharing: MeetingTransferSharing = .shared,
        meetingTransferTemporaryDirectory: @escaping @Sendable () -> URL = {
            FileManager.default.temporaryDirectory
        },
        stereoAudioExportPerformer: StereoAudioExportPerformer? = nil,
        meetingTrasher: @escaping MeetingTrasher = { library, meetingID in
            try library.trashMeeting(meetingID)
        },
        languagePreferences: TranscriptionLanguagePreferences = .init(),
        transcriptionModels: TranscriptionModelSettings = TranscriptionModelSettings(),
        transcriptionRegistry: TranscriptionProviderRegistry? = nil,
        transcriptionCatalog: TranscriptionModelCatalog = .standard,
        modelCoordinator: ModelInstallationCoordinator? = nil,
        recordingPermissionClient: MacRecordingPermissionClient = .live,
        recordingPermissionDefaults: UserDefaults = .standard,
        recordingPermissionIdentity: @escaping @MainActor () -> String? = {
            CurrentCodeSigningIdentity.cacheKey()
        },
        nativeGemmaRecordingBarrier: any NativeGemmaCoordinator =
            NativeGemmaRecordingBarrierFactory.live(),
        pipelineStarter: @escaping MacPipelineStarter = { request in
            try await startPipeline(
                at: request.libraryURL,
                transcriptionProviderResolver: request.transcriptionProviderResolver,
                modelCacheDirectory: request.modelCacheDirectory,
                textModelProviderResolver: request.textModelProviderResolver,
                locale: request.locale,
                activeMeetingIDs: request.activeMeetingIDs
            )
        },
        supportedLocalesLoader: @escaping MacSupportedLocalesLoader = {
            await SpeechTranscriber.supportedLocales
        },
        meetingListLoader: @escaping MacMeetingListLoader = { library in
            try await library.listMeetings()
        },
        folderListLoader: @escaping MacFolderListLoader = { store in
            try await store.listFolders()
        },
        libraryURL: URL? = nil,
        modelCacheDirectoryOverride: URL? = nil
    ) {
        self.transcriptionModels = transcriptionModels
        injectedTranscriptionRegistry = transcriptionRegistry
        self.transcriptionCatalog = transcriptionCatalog
        self.modelCoordinator = modelCoordinator
        self.libraryURLOverride = libraryURL?.standardizedFileURL
        self.modelCacheDirectoryOverride = modelCacheDirectoryOverride?.standardizedFileURL
        self.meetingTransferClient = meetingTransferClient
        self.meetingTransferDetailClient = meetingTransferDetailClient
        meetingTransferImportClientWasInjected = meetingTransferClient != nil
        meetingTransferDetailClientWasInjected = meetingTransferDetailClient != nil
        self.meetingTransferSecurityScope = meetingTransferSecurityScope
        self.meetingTransferSharing = meetingTransferSharing
        self.meetingTransferTemporaryDirectory = meetingTransferTemporaryDirectory
        self.meetingTrasher = meetingTrasher
        self.languagePreferences = languagePreferences
        self.recordingPermissionClient = recordingPermissionClient
        self.recordingPermissionDefaults = recordingPermissionDefaults
        self.recordingPermissionIdentity = recordingPermissionIdentity
        self.nativeGemmaRecordingBarrier = nativeGemmaRecordingBarrier
        self.pipelineStarter = pipelineStarter
        self.supportedLocalesLoader = supportedLocalesLoader
        self.meetingListLoader = meetingListLoader
        self.folderListLoader = folderListLoader
        selectedLanguageID = languagePreferences.selectedIdentifier
        languageWasChosenExplicitly = languagePreferences.wasChosenExplicitly
        self.stereoAudioExportPerformer = stereoAudioExportPerformer ?? {
            microphoneURL, systemURL, destinationURL, progress in
            let (updates, continuation) = AudioExportProgressStream.make()
            let worker = Task.detached {
                defer { continuation.finish() }
                try StereoM4AExporter().export(
                    microphoneURL: microphoneURL,
                    systemURL: systemURL,
                    destinationURL: destinationURL
                ) { continuation.yield($0) }
            }
            try await withTaskCancellationHandler {
                for await update in updates {
                    progress(update)
                }
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
        }
        recoverMeetingTransferExportsAtStartup()
    }

    private(set) var meetings: [Meeting] = []
    private(set) var folders: [Folder] = []
    private(set) var meetingsWithAudio: Set<MeetingID> = []
    private static let meetingSelectionDefaultsKey = "steno.selection.meeting"
    // Die Liste besitzt genau einen Auswahlzustand. Ein berechneter
    // Einzelelementzugriff haelt bestehende Detail- und Aufnahmewege kompatibel.
    var selectedMeetingIDs: Set<MeetingID> = [] {
        didSet { persistSingleMeetingSelection() }
    }
    var selectedMeetingID: MeetingID? {
        get {
            MeetingSidebarSelectionPolicy.singleID(in: selectedMeetingIDs)
        }
        set {
            selectedMeetingIDs = newValue.map { Set([$0]) } ?? []
        }
    }

    /// Prüft, ob mindestens eine Originalspur des Meetings tatsächlich
    /// abspielbar ist. Die blosse Existenz der Datei genügt nicht: Alt-Importe
    /// bringen WebM/Opus mit, das macOS nicht öffnen kann - Hörproben und
    /// Diarisierung wären dann tote Knöpfe.
    func hasPlayableAudio(_ meetingID: MeetingID) async -> Bool {
        guard let runtime else { return false }
        return await hasPlayableAudio(meetingID, in: runtime)
    }

    private func hasPlayableAudio(
        _ meetingID: MeetingID,
        in runtime: PipelineRuntime
    ) async -> Bool {
        let layout = await runtime.library.layout
        let assets = (try? await runtime.library.listMediaAssets(
            meetingID: meetingID
        )) ?? []
        for asset in assets {
            let url = layout.mediaFile(meetingID, fileName: asset.fileName)
            if await AudioAssetReadability.isReadable(url) {
                return true
            }
        }
        return false
    }

    /// Aktualisiert die Audio-Verfügbarkeit eines einzelnen Meetings, damit
    /// die Detailansicht nach Jobs oder Löschungen nicht auf einem veralteten
    /// Ja sitzenbleibt und tote Knöpfe anbietet.
    func refreshAudioAvailability(_ meetingID: MeetingID) async {
        guard let runtime else { return }
        let expectedRuntimeGeneration = runtimeGeneration
        let isPlayable = await hasPlayableAudio(meetingID, in: runtime)
        guard runtimeIsCurrent(
            runtime,
            generation: expectedRuntimeGeneration
        ) else { return }
        if isPlayable {
            meetingsWithAudio.insert(meetingID)
        } else {
            meetingsWithAudio.remove(meetingID)
        }
    }

    func restoreSelection(from meetings: [Meeting]) {
        guard selectedMeetingIDs.isEmpty,
              let raw = UserDefaults.standard.string(
                  forKey: Self.meetingSelectionDefaultsKey
              ),
              let uuid = UUID(uuidString: raw)
        else { return }
        let restored = MeetingID(rawValue: uuid)
        if meetings.contains(where: { $0.id == restored }) {
            selectedMeetingIDs = Set([restored])
        }
    }

    private func persistSingleMeetingSelection() {
        if let meetingID = MeetingSidebarSelectionPolicy.singleID(
            in: selectedMeetingIDs
        ) {
            UserDefaults.standard.set(
                meetingID.description,
                forKey: Self.meetingSelectionDefaultsKey
            )
        } else if selectedMeetingIDs.isEmpty {
            UserDefaults.standard.removeObject(
                forKey: Self.meetingSelectionDefaultsKey
            )
        }
    }

    // Aufnahmezustand
    private(set) var isRecording = false
    private(set) var recordingMeetingID: MeetingID?
    private(set) var recordingStartedAt: Date?
    /// One-shot report template choice for the recording dock. Nil pin =
    /// global default flow, identical to before the pinning feature.
    @ObservationIgnored
    private(set) var recordingTemplateChoice = RecordingTemplateChoice()
    var recordingPinnedTemplateID: String? {
        recordingTemplateChoice.pinnedTemplateID
    }
    var recordingContinuesExistingMeeting: Bool {
        recordingTemplateChoice.continuesExistingMeeting
    }
    private var liveTranscriptFeed = LiveTranscriptFeed()
    private(set) var liveTranscriptRows: [LiveTranscriptFeed.Row] = []
    private(set) var levels: [AudioTrack: AudioLevels] = [:]
    private(set) var microphoneStatus: RecordingTrackStatus?
    private(set) var recordingPermissions = RecordingAudioPermissionState()
    private(set) var isResolvingRecordingPermissions = false
    static let systemAudioPermissionDefaultsKey =
        "steno.permissions.systemAudio.lastStatus"
    static let systemAudioPermissionIdentityDefaultsKey =
        "steno.permissions.systemAudio.codeIdentity"
    private static let legacyProtectedMicrophoneUIDDefaultsKey =
        "steno.permissions.microphone.beforeSystemAudioProbe"
    @ObservationIgnored
    var notesSessions: [MeetingID: MeetingNotesEditingSession] = [:]
    /// Eine Meldung, die den Benutzer sicher erreicht, egal welche Ansicht
    /// gerade offen ist. Vorher hingen Aufnahme- und Importfehler an einer
    /// Eigenschaft, die nur die Aufnahmeansicht rendert - und die existiert
    /// genau dann nicht, wenn eine Aufnahme gar nicht erst startet.
    private(set) var notice: Notice?
    var audioExportActivity: AudioExportActivity?
    private var noticeDismissTask: Task<Void, Never>?
    var reviewError: String?
    /// Eigene Meldung fuer die Einstellungen: `notice` haengt am Hauptfenster
    /// und waere im Einstellungsfenster unsichtbar.
    var peopleError: String?
    private(set) var demoDataPresentationState = DemoDataPresentationState()
    private(set) var isManagingDemoData = false
    @ObservationIgnored
    private var demoDataStatusRefreshTask: Task<Void, Never>?

    var demoDataStatus: DemoLibraryStatus? {
        demoDataPresentationState.status
    }

    var isCheckingDemoDataStatus: Bool {
        demoDataPresentationState.isChecking
    }

    var demoDataStatusError: String? {
        demoDataPresentationState.statusError
    }

    var demoDataError: String? {
        demoDataPresentationState.lifecycleError
    }

    var demoDataLastResult: DemoLifecycleResult? {
        demoDataPresentationState.lifecycleResult
    }

    struct Notice: Equatable, Identifiable {
        let id = UUID()
        let text: String
        let isError: Bool
    }

    struct StartupNoticePresentation: Equatable {
        let text: String
        let isError: Bool
        let autoDismiss: Bool
    }

    /// Fehler bleiben stehen, bis der Benutzer sie bestaetigt - eine
    /// Bestaetigung nicht: Sie hat ihre Arbeit getan, sobald sie gelesen ist,
    /// und stuende sonst noch da, wenn man laengst woanders arbeitet.
    func report(
        _ text: String,
        isError: Bool = true,
        autoDismiss: Bool? = nil
    ) {
        let notice = Notice(text: text, isError: isError)
        self.notice = notice
        noticeDismissTask?.cancel()
        guard autoDismiss ?? !isError else { return }
        noticeDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            // Nur wegraeumen, wenn inzwischen keine neue Meldung kam.
            if self?.notice == notice { self?.notice = nil }
        }
    }


    func dismissNotice() {
        noticeDismissTask?.cancel()
        notice = nil
    }

    /// Der Dateiwaehler haengt am Fenster, das Menue liegt darueber. Das Flag
    /// ist die Bruecke; ContentView bindet den fileImporter daran.
    var wantsAudioImport = false

    func requestAudioImport() {
        guard !isRecording else { return }
        wantsAudioImport = true
    }

    // MARK: - Shell UX: command palette and undo-delete toast

    /// The Cmd-K menu command flips this; the palette itself renders as a
    /// ContentView overlay while it is set.
    var isCommandPalettePresented = false

    /// Focused-window command contexts, snapshotted when the Cmd-K menu
    /// command fires. The palette's search field owns keyboard focus while
    /// it is open, so @FocusedValue would resolve to nil inside the
    /// overlay - the contexts must be captured before it appears.
    @ObservationIgnored
    var commandPaletteContexts: CommandPaletteContexts?

    private(set) var pendingTrashUndo: UndoDeleteToastWindow?

    @ObservationIgnored private var trashUndoTargets: [UUID: NSObject] = [:]
    @ObservationIgnored private var availableTrashUndos: [UUID: UndoDeleteToastWindow] = [:]
    @ObservationIgnored private weak var trashUndoManager: UndoManager?

    /// Register with the window's native undo stack so text editing retains
    /// its normal responder-chain behavior. Undo outlives the visible toast.
    func registerTrashUndo(with manager: UndoManager?) {
        guard let manager, let window = pendingTrashUndo,
              trashUndoTargets[window.id] == nil else { return }
        let target = NSObject()
        trashUndoTargets[window.id] = target
        trashUndoManager = manager
        manager.registerUndo(withTarget: target) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.restoreTrashedMeetings(window: window)
            }
        }
        manager.setActionName(String(localized: "Move to Trash"))
    }

    /// Opens (or restarts) the 12-second undo window after one confirmed trash
    /// operation. A later operation replaces the toast, but earlier batches
    /// remain in the native undo stack.
    func beginTrashUndoWindow(
        items: [UndoDeleteToastItem],
        now: Date = Date()
    ) {
        guard let window = UndoDeleteToastPolicy.begin(
            previous: pendingTrashUndo,
            items: items,
            now: now
        ) else { return }
        availableTrashUndos[window.id] = window
        pendingTrashUndo = window
    }

    /// Drops the pending toast once its window has elapsed. The toast view
    /// calls this from its expiry task; safe to call at any time.
    func expireTrashUndoIfElapsed(now: Date = Date()) {
        pendingTrashUndo = UndoDeleteToastPolicy.resolved(
            pendingTrashUndo,
            now: now
        )
    }

    /// Undoes the latest trash operation. Every recoverable folder in the
    /// captured batch moves back under the library's exclusive mutation lock.
    func restoreTrashedMeetings(window capturedWindow: UndoDeleteToastWindow? = nil) async {
        guard let window = capturedWindow ?? pendingTrashUndo,
              availableTrashUndos.removeValue(forKey: window.id) != nil else { return }
        if let target = trashUndoTargets.removeValue(forKey: window.id) {
            trashUndoManager?.removeAllActions(withTarget: target)
        }
        if pendingTrashUndo?.id == window.id { pendingTrashUndo = nil }
        guard let runtime else {
            beginTrashUndoWindow(items: window.items)
            registerTrashUndo(with: trashUndoManager)
            report(window.items.count == 1
                ? "The meeting could not be restored."
                : "The meetings could not be restored.")
            return
        }

        var restored: [UndoDeleteToastItem] = []
        var failed: [UndoDeleteToastItem] = []
        var destinationWasOccupied = false
        var lastError: Error?

        for item in window.items {
            guard let trashedURL = item.trashedURL else {
                failed.append(item)
                continue
            }
            let layout = runtime.library.layout
            let destination = layout.meetingDirectory(item.meetingID)
            do {
                try LibraryMutationCoordination.withExclusiveAccess(layout: layout) {
                    guard !FileManager.default.fileExists(atPath: destination.path) else {
                        throw CocoaError(.fileWriteFileExists)
                    }
                    try FileManager.default.moveItem(at: trashedURL, to: destination)
                }
                restored.append(item)
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                destinationWasOccupied = true
                lastError = error
                failed.append(item)
            } catch {
                lastError = error
                failed.append(item)
            }
        }

        // Keep only failed restore handles available for retry. Consumed
        // handles cannot run twice, even when menu and toast race.
        let retryable = failed.filter { $0.trashedURL != nil }
        if !retryable.isEmpty {
            beginTrashUndoWindow(items: retryable)
            registerTrashUndo(with: trashUndoManager)
        }
        if !restored.isEmpty {
            await refreshMeetings()
        }

        if window.items.count == 1, let item = window.items.first {
            if failed.isEmpty {
                selectedMeetingID = item.meetingID
                report("\(item.title) was restored.", isError: false)
            } else if item.trashedURL == nil {
                report("\(item.title) was moved to the Trash. Restore it manually from the Finder.")
            } else if destinationWasOccupied {
                report("A folder already occupies the original location. \(item.title) is still in the Trash.")
            } else if let lastError {
                report(AppModel.message("The meeting could not be restored.", lastError))
            } else {
                report("The meeting could not be restored.")
            }
        } else if failed.isEmpty {
            report("\(restored.count) meetings were restored.", isError: false)
        } else if restored.isEmpty {
            report("The meetings could not be restored automatically. They are still in the Trash.")
        } else {
            report(
                "\(restored.count) meetings were restored. \(failed.count) remain in the Trash."
            )
        }
    }

    /// Rohe Swift-Fehlerbeschreibungen gehören nicht in die Oberfläche.
    /// Der Klartext sagt, was nicht ging; das technische Detail hängt hinten
    /// dran, damit ein Fehlerbericht noch etwas hergibt.
    static func message(_ summary: String, _ error: Error) -> String {
        "\(summary) (\(error.localizedDescription))"
    }

    nonisolated static func pipelineStartupWarningMessage(
        for warnings: [PipelineStartupWarning],
        locale: Locale = .current
    ) -> String? {
        guard !warnings.isEmpty else { return nil }
        let orphanedMediaCount = warnings.reduce(into: 0) { count, warning in
            if case .orphanedMedia = warning { count += 1 }
        }
        let importedMeetingCount = warnings.count - orphanedMediaCount
        var messages: [String] = []
        if orphanedMediaCount == 1 {
            messages.append(localized("Steno found an original recording file that could not be safely registered. The file remains stored and needs attention.", locale: locale))
        } else if orphanedMediaCount > 1 {
            messages.append(localized("Steno found \(orphanedMediaCount) original recording files that could not be safely registered. The files remain stored and need attention.", locale: locale))
        }
        if importedMeetingCount == 1 {
            messages.append(localized("One imported meeting needs attention because its processing could not be resumed. Other meetings and recording remain available.", locale: locale))
        } else if importedMeetingCount > 1 {
            messages.append(localized("\(importedMeetingCount) imported meetings need attention because their processing could not be resumed. Other meetings and recording remain available.", locale: locale))
        }
        return messages.joined(separator: " ")
    }

    nonisolated static func startupNoticePresentation(
        for warnings: [PipelineStartupWarning],
        captureRecoveryFailure: String?,
        locale: Locale = .current
    ) -> StartupNoticePresentation? {
        let pipelineWarning = pipelineStartupWarningMessage(
            for: warnings,
            locale: locale
        )
        let messages = [pipelineWarning, captureRecoveryFailure].compactMap { $0 }
        guard !messages.isEmpty else { return nil }
        let containsOrphan = warnings.contains { warning in
            if case .orphanedMedia = warning { return true }
            return false
        }
        return StartupNoticePresentation(
            text: messages.joined(separator: " "),
            isError: captureRecoveryFailure != nil,
            autoDismiss: captureRecoveryFailure == nil && !containsOrphan
        )
    }

    private nonisolated static func localized(
        _ resource: LocalizedStringResource,
        locale: Locale
    ) -> String {
        var resource = resource
        resource.locale = locale
        return String(localized: resource)
    }

    nonisolated static func captureRecoveryFailureMessage(
        _ failures: [CaptureRecovery.Failure]
    ) -> String? {
        guard let first = failures.first else { return nil }
        let meetingCount = Set(failures.map(\.meetingID)).count
        if meetingCount == 1 {
            return String(localized: "Steno could not finish recovering one interrupted meeting. All recording files remain stored. First error: \(first.error.localizedDescription)")
        }
        return String(localized: "Steno could not finish recovering \(meetingCount) interrupted meetings. All recording files remain stored. First error: \(first.error.localizedDescription)")
    }

    // Hörproben-Wiedergabe im Sprecher-Review
    private(set) var playingSampleID: Double?
    /// Dieselbe Wiedergabe, angestossen aus der Personenverwaltung. Zwei
    /// Kennungen, aber nur ein Abspieler: was hier laeuft, stoppt dort.
    private(set) var playingPersonSampleID: SpeakerEvidenceID?
    // Hoerproben werden als herausgeschnittene Kopie abgespielt: AVAudioPlayer
    // kann in Opus-in-CAF nicht springen (gemessen: stille Passage klang wie
    // eine laute), und AVAudioEngine fasst auf macOS die Eingangsseite an und
    // loest eine Mikrofon-Abfrage aus. Der Ausschnitt wird deshalb ueber
    // AVAudioFile framegenau gelesen und als Temp-Datei ab Position 0 gespielt.
    var samplePlayer: AVAudioPlayer?
    var samplePlaybackTask: Task<Void, Never>?
    var sampleClipURL: URL?

    func setPlayingSample(_ id: Double?) { playingSampleID = id }
    func setPlayingPersonSample(_ id: SpeakerEvidenceID?) {
        playingPersonSampleID = id
    }

    private var session: RecordingSession?
    private var liveTasks = RecordingLiveTaskSet()
    private var levelTask: Task<Void, Never>?
    private var recordingStopTask: Task<Void, Never>?
    /// App-level logger for degraded-but-nonfatal library conveniences.
    private static let searchIndexLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.steno",
        category: "library"
    )

    private var meetingChangesTask: Task<Void, Never>?
    private var searchIndexRebuildTask: Task<Void, Never>?
    /// Derived full-text index; rebuildable at any time (ARCHITECTURE s11).
    @ObservationIgnored
    private var searchIndex: MeetingSearchIndex?
    private var recordingStartState = RecordingStartState()
    /// Sprache, mit der die Live-Lanes aktuell transkribieren. Weicht nur
    /// dann vom Aufnahme-Startwert ab, wenn die automatische Erkennung
    /// entschieden hat und die Lanes genau einmal neu gestartet wurden (F8).
    private var activeLiveLaneLocale: Locale?
    /// Hysterese-Zustand der automatischen Spracherkennung waehrend einer
    /// Aufnahme; nil bei expliziter Sprachwahl.
    private var languageDetectionSession: LanguageDetectionSession?
    private var hasRestartedLiveLanesForDetectedLanguage = false
    private var recordingLanguageStartLocaleIdentifier: String?
    private(set) var recordingDetectedLocaleIdentifier: String?
    /// F11: locale identifier of the LAST language decision for the current
    /// recording - either a decisive automatic detection or a mid-recording
    /// manual pick. The stop path reads it to pin the final ASR job's
    /// locale; pre-switch text was recognized in its original language and
    /// stays as the live transcript captured it (Transcribe Again re-runs).
    private var recordingLastSelectedLocaleIdentifier: String?
    /// F11: locale identifier of a mid-recording MANUAL pick, if any. It
    /// outranks every detection result for the rest of the recording.
    private(set) var recordingManualLocaleIdentifier: String?
    // Platform integration state; lifecycle logic lives in
    // AppModel+PlatformIntegration.swift. Extensions cannot add stored
    // properties, so the instances are kept here (untracked: no view
    // renders them).
    @ObservationIgnored
    var menuBarController: MenuBarController?
    @ObservationIgnored
    var globalRecordHotkey: GlobalRecordHotkey?
    @ObservationIgnored
    var microphoneActivityMonitor: MicrophoneActivityMonitor?
    @ObservationIgnored
    var meetingDetectionController: MeetingDetectionController?

    var isStartingRecording: Bool { recordingStartState.isStarting }

    var canStartRecording: Bool {
        runtime != nil
            && startupState == .ready
            && !isBootstrappingPipeline
            && !isRecording
            && !isStartingRecording
            && !isMovingMeetingsToTrash
            && !isResolvingRecordingPermissions
    }

    func beginMovingMeetingsToTrash() -> Bool {
        guard !isMovingMeetingsToTrash else { return false }
        isMovingMeetingsToTrash = true
        return true
    }

    func finishMovingMeetingsToTrash() {
        isMovingMeetingsToTrash = false
    }

    private var activeRecordingMeetingIDs: Set<MeetingID> {
        Set([recordingMeetingID, recordingStartState.activeMeetingID].compactMap { $0 })
    }

    private(set) var microphoneDiscovery = MicrophoneDiscoverySnapshot.empty
    private(set) var microphoneDiscoveryError: String?
    private(set) var recordingMicrophoneMode = MicrophoneSelectionStore().load()
    private var microphoneDiscoveryRequestID: UInt64 = 0

    var resolvedRecordingMicrophone: MicrophoneDevice? {
        try? RecordingMicrophoneSelection.resolve(
            mode: recordingMicrophoneMode,
            discovery: microphoneDiscovery
        )
    }

    @discardableResult
    func refreshMicrophoneDiscovery() async -> MicrophoneDiscoverySnapshot {
        microphoneDiscoveryRequestID &+= 1
        let requestID = microphoneDiscoveryRequestID
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let load = await Task.detached(priority: .userInitiated) {
            do {
                return MicrophoneDiscoveryLoad(
                    snapshot: try .current(
                        excludingBundleIdentifier: ownBundleIdentifier
                    ),
                    errorDescription: nil
                )
            } catch {
                return MicrophoneDiscoveryLoad(
                    snapshot: .empty,
                    errorDescription: error.localizedDescription
                )
            }
        }.value
        guard requestID == microphoneDiscoveryRequestID else {
            return load.snapshot
        }
        microphoneDiscovery = load.snapshot
        if let errorDescription = load.errorDescription {
            microphoneDiscoveryError = String(localized: "Steno could not read the available microphones. (\(errorDescription))")
        } else {
            microphoneDiscoveryError = nil
        }
        return load.snapshot
    }

    func selectAutomaticMicrophone() {
        guard !isRecording, !isStartingRecording else { return }
        recordingMicrophoneMode = .automatic
        MicrophoneSelectionStore().save(recordingMicrophoneMode)
    }

    func selectMicrophone(_ device: MicrophoneDevice) {
        guard !isRecording, !isStartingRecording else { return }
        recordingMicrophoneMode = .manual(device)
        MicrophoneSelectionStore().save(recordingMicrophoneMode)
    }

    // Transkriptionssprache: explizit wählbar und persistiert. Der System-
    // Locale-Default hat sich als Falle erwiesen (englisches macOS ->
    // deutsche Sprache englisch transkribiert).
    private(set) var availableLocales: [Locale] = []
    /// Eine leere Liste heisst zweierlei: noch nicht gefragt, oder gefragt und
    /// nichts bekommen. Ohne diese Unterscheidung muesste die Oberflaeche
    /// raten, und der Wizard oeffnet bewusst vor `bootstrap`.
    private(set) var hasLoadedLocales = false
    private(set) var selectedLanguageID: String
    private(set) var languageWasChosenExplicitly: Bool
    private var resolvedLanguageFallback: Locale?
    private var locale: Locale {
        resolvedLanguageFallback ?? Locale(identifier: selectedLanguageID)
    }
    var effectiveTranscriptionLanguageID: String { locale.identifier }
    var transcriptionLanguageSelection: TranscriptionLanguageSelection {
        TranscriptionLanguageSelection(
            selectedIdentifier: selectedLanguageID,
            wasChosenExplicitly: languageWasChosenExplicitly,
            resolvedFallback: resolvedLanguageFallback
        )
    }
    var canConfirmTranscriptionLanguage: Bool {
        transcriptionLanguageSelection.canBeConfirmed(in: availableLocales)
    }
    var selectedTranscriptionLanguageName: String {
        localizedLanguageName(locale)
    }

    private static func assetKind(for track: AudioTrack) -> MediaAsset.Kind {
        track == .microphone ? .micTrack : .systemTrack
    }

    var canChangeTranscriptionModels: Bool { !isRecording && !isStartingRecording }

    /// Momentaufnahme der aktuell gewaehlten Live- und Final-Provider. Wird
    /// beim Aufnahmestart einmal gezogen und dann fuer die ganze Aufnahme
    /// gepinnt - eine spaetere Aenderung in den Einstellungen betrifft nur
    /// neue Aufnahmen und ausdrueckliche Neu-Transkriptionen.
    func currentTranscriptionPlan() -> TranscriptionPlan {
        TranscriptionPlan(
            liveProviderID: transcriptionModels.liveProviderID,
            finalProviderID: transcriptionModels.finalProviderID
        )
    }

    func transcriptionModelName(_ id: TranscriptionProviderID) -> String {
        transcriptionCatalog.descriptor(for: id)?.displayName ?? id.rawValue
    }

    /// Ob ein Modell wirklich installiert ist, nicht nur im Katalog steht.
    /// Apple braucht keine gesonderte Installation; alles andere haengt an
    /// `parakeetReadiness`. Falle 4: ein nicht installiertes Modell darf
    /// nicht als waehlbar erscheinen.
    func isTranscriptionModelInstalled(_ id: TranscriptionProviderID) -> Bool {
        id == .apple || parakeetReadiness?.isReady(for: transcriptionLocale) == true
    }

    // MARK: - Modelle

    /// Die Zustimmung lebt in der App, nicht in StenoKit: die Bibliothek
    /// kennt UserDefaults nicht und soll es nicht.
    let modelConsent = ModelConsent()
    private var modelCoordinator: ModelInstallationCoordinator?
    /// Arbeitsfaehigkeit je Sprache, nicht als einzelnes Ja: die
    /// Sprachassets haengen an der Locale, die Antwort kippt beim Wechsel.
    private(set) var modelReadiness: ModelReadiness?
    /// Bereitschaft des optionalen Parakeet-Modells, getrennt von
    /// `modelReadiness`: Parakeet ist kein Basismodell, ohne das gar nichts
    /// transkribiert werden kann, sondern eine ausdrueckliche Zusatzwahl.
    private(set) var parakeetReadiness: ModelReadiness?
    private(set) var modelInstallProgress: ModelInstallProgress?
    private(set) var isInstallingModels = false
    private(set) var modelInstallationCancellationState: MacModelInstallCancellationState = .idle
    private(set) var modelError: String?
    @ObservationIgnored
    private var activeModelInstallation: ActiveModelInstallation?
    @ObservationIgnored
    private var modelInstallationCompletionOwner: ModelInstallationIdentity?
    @ObservationIgnored
    private var modelInstallationCompletionWaiters: [CheckedContinuation<Void, Never>] = []

    var modelInstallProgressPresentation: MacModelInstallProgressPresentation? {
        MacModelInstallProgressPresentation.make(
            isInstalling: isInstallingModels,
            cancellationState: modelInstallationCancellationState,
            progress: modelInstallProgress
        )
    }

    var isInstallingBaselineModels: Bool {
        activeModelInstallation?.target == .baseline
    }

    var isInstallingParakeet: Bool {
        activeModelInstallation?.target == .parakeet
    }

    var showsModelInstallationCancellationAction: Bool {
        modelInstallationCancellationState == .cancelling
            || (activeModelInstallation != nil
                && modelInstallationCompletionOwner == nil)
    }
    /// Die zuletzt geprueften Modellbytes stimmten nicht mit den
    /// freigegebenen ueberein.
    ///
    /// Das braucht die Statuszeile, weil `readiness` nur prueft, ob Dateien
    /// **da** sind, nicht ob sie stimmen. Eine beschaedigte Datei liest sich
    /// dort als bereit, und dann stuende ein gruener Haken neben einer roten
    /// Fehlermeldung - genau so am 07.08.2026 auf dem Schirm gesehen.
    ///
    /// Ausschliesslich `ModelIntegrityError` setzt das Flag. Ein Netzfehler
    /// darf es nicht: `DownloadUtils.downloadRepo` fragt zuerst die
    /// Dateiliste ab, also scheitert ein Klick ohne Netz auch dann, wenn
    /// alles vollstaendig und in Ordnung ist.
    ///
    /// **Grenze:** der Wert liegt im Speicher. Nach einem Neustart steht die
    /// Zeile wieder auf "bereit", obwohl die Dateien noch beschaedigt sind.
    /// Die Alternative waere, bei jedem Start ein halbes Gigabyte zu hashen.
    private(set) var lastCheckFoundWrongBytes = false

    /// Ein Wortlaut fuer beide Stellen: die Ansicht zeigt ihn, solange der
    /// Knopf gesperrt ist, der Waechter setzt ihn, falls jemand die
    /// Installation an der Ansicht vorbei anstoesst.
    static let waitingForLocalesMessage = """
        Steno is still checking which languages this Mac can transcribe. \
        The models are downloaded for the language you pick, so installing \
        waits until that is known.
        """

    var modelBundles: [ModelBundleDescription] {
        modelCoordinator?.bundleDescriptions ?? []
    }

    var transcriptionLocale: Locale { locale }

    /// Wird beim Start und beim Oeffnen des Registers gerufen. Baut den
    /// Koordinator beim ersten Mal auf; das Pruefsummenmanifest kann fehlen,
    /// deshalb kann das scheitern.
    func refreshModelReadiness() async {
        guard !isInstallingModels, prepareModelCoordinator() else { return }
        await performBaselineReadinessRefresh(for: locale)
    }

    /// Zustimmen und sofort installieren. Der Nutzer soll nach dem Klick
    /// nicht raten muessen, ob noch etwas passieren wird.
    func allowAndInstallModels() async {
        _ = await installModels(for: locale)
    }

    /// Wird von der Transkriptions-Einstellungsseite gerufen, bevor sie
    /// Parakeets Status zeigt.
    func refreshParakeetReadiness() async {
        guard !isInstallingModels, prepareModelCoordinator() else { return }
        await performParakeetReadinessRefresh(for: locale)
    }

    /// Zustimmung und Installation fuer genau das eine optionale Modell,
    /// getrennt von `allowAndInstallModels()`: Parakeet ist keine
    /// Voraussetzung fuer die Basis-Arbeitsfaehigkeit, seine Installation
    /// ist eine eigene, ausdrueckliche Entscheidung.
    func installParakeet() async {
        guard !isRecording, !isInstallingModels else { return }
        isInstallingModels = true
        modelInstallationCancellationState = .idle
        modelError = nil
        modelInstallProgress = nil
        guard prepareModelCoordinator(), let modelCoordinator else {
            finishModelInstallationSetup()
            return
        }
        modelConsent.grant(sources: [.huggingFace])
        _ = await runRetainedModelInstallation(
            target: .parakeet,
            bundleIDs: [.parakeetTDTv3],
            locale: locale,
            coordinator: modelCoordinator,
            errorSummary: "Parakeet could not be installed."
        )
    }

    /// Das ausdrueckliche Apple-Retry-Angebot: ein fehlgeschlagener
    /// Parakeet-Lauf schlaegt Apple vor, wechselt aber nie selbst um. Der
    /// Klick hier ist die Zustimmung.
    func retryFinalASRWithApple(_ failedJob: Job) async {
        guard let runtime,
              failedJob.kind == .finalASR,
              failedJob.status == .failed
        else { return }
        let localeIdentifier = failedJob.localeIdentifier ?? selectedLanguageID
        do {
            try await runtime.jobStore.enqueue(Job.finalASR(
                meetingID: failedJob.meetingID,
                providerID: .apple,
                localeIdentifier: localeIdentifier,
                processingGenerationID: failedJob.processingGenerationID
            ))
            noteJobEnqueued(for: failedJob.meetingID)
        } catch {
            report(Self.message("The Apple retry could not be queued.", error))
        }
    }

    /// Prüft ausschließlich die lokal ausgewählte Importsprache. Ein Paket
    /// kann eine andere Sprache als die globale App-Einstellung tragen; diese
    /// darf den gepinnten Importjob weder überschreiben noch ersetzen.
    func meetingTransferModelsReady(for localeIdentifier: String) async -> Bool {
        guard let locale = meetingTransferLocale(identifier: localeIdentifier) else {
            return false
        }
        if modelCoordinator == nil {
            await refreshModelReadiness()
        }
        guard let modelCoordinator else { return false }
        let readiness = await modelCoordinator.readiness(
            for: [locale],
            bundleIDs: Self.baselineModelBundleIDs
        )
        return readiness.isReady(for: locale) && !lastCheckFoundWrongBytes
    }

    /// Der Klick im importierten Meeting ist die ausdrückliche Zustimmung zu
    /// den benannten Modellquellen. Erst danach darf ein Download beginnen.
    @discardableResult
    func installMeetingTransferModels(for localeIdentifier: String) async -> Bool {
        guard let locale = meetingTransferLocale(identifier: localeIdentifier) else {
            modelError = "This Mac cannot transcribe the selected language."
            return false
        }
        if await meetingTransferModelsReady(for: localeIdentifier) { return true }
        return await installModels(for: locale)
    }

    func meetingTransferLocale(identifier: String) -> Locale? {
        availableLocales.first {
            $0.identifier.caseInsensitiveCompare(identifier) == .orderedSame
        }
    }

    private func installModels(for locale: Locale) async -> Bool {
        // Der Waechter steht vor dem ersten `await`: der Hauptaktor gibt an
        // jedem Suspendierungspunkt ab, zwei schnelle Klicks kaemen sonst
        // beide durch, und der erste Abschluss meldete Ruhe, waehrend der
        // zweite Lauf noch laedt.
        guard !isInstallingModels else { return false }
        // Zweiter Waechter, aus demselben Grund an derselben Stelle: die
        // Installation reserviert die Sprachassets fuer `locale`, und `locale`
        // steht erst fest, wenn `loadAvailableLocales` durch ist. Vorher zu
        // laden hiesse, ein halbes Gigabyte fuer die zufaellig voreingestellte
        // Sprache zu reservieren. Er steht hier und nicht nur am Knopf, weil
        // der Knopf nicht der einzige Weg bleiben muss.
        guard hasLoadedLocales else {
            modelError = Self.waitingForLocalesMessage
            return false
        }
        isInstallingModels = true
        modelInstallationCancellationState = .idle
        modelError = nil
        // `lastCheckFoundWrongBytes` wird hier bewusst **nicht** geloescht.
        // Es wird nur von einer bestandenen Pruefung widerlegt, nicht von
        // einem neuen Versuch: scheitert der naechste Lauf schon vorher,
        // etwa ohne Netz am Dateilisting, wissen wir nichts Neues - die
        // beschaedigten Dateien liegen unveraendert da, und "Ready" waere
        // wieder die Luege, die dieser Zustand verhindern soll.
        modelInstallProgress = nil
        guard prepareModelCoordinator(), let modelCoordinator else {
            finishModelInstallationSetup()
            return false
        }
        modelConsent.grant(sources: modelSources())
        return await runRetainedModelInstallation(
            target: .baseline,
            bundleIDs: Self.baselineModelBundleIDs,
            locale: locale,
            coordinator: modelCoordinator,
            errorSummary: "The models could not be installed."
        )
    }

    private func prepareModelCoordinator() -> Bool {
        guard modelCoordinator == nil else { return true }
        do {
            modelCoordinator = try ModelInstallationCoordinator.standard(
                modelCacheDirectory: resolvedModelCacheDirectory
            )
            return true
        } catch {
            modelError = Self.message("The model list could not be read.", error)
            return false
        }
    }

    private func runRetainedModelInstallation(
        target: ModelInstallationTarget,
        bundleIDs: Set<ModelBundleID>,
        locale: Locale,
        coordinator: ModelInstallationCoordinator,
        errorSummary: String
    ) async -> Bool {
        let identity = ModelInstallationIdentity()
        let consentGranted = modelConsent.isGranted
        let task = Task { [weak self] in
            guard let self else { return false }
            return await self.performModelInstallation(
                target: target,
                bundleIDs: bundleIDs,
                locale: locale,
                coordinator: coordinator,
                consentGranted: consentGranted,
                identity: identity,
                errorSummary: errorSummary
            )
        }
        let installation = ActiveModelInstallation(
            identity: identity,
            target: target,
            locale: locale,
            task: task
        )
        activeModelInstallation = installation
        modelInstallationCompletionOwner = nil

        let installationCompleted = await task.value
        guard isCurrentModelInstallation(installation) else { return false }
        guard modelInstallationCancellationState == .idle else { return false }
        guard claimModelInstallationCompletion(installation) else { return false }

        await refreshReadiness(
            for: installation.target,
            locale: installation.locale,
            owner: installation.identity
        )
        guard isCurrentModelInstallation(installation) else { return false }
        let verifiedReady = modelInstallationIsReady(
            target: installation.target,
            locale: installation.locale
        )
        finishModelInstallation(installation)
        return installationCompleted && verifiedReady
    }

    private func performModelInstallation(
        target: ModelInstallationTarget,
        bundleIDs: Set<ModelBundleID>,
        locale: Locale,
        coordinator: ModelInstallationCoordinator,
        consentGranted: Bool,
        identity: ModelInstallationIdentity,
        errorSummary: String
    ) async -> Bool {
        do {
            try await coordinator.install(
                bundleIDs: bundleIDs,
                for: locale,
                consentGranted: consentGranted
            ) { [weak self] progress in
                Task { @MainActor in
                    self?.applyInstallProgress(progress, identity: identity)
                }
            }
            if target == .baseline {
                // Nur eine vollständig durchgelaufene Prüfung widerlegt einen
                // früheren Integritätsfehler.
                lastCheckFoundWrongBytes = false
            }
            return true
        } catch is CancellationError {
            return false
        } catch let integrity as ModelIntegrityError where target == .baseline {
            if modelConsent.isGranted,
               modelInstallationCancellationState == .idle {
                modelError = Self.message(errorSummary, integrity)
                lastCheckFoundWrongBytes = true
            }
            return false
        } catch {
            // URLSession und Apples Assettransfer koennen einen angeforderten
            // Abbruch als Transportfehler statt als CancellationError melden.
            if modelConsent.isGranted,
               modelInstallationCancellationState == .idle {
                modelError = Self.message(errorSummary, error)
            }
            return false
        }
    }

    /// Widerruf stoppt kuenftige Downloads und fordert den Abbruch eines
    /// laufenden an: die Diarisierung bricht ueber URLSession wirklich ab,
    /// bei Apples Assetanfrage wird zusaetzlich deren `Progress` abgebrochen.
    /// Geloescht wird nichts: Apple-Assets liegen systemweit, und was schon
    /// da ist, soll weiter benutzbar bleiben.
    func revokeModelConsent() async {
        modelConsent.revoke()
        guard let installation = activeModelInstallation else {
            await modelCoordinator?.cancelAll()
            await performBaselineReadinessRefresh(for: locale)
            await performParakeetReadinessRefresh(for: locale)
            return
        }

        if modelInstallationCancellationState == .cancelling
            || modelInstallationCompletionOwner != nil {
            await modelCoordinator?.cancelAll()
            await waitForModelInstallationCompletion(installation)
            return
        }

        modelInstallationCancellationState = .cancelling
        guard claimModelInstallationCompletion(installation) else {
            await waitForModelInstallationCompletion(installation)
            return
        }
        await cancelAndFinishModelInstallation(installation)
    }

    /// Bricht nur den laufenden Transfer ab. Die bereits protokollierte
    /// Zustimmung bleibt erhalten und ist weiterhin getrennt widerrufbar.
    @discardableResult
    func cancelModelInstallation() async -> Bool {
        guard isInstallingModels,
              modelInstallationCancellationState == .idle,
              let installation = activeModelInstallation,
              modelInstallationCompletionOwner == nil else { return false }

        modelInstallationCancellationState = .cancelling
        guard claimModelInstallationCompletion(installation) else { return false }
        await cancelAndFinishModelInstallation(installation)
        return true
    }

    private func cancelAndFinishModelInstallation(
        _ installation: ActiveModelInstallation
    ) async {
        await modelCoordinator?.cancelAll()
        _ = await installation.task.value
        guard isCurrentModelInstallation(installation) else { return }

        // Keine lokale Vermutung über teilweise geschriebene Bytes. Erst
        // nachdem genau der abgebrochene Task wirklich beendet ist, werden
        // beide verifizierten Zustände neu aus den Installern gelesen.
        await performBaselineReadinessRefresh(
            for: installation.locale,
            owner: installation.identity
        )
        await performParakeetReadinessRefresh(
            for: installation.locale,
            owner: installation.identity
        )
        guard isCurrentModelInstallation(installation) else { return }
        finishModelInstallation(installation)
    }

    /// Die Quellen in der Reihenfolge der Bundles, jede genau einmal. Sie
    /// werden mit der Zustimmung protokolliert, ein blosses Ja waere zu wenig.
    private func modelSources() -> [ModelSource] {
        var seen: Set<ModelSource> = []
        return modelBundles.map(\.source).filter { seen.insert($0).inserted }
    }

    /// Die Rueckrufe kommen aus fremden Kontexten und koennen sich beim
    /// Sprung auf den Hauptaktor ueberholen. Innerhalb eines Bundles laeuft
    /// der Balken deshalb nur vorwaerts.
    private func applyInstallProgress(
        _ progress: ModelInstallProgress,
        identity: ModelInstallationIdentity
    ) {
        guard activeModelInstallation?.identity === identity else { return }
        guard progress.fraction.isFinite else { return }
        guard progress.supersedes(modelInstallProgress) else { return }
        modelInstallProgress = progress
    }

    private func performBaselineReadinessRefresh(
        for locale: Locale,
        owner: ModelInstallationIdentity? = nil
    ) async {
        guard canApplyModelReadinessRefresh(owner: owner),
              let modelCoordinator else { return }
        let result = await modelCoordinator.readiness(
            for: [locale],
            bundleIDs: Self.baselineModelBundleIDs
        )
        guard canApplyModelReadinessRefresh(owner: owner) else { return }
        modelReadiness = result
    }

    private func performParakeetReadinessRefresh(
        for locale: Locale,
        owner: ModelInstallationIdentity? = nil
    ) async {
        guard canApplyModelReadinessRefresh(owner: owner),
              let modelCoordinator else { return }
        let result = await modelCoordinator.readiness(
            for: [locale],
            bundleIDs: [.parakeetTDTv3]
        )
        guard canApplyModelReadinessRefresh(owner: owner) else { return }
        parakeetReadiness = result
    }

    private func refreshReadiness(
        for target: ModelInstallationTarget,
        locale: Locale,
        owner: ModelInstallationIdentity
    ) async {
        switch target {
        case .baseline:
            await performBaselineReadinessRefresh(for: locale, owner: owner)
        case .parakeet:
            await performParakeetReadinessRefresh(for: locale, owner: owner)
        }
    }

    private func modelInstallationIsReady(
        target: ModelInstallationTarget,
        locale: Locale
    ) -> Bool {
        switch target {
        case .baseline:
            modelReadiness?.isReady(for: locale) == true
                && !lastCheckFoundWrongBytes
        case .parakeet:
            parakeetReadiness?.isReady(for: locale) == true
        }
    }

    private func canApplyModelReadinessRefresh(
        owner: ModelInstallationIdentity?
    ) -> Bool {
        if let owner {
            return activeModelInstallation?.identity === owner
        }
        return activeModelInstallation == nil
    }

    private func isCurrentModelInstallation(
        _ installation: ActiveModelInstallation
    ) -> Bool {
        activeModelInstallation?.identity === installation.identity
    }

    private func claimModelInstallationCompletion(
        _ installation: ActiveModelInstallation
    ) -> Bool {
        guard isCurrentModelInstallation(installation),
              modelInstallationCompletionOwner == nil else { return false }
        modelInstallationCompletionOwner = installation.identity
        return true
    }

    private func waitForModelInstallationCompletion(
        _ installation: ActiveModelInstallation
    ) async {
        guard isCurrentModelInstallation(installation) else { return }
        await withCheckedContinuation { continuation in
            guard isCurrentModelInstallation(installation) else {
                continuation.resume()
                return
            }
            modelInstallationCompletionWaiters.append(continuation)
        }
    }

    private func finishModelInstallationSetup() {
        isInstallingModels = false
        modelInstallationCancellationState = .idle
        modelInstallProgress = nil
    }

    private func finishModelInstallation(
        _ installation: ActiveModelInstallation
    ) {
        guard isCurrentModelInstallation(installation),
              modelInstallationCompletionOwner === installation.identity else { return }
        activeModelInstallation = nil
        modelInstallationCompletionOwner = nil
        isInstallingModels = false
        modelInstallationCancellationState = .idle
        modelInstallProgress = nil
        let waiters = modelInstallationCompletionWaiters
        modelInstallationCompletionWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private enum ModelInstallationTarget: Equatable {
        case baseline
        case parakeet
    }

    private final class ModelInstallationIdentity: @unchecked Sendable {}

    private struct ActiveModelInstallation {
        let identity: ModelInstallationIdentity
        let target: ModelInstallationTarget
        let locale: Locale
        let task: Task<Bool, Never>
    }

    static func libraryURL() -> URL {
        // Precedence contract lives in StorageLocation: env override keeps
        // dev/test isolation, then the user's custom path from Settings.
        StorageLocation.effectiveLibraryDirectory(defaults: .standard)
    }

    /// Nur fuer Tests des Erstlaufs: lenkt Download und Provider auf ein
    /// Wegwerfverzeichnis, damit ein Rechner mit vorhandenen Modellen den
    /// Zustand eines frischen Rechners zeigen kann. Ohne die Variable bleibt
    /// alles, wie FluidAudio es vorgibt.
    ///
    /// Wie `STENO_LIBRARY_DIR` wird die Umgebung hier gelesen und nicht in
    /// StenoKit: die Kenntnis der Ablage gehoert in die App-Schicht.
    static func modelCacheURL() -> URL? {
        guard let override = ProcessInfo.processInfo.environment["STENO_MODEL_DIR"] else {
            return nil
        }
        return URL(fileURLWithPath: override, isDirectory: true)
    }

    /// Diese Werte werden erst beim Zugriff aufgeloest, damit die
    /// produktiven Umgebungs-Overrides ihren bisherigen Zeitpunkt behalten.
    /// Tests reichen stattdessen explizite, isolierte Pfade ein.
    var resolvedLibraryURL: URL {
        libraryURLOverride ?? Self.libraryURL()
    }

    var resolvedModelCacheDirectory: URL? {
        modelCacheDirectoryOverride ?? Self.modelCacheURL()
    }

    // MARK: - Start

    func bootstrap() async {
        guard runtime == nil,
              !isBootstrappingPipeline,
              !isSwitchingTranscriptionLanguage else { return }
        isBootstrappingPipeline = true
        defer { isBootstrappingPipeline = false }
        startupState = .opening
        // Die Pipeline haelt ihre Locale fuer ihre gesamte Lebensdauer.
        // Deshalb muss die effektive, von Speech tatsaechlich unterstuetzte
        // Sprache feststehen, bevor der Koordinator entsteht.
        await loadAvailableLocales()
        var fatalFailure: MacStartupFailure?
        var replacementStartupWarnings: [MacStartupWarning] = []
        do {
            // Encryption beta: a crash between the activation renames leaves
            // the root missing with a complete backup next to it; restore
            // deterministically BEFORE anything opens the library.
            let encryptionRoot = resolvedLibraryURL
            if LibraryEncryptionCoordinator.recoverInterruptedSwitch(root: encryptionRoot) {
                replacementStartupWarnings.append(.pipeline(
                    "An interrupted library encryption switch was rolled back. Your library was restored from its backup."
                ))
            }
            let request = MacPipelineStartRequest(
                libraryURL: encryptionRoot,
                // Der Provider wird je Job aufgeloest, nicht fest verdrahtet:
                // ein finalASR-Job traegt seinen gepinnten Provider aus
                // `meeting.transcriptionPlan`, und die Ausfuehrungsgrenze
                // lehnt einen nicht registrierten Provider ab, statt still
                // auf Apple zurueckzufallen (`TranscriptionRegistryError`).
                transcriptionProviderResolver: { [transcriptionRegistry] providerID, assetKind in
                    try transcriptionRegistry.resolve(providerID, for: assetKind)
                },
                modelCacheDirectory: resolvedModelCacheDirectory,
                textModelProviderResolver: { selection in
                    try TextModelSettings.resolveProvider(selection: selection)
                },
                locale: locale,
                activeMeetingIDs: activeRecordingMeetingIDs
            )
            let runtime = try await pipelineStarter(request)
            invalidateRuntimeDependentOperations()
            self.runtime = runtime
            libraryIssues = []
            invalidateDemoDataContext()
            if !meetingTransferImportClientWasInjected {
                meetingTransferClient = MeetingTransferImportClient(
                    service: MeetingTransferImportService(
                        library: runtime.library,
                        jobStore: runtime.jobStore
                    )
                )
            }
            if !meetingTransferDetailClientWasInjected {
                meetingTransferDetailClient = MeetingTransferDetailClient(
                    library: runtime.library,
                    jobStore: runtime.jobStore
                )
            }
            do {
                folderStore = try FolderStore.open(layout: runtime.library.layout)
            } catch {
                folderStore = nil
                reportLibraryIssue(.folders(error.localizedDescription))
            }
            invalidateDemoDataContext()
            let meetingChanges = await runtime.library.meetingChanges()
            meetingChangesTask?.cancel()
            meetingChangesTask = Task { [weak self] in
                for await meetingID in meetingChanges {
                    guard !Task.isCancelled else { return }
                    await self?.refreshMeeting(meetingID)
                    // Keep the derived search index in delta step with the
                    // library; fingerprint checks make repeats no-ops.
                    if let library = self?.runtime?.library {
                        try? await self?.searchIndex?.update(
                            meetingID: meetingID,
                            library: library
                        )
                    }
                }
            }
            // First-record latency: pre-touch planned engines off the
            // critical path (never downloads, never consent prompts).
            if runtime != nil {
                let plan = currentTranscriptionPlan()
                Task { [transcriptionRegistry, locale] in
                    await TranscriptionWarmup.preTouch(
                        plan: currentTranscriptionPlan(),
                        registry: transcriptionRegistry,
                        locale: locale
                    )
                }
            }
            // Full-text search: heal/rebuild the derived index once per
            // launch, off the critical path.
            do {
                let index = try MeetingSearchIndex(layout: runtime.library.layout)
                searchIndex = index
                searchIndexRebuildTask?.cancel()
                searchIndexRebuildTask = Task { [library = runtime.library] in
                    try? await index.rebuild(library: library)
                }
            } catch {
                // The index is derived data: a failure to open it only
                // degrades search, never the library itself.
                Self.searchIndexLogger.error("Search index unavailable: \(error.localizedDescription, privacy: .public)")
            }
            // Nach dem Sweep: gestrandete Capture-Dateien harter Abstürze
            // als Originalspuren adoptieren und die Finalisierung einreihen.
            let captureRecoveryFailure: String?
            do {
                let recovery = try await CaptureRecovery.run(
                    library: runtime.library,
                    jobStore: runtime.jobStore
                )
                captureRecoveryFailure = Self.captureRecoveryFailureMessage(
                    recovery.failures
                )
            } catch {
                captureRecoveryFailure = Self.message(
                    "Interrupted recordings could not be inspected. Existing recording files remain stored.",
                    error
                )
            }
            // Einmalig: Ordnernamen aus dem Steno-Altimport in echte Ordner
            // überführen. Scheitert das, fehlen Ordner - die Meetings selbst
            // sind unberührt, deshalb bricht es den Start nicht ab.
            if let folderStore {
                _ = try? await LegacyFolderAdoption.run(
                    library: runtime.library,
                    folders: folderStore
                )
            }
            await refreshMeetings()
            await refreshDemoDataStatus()
            if let pipelineWarning = Self.pipelineStartupWarningMessage(
                for: runtime.startupWarnings
            ) {
                replacementStartupWarnings.append(.pipeline(pipelineWarning))
            }
            if let captureRecoveryFailure {
                replacementStartupWarnings.append(
                    .captureRecovery(captureRecoveryFailure)
                )
            }
        } catch {
            fatalFailure = .runtimeOpening(error.localizedDescription)
        }
        // Erst nach der Sprachwahl: die Arbeitsfaehigkeit haengt an der
        // Sprache, die dann wirklich eingestellt ist.
        await refreshModelReadiness()
        // Failed wird erst nach dem letzten Suspendierungspunkt sichtbar.
        // Damit kann der sichtbare Retry nicht noch in den auslaufenden
        // Bootstrap geraten und am In-Flight-Guard wirkungslos abprallen.
        if let fatalFailure {
            startupState = .failed(fatalFailure)
        } else {
            startupWarnings = replacementStartupWarnings
            startupState = .ready
        }
    }

    private func loadAvailableLocales() async {
        let supported = await supportedLocalesLoader()
        // Gegen dieselbe unformatierte Speech-Liste aufloesen, die auch der
        // Provider verwendet. Die Sortierung darunter ist reine Anzeige und
        // darf die Auswahl der tatsaechlichen Erkenner-Locale nicht aendern.
        let alreadyValid = supported.contains {
            $0.identifier.caseInsensitiveCompare(selectedLanguageID) == .orderedSame
        }
        resolvedLanguageFallback = alreadyValid
            ? nil
            : LocaleResolver.select(
                requested: Locale(identifier: selectedLanguageID),
                supported: supported
            )
        availableLocales = supported.sorted {
            localizedLanguageName($0) < localizedLanguageName($1)
        }
        hasLoadedLocales = true
    }

    func localizedLanguageName(_ locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier)
            ?? locale.identifier
    }

    /// Sprachwechsel startet die Pipeline neu, damit auch finale Läufe die
    /// neue Sprache nutzen. Während einer Aufnahme nicht erlaubt (die UI
    /// sperrt das zusätzlich).
    func setLanguage(_ identifier: String) async {
        guard !isRecording,
              !isStartingRecording,
              !isBootstrappingPipeline,
              !isSwitchingTranscriptionLanguage,
              !isManagingDemoData else { return }
        let requestedSelection = TranscriptionLanguageSelection(
            selectedIdentifier: identifier,
            wasChosenExplicitly: true,
            resolvedFallback: nil
        )
        // Nur eine von Speech angebotene konkrete Locale kann der Nutzer als
        // Tatsache bestaetigen. Die Automatic-Option ist die eine Ausnahme:
        // Der Sentinel ist selbst die ausdrueckliche Entscheidung (Opt-in),
        // auch ohne Speech-Bestaetigung. Fremde Kennungen bleiben Ableitung.
        guard requestedSelection.selectsAutomatic
            || requestedSelection.canBeConfirmed(in: availableLocales) else {
            return
        }
        guard meetingTransferImportState == nil else {
            report("Close the meeting import before changing the transcription language.")
            return
        }
        guard TranscriptionLanguageChangePolicy.shouldApply(
            identifier: identifier,
            selectedIdentifier: selectedLanguageID,
            wasChosenExplicitly: languageWasChosenExplicitly
        ) else { return }
        selectedLanguageID = identifier
        languageWasChosenExplicitly = true
        resolvedLanguageFallback = nil
        languagePreferences.saveExplicitChoice(identifier)
        if let runtime {
            isSwitchingTranscriptionLanguage = true
            meetingChangesTask?.cancel()
            meetingChangesTask = nil
            // Vor dem ersten Suspendierungspunkt synchron abhaengen: Sonst
            // koennte waehrend `stop()` noch ein Start die alte Runtime
            // greifen und erst nach dem Active-ID-Snapshot ein Meeting
            // anlegen, das der neue RecoverySweep fuer gestrandet hielte.
            invalidateRuntimeDependentOperations()
            self.runtime = nil
            folderStore = nil
            invalidateDemoDataContext()
            await runtime.coordinator.stop()
            // Ohne Suspendierung freigeben und sofort selbst bootstrappen.
            // Ein fremder Bootstrap kam waehrend des Wechsels nicht hinein.
            isSwitchingTranscriptionLanguage = false
            await bootstrap()
        }
    }

    func refreshMeetings(
        invalidatingDemoDataStatus: Bool = true
    ) async {
        await refreshMeetingList()
        await refreshFolderList()
        if invalidatingDemoDataStatus {
            invalidateDemoDataStatusAfterLibraryChange()
        }
    }

    private struct MeetingRefreshToken {
        let runtimeGeneration: UInt64
        let refreshGeneration: UInt64
        let runtime: PipelineRuntime
    }

    private struct FolderRefreshToken {
        let runtimeGeneration: UInt64
        let refreshGeneration: UInt64
        let runtime: PipelineRuntime
        let folderStore: FolderStore
    }

    private func refreshMeetingList(
        preservingRetryGeneration retryGeneration: UInt64? = nil
    ) async {
        guard let token = beginMeetingRefresh(
            preservingRetryGeneration: retryGeneration
        ) else { return }
        do {
            let loadedMeetings = try await meetingListLoader(token.runtime.library)
                .sorted { $0.createdAt > $1.createdAt }
            var withAudio: Set<MeetingID> = []
            for meeting in loadedMeetings
            where await hasPlayableAudio(meeting.id, in: token.runtime) {
                withAudio.insert(meeting.id)
            }
            guard meetingRefreshIsCurrent(token) else { return }
            meetings = loadedMeetings
            meetingsWithAudio = withAudio
            restoreSelection(from: loadedMeetings)
            selectedMeetingIDs = MeetingSidebarSelectionPolicy.pruned(
                selectedMeetingIDs,
                to: Set(loadedMeetings.map(\.id))
            )
            clearLibraryIssue(.meetings)
        } catch {
            guard meetingRefreshIsCurrent(token) else { return }
            reportLibraryIssue(.meetings(error.localizedDescription))
        }
    }

    private func refreshFolderList(
        preservingRetryGeneration retryGeneration: UInt64? = nil
    ) async {
        guard let token = beginFolderRefresh(
            preservingRetryGeneration: retryGeneration
        ) else { return }
        do {
            let loadedFolders = try await folderListLoader(token.folderStore)
            guard folderRefreshIsCurrent(token) else { return }
            folders = loadedFolders
            clearLibraryIssue(.folders)
        } catch {
            guard folderRefreshIsCurrent(token) else { return }
            reportLibraryIssue(.folders(error.localizedDescription))
        }
    }

    func retryLibraryIssue(_ issue: MacLibraryIssue) async {
        guard runtime != nil,
              libraryIssues.contains(where: { $0.id == issue.id }),
              activeLibraryIssueRetryGenerations[issue.id] == nil
        else { return }
        let retryGeneration = beginLibraryIssueRetry(issue.id)
        defer { finishLibraryIssueRetry(issue.id, generation: retryGeneration) }

        switch issue {
        case .meetings:
            await refreshMeetingList(
                preservingRetryGeneration: retryGeneration
            )
        case .folders:
            guard let retryRuntime = runtime else { return }
            let retryRuntimeGeneration = runtimeGeneration
            if folderStore == nil {
                do {
                    let openedStore = try FolderStore.open(
                        layout: retryRuntime.library.layout
                    )
                    guard runtimeIsCurrent(
                        retryRuntime,
                        generation: retryRuntimeGeneration
                    ), libraryIssueRetryIsCurrent(
                        issue.id,
                        generation: retryGeneration
                    ) else { return }
                    folderStore = openedStore
                    _ = try? await LegacyFolderAdoption.run(
                        library: retryRuntime.library,
                        folders: openedStore
                    )
                    guard runtimeIsCurrent(
                        retryRuntime,
                        generation: retryRuntimeGeneration
                    ), libraryIssueRetryIsCurrent(
                        issue.id,
                        generation: retryGeneration
                    ) else { return }
                } catch {
                    guard runtimeIsCurrent(
                        retryRuntime,
                        generation: retryRuntimeGeneration
                    ), libraryIssueRetryIsCurrent(
                        issue.id,
                        generation: retryGeneration
                    ) else { return }
                    reportLibraryIssue(.folders(error.localizedDescription))
                    return
                }
            }
            await refreshFolderList(
                preservingRetryGeneration: retryGeneration
            )
        }
        invalidateDemoDataStatusAfterLibraryChange()
    }

    private func beginMeetingRefresh(
        preservingRetryGeneration retryGeneration: UInt64?
    ) -> MeetingRefreshToken? {
        invalidateLibraryIssueRetry(
            .meetings,
            preserving: retryGeneration
        )
        meetingRefreshGeneration &+= 1
        guard let runtime else { return nil }
        return MeetingRefreshToken(
            runtimeGeneration: runtimeGeneration,
            refreshGeneration: meetingRefreshGeneration,
            runtime: runtime
        )
    }

    private func beginFolderRefresh(
        preservingRetryGeneration retryGeneration: UInt64?
    ) -> FolderRefreshToken? {
        invalidateLibraryIssueRetry(
            .folders,
            preserving: retryGeneration
        )
        folderRefreshGeneration &+= 1
        guard let runtime, let folderStore else { return nil }
        return FolderRefreshToken(
            runtimeGeneration: runtimeGeneration,
            refreshGeneration: folderRefreshGeneration,
            runtime: runtime,
            folderStore: folderStore
        )
    }

    private func meetingRefreshIsCurrent(_ token: MeetingRefreshToken) -> Bool {
        guard let currentRuntime = runtime else { return false }
        return runtimeGeneration == token.runtimeGeneration
            && meetingRefreshGeneration == token.refreshGeneration
            && currentRuntime.library === token.runtime.library
    }

    private func folderRefreshIsCurrent(_ token: FolderRefreshToken) -> Bool {
        guard let currentRuntime = runtime, let currentStore = folderStore else {
            return false
        }
        return runtimeGeneration == token.runtimeGeneration
            && folderRefreshGeneration == token.refreshGeneration
            && currentRuntime.library === token.runtime.library
            && currentStore === token.folderStore
    }

    private func runtimeIsCurrent(
        _ expectedRuntime: PipelineRuntime,
        generation: UInt64
    ) -> Bool {
        guard let currentRuntime = runtime else { return false }
        return runtimeGeneration == generation
            && currentRuntime.library === expectedRuntime.library
    }

    private func beginLibraryIssueRetry(_ id: MacLibraryIssue.ID) -> UInt64 {
        let generation = (libraryIssueRetryCounters[id] ?? 0) &+ 1
        libraryIssueRetryCounters[id] = generation
        activeLibraryIssueRetryGenerations[id] = generation
        retryingLibraryIssueIDs.insert(id)
        return generation
    }

    private func finishLibraryIssueRetry(
        _ id: MacLibraryIssue.ID,
        generation: UInt64
    ) {
        guard libraryIssueRetryIsCurrent(id, generation: generation) else {
            return
        }
        activeLibraryIssueRetryGenerations[id] = nil
        retryingLibraryIssueIDs.remove(id)
    }

    private func libraryIssueRetryIsCurrent(
        _ id: MacLibraryIssue.ID,
        generation: UInt64
    ) -> Bool {
        activeLibraryIssueRetryGenerations[id] == generation
    }

    private func invalidateLibraryIssueRetry(
        _ id: MacLibraryIssue.ID,
        preserving generation: UInt64?
    ) {
        guard activeLibraryIssueRetryGenerations[id] != generation else {
            return
        }
        activeLibraryIssueRetryGenerations[id] = nil
        retryingLibraryIssueIDs.remove(id)
    }

    private func invalidateRuntimeDependentOperations() {
        runtimeGeneration &+= 1
        meetingRefreshGeneration &+= 1
        folderRefreshGeneration &+= 1
        activeLibraryIssueRetryGenerations.removeAll()
        retryingLibraryIssueIDs.removeAll()
    }

    #if DEBUG
    func stopBackgroundLibraryTasksForTesting() async {
        if let meetingChangesTask {
            meetingChangesTask.cancel()
            await meetingChangesTask.value
            self.meetingChangesTask = nil
        }
        if let searchIndexRebuildTask {
            searchIndexRebuildTask.cancel()
            await searchIndexRebuildTask.value
            self.searchIndexRebuildTask = nil
        }
        searchIndex = nil
    }
    #endif

    func retryStartup() async {
        guard case .failed = startupState, runtime == nil else { return }
        await bootstrap()
    }

    private func reportLibraryIssue(_ issue: MacLibraryIssue) {
        if let index = libraryIssues.firstIndex(where: { $0.id == issue.id }) {
            libraryIssues[index] = issue
        } else {
            libraryIssues.append(issue)
        }
    }

    private func clearLibraryIssue(_ id: MacLibraryIssue.ID) {
        libraryIssues.removeAll { $0.id == id }
    }

    // MARK: - Demo data

    func refreshDemoDataStatus() async {
        guard !isManagingDemoData,
              !demoDataPresentationState.isChecking else { return }
        guard var context = currentDemoDataContext() else {
            _ = demoDataPresentationState.invalidateStatus()
            return
        }
        let token = demoDataPresentationState.beginStatusCheck()
        context = DemoDataPublicationContext(
            library: context.library,
            folders: context.folders,
            token: token
        )
        do {
            let status = try await DemoLibrarySeeder(
                library: context.library,
                folders: context.folders
            ).status()
            guard isCurrentDemoDataContext(context) else { return }
            _ = demoDataPresentationState.publish(status, for: token)
        } catch {
            guard isCurrentDemoDataContext(context) else { return }
            _ = demoDataPresentationState.publishStatusFailure(
                String(localized: DemoDataPresentation.statusCheckFailedMessage),
                for: token
            )
        }
    }

    func installDemoData() async {
        await performDemoData(.install)
    }

    func replaceDemoData(policy: DemoReplacementPolicy) async {
        await performDemoData(.replace(policy))
    }

    func removeDemoData() async {
        await performDemoData(.remove)
    }

    private enum DemoDataAction {
        case install
        case replace(DemoReplacementPolicy)
        case remove
    }

    private func performDemoData(_ action: DemoDataAction) async {
        guard !isManagingDemoData else { return }
        _ = demoDataPresentationState.invalidateStatus()
        demoDataPresentationState.beginLifecycleOperation()
        guard let context = currentDemoDataContext() else {
            demoDataPresentationState.publishLifecycleError(
                String(localized: DemoDataPresentation.unavailableStatus)
            )
            return
        }
        isManagingDemoData = true
        defer { isManagingDemoData = false }
        do {
            let seeder = try DemoLibrarySeeder(
                library: context.library,
                folders: context.folders
            )
            switch action {
            case .install:
                try await seeder.install()
            case .replace(let policy):
                let result = try await seeder.replace(policy: policy)
                guard isCurrentDemoDataContext(context) else { return }
                demoDataPresentationState.publishLifecycleResult(result)
            case .remove:
                let result = try await seeder.remove()
                guard isCurrentDemoDataContext(context) else { return }
                demoDataPresentationState.publishLifecycleResult(result)
            }
        } catch {
            guard isCurrentDemoDataContext(context) else { return }
            demoDataPresentationState.publishLifecycleError(
                String(localized: DemoDataPresentation.operationFailedMessage)
            )
        }
        guard isCurrentDemoDataContext(context) else { return }
        await refreshMeetings(invalidatingDemoDataStatus: false)
        guard isCurrentDemoDataContext(context) else { return }
        isManagingDemoData = false
        _ = demoDataPresentationState.invalidateStatus()
        await refreshDemoDataStatus()
    }

    private func currentDemoDataContext() -> DemoDataPublicationContext? {
        guard let runtime, let folderStore else { return nil }
        return DemoDataPublicationContext(
            library: runtime.library,
            folders: folderStore,
            token: demoDataPresentationState.currentStatusToken
        )
    }

    private func isCurrentDemoDataContext(
        _ context: DemoDataPublicationContext
    ) -> Bool {
        context.isCurrent(
            library: runtime?.library,
            folders: folderStore,
            token: demoDataPresentationState.currentStatusToken
        )
    }

    private func invalidateDemoDataContext() {
        demoDataStatusRefreshTask?.cancel()
        demoDataStatusRefreshTask = nil
        _ = demoDataPresentationState.invalidateStatus()
    }

    private func invalidateDemoDataStatusAfterLibraryChange() {
        guard !isManagingDemoData else {
            return
        }
        let hadObservedStatus = demoDataPresentationState.status != nil
            || demoDataPresentationState.isChecking
            || demoDataPresentationState.statusError != nil
        _ = demoDataPresentationState.invalidateStatus()
        guard hadObservedStatus, currentDemoDataContext() != nil else { return }
        demoDataStatusRefreshTask?.cancel()
        demoDataStatusRefreshTask = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            await self?.refreshDemoDataStatus()
        }
    }

    /// Inhaltsänderungen an Demo-Meetings erscheinen nicht immer im
    /// `meetingChanges`-Strom, etwa bei Revisionen, Notizen oder review.json.
    /// Der explizite Hook hält den Status deshalb ohne Polling aktuell.
    func demoDataMeetingContentDidChange(_ meetingID: MeetingID) async {
        guard !isManagingDemoData,
              let context = currentDemoDataContext()
        else { return }
        let meeting: Meeting?
        if let cached = meetings.first(where: { $0.id == meetingID }) {
            meeting = cached
        } else {
            meeting = try? await context.library.loadMeeting(meetingID)
        }
        guard isCurrentDemoDataContext(context), meeting?.isDemo == true else {
            return
        }
        invalidateDemoDataStatusAfterLibraryChange()
    }

    /// Eine Review-Aktion darf erst nach erfolgreicher Persistenz die
    /// Demo-Prüfung anstoßen. `keepGeneric` schreibt zwar keine Evidenz,
    /// verändert aber trotzdem review.json.
    func demoDataDidPersistSpeakerReview(for meetingID: MeetingID) async {
        await demoDataMeetingContentDidChange(meetingID)
    }

    private func refreshMeeting(_ meetingID: MeetingID) async {
        guard let token = beginMeetingRefresh(
            preservingRetryGeneration: nil
        ) else { return }
        guard meetings.contains(where: { $0.id == meetingID }) else {
            await refreshMeetings()
            return
        }
        do {
            let latest = try await token.runtime.library.loadMeeting(meetingID)
            let isPlayable = await hasPlayableAudio(
                meetingID,
                in: token.runtime
            )
            guard meetingRefreshIsCurrent(token) else { return }
            meetings = MeetingListSnapshot.replacing(latest, in: meetings)
            if isPlayable {
                meetingsWithAudio.insert(meetingID)
            } else {
                meetingsWithAudio.remove(meetingID)
            }
            invalidateDemoDataStatusAfterLibraryChange()
        } catch {
            guard meetingRefreshIsCurrent(token) else { return }
            await refreshMeetings()
        }
    }

    // MARK: - Aufnahme

    /// Reads existing decisions only. This path is safe during launch and must
    /// never cause a TCC prompt or prepare a system-audio source.
    func refreshRecordingPermissionStatus() {
        recordingPermissions = RecordingAudioPermissionState(
            microphone: recordingPermissionClient.microphoneStatus(),
            systemAudio: reusableCachedSystemAudioPermission()
                ?? .notDetermined
        )
        recordingPermissionDefaults.removeObject(
            forKey: Self.legacyProtectedMicrophoneUIDDefaultsKey
        )
    }

    /// Requests access only after an explicit user action. A reusable
    /// code-identity-bound system-audio decision avoids probing that source
    /// again unless the caller deliberately forces a recheck.
    func requestRecordingPermissions(forceSystemAudioProbe: Bool = false) async {
        guard !isResolvingRecordingPermissions,
              !isRecording,
              !isStartingRecording else {
            return
        }
        isResolvingRecordingPermissions = true
        defer { isResolvingRecordingPermissions = false }
        if !forceSystemAudioProbe,
           let cachedSystemStatus = reusableCachedSystemAudioPermission() {
            recordingPermissions = RecordingAudioPermissionState(
                microphone: await recordingPermissionClient.requestMicrophone(),
                systemAudio: cachedSystemStatus
            )
        } else {
            recordingPermissions = await recordingPermissionClient
                .requestRecordingAccess()
            cacheSystemAudioPermission(recordingPermissions.systemAudio)
        }
        recordingPermissionDefaults.removeObject(
            forKey: Self.legacyProtectedMicrophoneUIDDefaultsKey
        )
    }

    private func reusableCachedSystemAudioPermission() -> AudioPermissionStatus? {
        RecordingPermissionCache.reusableStatus(
            rawStatus: recordingPermissionDefaults.string(
                forKey: Self.systemAudioPermissionDefaultsKey
            ),
            cachedIdentity: recordingPermissionDefaults.string(
                forKey: Self.systemAudioPermissionIdentityDefaultsKey
            ),
            currentIdentity: recordingPermissionIdentity()
        )
    }

    private func cacheSystemAudioPermission(_ status: AudioPermissionStatus) {
        recordingPermissionDefaults.set(
            status.rawValue,
            forKey: Self.systemAudioPermissionDefaultsKey
        )
        if let identity = recordingPermissionIdentity() {
            recordingPermissionDefaults.set(
                identity,
                forKey: Self.systemAudioPermissionIdentityDefaultsKey
            )
        } else {
            recordingPermissionDefaults.removeObject(
                forKey: Self.systemAudioPermissionIdentityDefaultsKey
            )
        }
    }
    func startRecording(title overrideTitle: String? = nil) async {
        await beginRecording(.newMeeting(title: overrideTitle))
    }

    /// "Continue recording" (F7): nimmt WEITERE unveränderliche Spuren in
    /// ein bestehendes Meeting auf. Angehangene Spuren laufen auf der
    /// Meeting-Zeitachse nach der laengsten bestehenden Aufnahme weiter;
    /// der Final-ASR-Lauf verschiebt sie in absolute Meeting-Zeit. Eine
    /// hart abgestuerzte angehangene Aufnahme wird von Recovery genau wie
    /// eine frische adoptiert.
    func continueRecording(in meetingID: MeetingID) async {
        await beginRecording(.existingMeeting(meetingID))
    }

    // MARK: - Recording-time template pinning (per-recording choice)

    /// Catalog entries offered by the recording dock's template picker.
    var recordingTemplateOptions: [ResolvedTemplateEntry] {
        TemplateCatalogStore().load().resolvedEntries()
    }

    /// The global default's NAME, shown when nothing is pinned.
    var recordingDefaultTemplateName: String {
        TemplateCatalogStore().load().resolvedDefault().name
    }

    /// Name shown in the strip: pinned choice if any, else the default.
    var recordingActiveTemplateName: String {
        guard let id = recordingPinnedTemplateID,
              let template = TemplateRenderRequest.template(for: id) else {
            return recordingDefaultTemplateName
        }
        return template.name
    }

    /// Dock choice, also applied live while a NEW-meeting recording runs
    /// (mid-recording switch): the pin on the created meeting updates so
    /// subsequent report runs use the latest choice. Continue/append
    /// recordings never write a pin.
    func selectRecordingTemplate(_ templateID: String?) async {
        guard !recordingContinuesExistingMeeting else { return }
        recordingTemplateChoice.choose(templateID)
        guard isRecording,
              let meetingID = recordingMeetingID,
              let runtime else { return }
        do {
            _ = try await runtime.library.setPinnedTemplate(
                templateID,
                for: meetingID
            )
            await refreshMeetings()
        } catch {
            report(AppModel.message("The template could not be pinned.", error))
        }
    }

    private enum RecordingTarget {
        case newMeeting(title: String?)
        case existingMeeting(MeetingID)
    }

    private func beginRecording(_ target: RecordingTarget) async {
        guard canStartRecording,
              let runtime,
              recordingStartState.begin() else { return }
        liveTasks.cancelAndDiscard()
        let languageSelection = transcriptionLanguageSelection
        // Fuer die ganze Aufnahme gepinnt: eine spaetere Aenderung in den
        // Einstellungen (waehrend der Aufnahme ohnehin gesperrt, siehe
        // `canChangeTranscriptionModels`) darf diesen Lauf nicht mehr treffen.
        let plan = currentTranscriptionPlan()
        dismissNotice()
        recordingTemplateChoice.beginNewMeeting()

        do {
            try await nativeGemmaRecordingBarrier.acquire()
            nativeGemmaRecordingBarrierIsHeld = true
        } catch NativeGemmaCoordinatorError.gateUnavailable {
            _ = recordingStartState.fail()
            report(
                "The recording could not be started because Steno could not establish its local model safety gate."
            )
            return
        } catch {
            _ = recordingStartState.fail()
            report(Self.message(
                "The recording could not be started because the local model helper could not be stopped safely.",
                error
            ))
            return
        }

        let micStatus = await recordingPermissionClient.requestMicrophone()
        recordingPermissions = RecordingAudioPermissionState(
            microphone: micStatus,
            systemAudio: recordingPermissions.systemAudio,
            systemAudioError: recordingPermissions.systemAudioError
        )
        guard micStatus == .authorized else {
            _ = recordingStartState.fail()
            report("No microphone access. Allow it in System Settings under Privacy & Security.")
            await releaseNativeGemmaRecordingBarrierAfterCapture()
            return
        }
        do {
            let discovery = await refreshMicrophoneDiscovery()
            // Pin exactly the selected input when the user clicks Record.
            // The system-audio source starts first and may rebuild Core Audio's
            // graph, but it must not change which physical mic this recording
            // will accept. There is deliberately no default-device fallback.
            let recordingMicrophone = try RecordingMicrophoneSelection.resolve(
                mode: recordingMicrophoneMode,
                discovery: discovery
            )
            let appendedTimelineOffset: TimeInterval
            let meeting: Meeting
            switch target {
            case let .newMeeting(titleOverride):
                let title = titleOverride ?? Self.defaultMeetingTitle()
                meeting = try await runtime.library.createMeeting(
                    title: title,
                    status: .recording,
                    sourceLocale: try languageSelection.meetingSourceLocale(),
                    transcriptionPlan: plan
                )
                // Template pinning is a NEW-meeting concept: the dock
                // choice lands on the freshly created meeting. Not
                // choosing leaves metadata untouched (identical flow as
                // before the feature).
                if let pinnedID = recordingPinnedTemplateID {
                    _ = try? await runtime.library.setPinnedTemplate(
                        pinnedID,
                        for: meeting.id
                    )
                }
                appendedTimelineOffset = 0
            case let .existingMeeting(meetingID):
                let existing = try await runtime.library.loadMeeting(meetingID)
                // Continue/append NEVER overrides an existing note's
                // template pin; the dock merely shows it.
                recordingTemplateChoice.beginExistingMeeting(
                    pinnedTemplateID: existing.metadata?.pinnedTemplateID
                )
                guard existing.status != .recording else {
                    report("This meeting is already recording.")
                    _ = recordingStartState.fail()
                    await releaseNativeGemmaRecordingBarrierAfterCapture()
                    return
                }
                // Die angehangene Aufnahme beginnt nach dem laengsten
                // bestehenden Ende; Live-Zeilen und Final-ASR landen auf
                // dieser absoluten Meeting-Zeit.
                appendedTimelineOffset = AppendedTimeline.timelineEnd(
                    of: try await runtime.library.listMediaAssets(
                        meetingID: meetingID
                    )
                )
                meeting = try await runtime.library.updateMeetingStatus(
                    meetingID,
                    to: .recording
                )
            }
            recordingStartState.didCreateMeeting(meeting.id)
            // Capture INNERHALB des Meeting-Ordners: nach kill -9 liegen die
            // Spuren in der Bibliothek und werden beim nächsten Start
            // adoptiert, statt in einem Temp-Verzeichnis zu stranden.
            let captureDirectory = await runtime.library.layout
                .captureDirectory(meeting.id)
            let session = RecordingSession(
                meetingID: meeting.id,
                library: runtime.library,
                outputDirectory: captureDirectory,
                microphoneSource: MicRecorder(
                    selectedDeviceUID: recordingMicrophone.uid
                ),
                systemAudioSource: SystemAudioRecorder()
            )
            try await session.start(
                silenceAutoStop: PlatformPreferences.silenceAutoStopConfig()
            )

            recordingPermissions = RecordingAudioPermissionState(
                microphone: micStatus,
                systemAudio: .authorized
            )
            cacheSystemAudioPermission(.authorized)

            self.session = session
            microphoneStatus = await session.status(for: .microphone)
            recordingMeetingID = meeting.id
            // Die Auswahl folgt der Aufnahme: Sonst zeigt die Seitenleiste
            // ein anderes Meeting als das, in das gerade aufgenommen wird.
            selectedMeetingID = meeting.id
            recordingStartedAt = Date()
            isRecording = true

            // External-capture polling is pointless while we record; an
            // episode fired now would be suppressed anyway.
            pauseMeetingDetectionMonitor()
            liveTranscriptFeed = LiveTranscriptFeed()
            liveTranscriptRows = []

            // F8: Bei Automatic startet die Live-Lane mit der zuletzt
            // ausdruecklich gewaehlten Sprache (bzw. dem deterministischen
            // Speech-Fallback). Der Detektor entscheidet einmalig und
            // startet die Lanes neu; manuelle Wechsel waehrend der
            // Aufnahme greifen ueber activeLiveLaneLocale.
            let liveLaneLocale = Self.startLocale(
                for: languageSelection,
                lastUsedExplicitIdentifier: languagePreferences.lastUsedExplicitIdentifier,
                availableLocales: availableLocales
            )
            activeLiveLaneLocale = liveLaneLocale
            recordingLanguageStartLocaleIdentifier = liveLaneLocale.identifier
            recordingDetectedLocaleIdentifier = nil
            hasRestartedLiveLanesForDetectedLanguage = false
            recordingLastSelectedLocaleIdentifier = nil
            recordingManualLocaleIdentifier = nil
            languageDetectionSession = languageSelection.selectsAutomatic
                ? LanguageDetectionSession(
                    startLocaleIdentifier: liveLaneLocale.identifier,
                    isSupported: Self.detectedLanguageSupportPredicate(
                        availableLocales
                    ),
                    now: recordingStartedAt ?? Date()
                )
                : nil

            for track in AudioTrack.allCases {
                let stream = try await session.liveAudioEvents(for: track)
                do {
                    let provider = try transcriptionRegistry.resolve(
                        plan.liveProviderID,
                        for: Self.assetKind(for: track)
                    )
                    liveTasks.append(makeLiveTask(
                        track: track,
                        stream: stream,
                        provider: provider,
                        locale: liveLaneLocale,
                        timelineBaseOffset: appendedTimelineOffset
                    ))
                } catch {
                    // Live-Transkription ist ein Komfortpfad: ein nicht
                    // installiertes oder nicht registriertes Modell darf die
                    // Aufnahme nicht anhalten, die Originalspur laeuft weiter.
                    report(
                        "No live transcript (\(track.rawValue)): \(error.localizedDescription). Audio recording continues.",
                        isError: false
                    )
                }
            }
            startLevelPolling(session: session)
            await refreshMeetings()
            recordingStartState.succeed()
        } catch {
            if let audioError = error as? AudioRecordingError,
               audioError == .systemAudioPermissionDenied {
                recordingPermissions = RecordingAudioPermissionState(
                    microphone: micStatus,
                    systemAudio: .denied
                )
                cacheSystemAudioPermission(.denied)
            }
            let failedMeetingID = recordingStartState.fail()
            report(Self.message("The recording could not be started.", error))
            await abortRecordingCleanup()
            if let failedMeetingID {
                _ = try? await runtime.library.updateMeetingStatus(
                    failedMeetingID,
                    to: .interrupted
                )
            }
            await refreshMeetings()
        }
    }

    func stopRecording() async {
        if let recordingStopTask {
            await recordingStopTask.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performStopRecording()
        }
        recordingStopTask = task
        await task.value
        recordingStopTask = nil
    }

    private func performStopRecording() async {
        guard let runtime, let session, let meetingID = recordingMeetingID else { return }
        let tasks = liveTasks.takeForStop()
        var stopFailed = false
        do {
            levelTask?.cancel()
            levelTask = nil
            let result = try await session.stop()
            if result.stopReason != .requested,
               let error = await session.lastError() {
                report(error.localizedDescription)
            }

            if let notesSession = notesSessions[meetingID] {
                await notesSession.flush()
                if let error = notesSession.errorMessage {
                    report("The notes could not be saved. (\(error))")
                }
            }

            // Live-Ergebnisse einsammeln und als vorläufige Revision sichern.
            var outputs: [TranscriptOutput] = []
            for task in tasks {
                if let output = await task.value {
                    outputs.append(output)
                }
            }
            if outputs.contains(where: { !$0.blocks.isEmpty }) {
                let revision = TranscriptMapper.revision(
                    from: outputs,
                    meetingID: meetingID,
                    origin: .liveProvisional
                )
                _ = try await runtime.library.appendRevision(revision)
            }

            selectedMeetingID = meetingID
        } catch {
            stopFailed = true
            for task in tasks {
                task.cancel()
            }
            report(Self.message("The recording could not be stopped cleanly.", error))
        }

        let followUp = RecordingStopFollowUp.make(stopFailed: stopFailed)
        if let status = followUp.meetingStatusCorrection {
            _ = try? await runtime.library.updateMeetingStatus(
                meetingID,
                to: status
            )
        }
        // F8: Ein entschiedenes Erkennungsergebnis wird mit dem Final-ASR-
        // Job gepinnt (Start- und erkannte Sprache; die erkannte bleibt
        // eine Schätzung mit origin .estimated, nie eine Nutzerwahl).
        let languageDetectionPin = recordingDetectedLocaleIdentifier.map {
            TranscriptionLanguageDetectionPin(
                startLocaleIdentifier: recordingLanguageStartLocaleIdentifier
                    ?? $0,
                detectedLocaleIdentifier: $0
            )
        }
        for kind in followUp.jobKinds {
            do {
                let meeting = try await runtime.library.loadMeeting(meetingID)
                let job = kind == .finalASR
                    ? Self.finalASRJob(
                        for: meeting,
                        languageDetection: languageDetectionPin,
                        lastSelectedLocaleIdentifier:
                            recordingLastSelectedLocaleIdentifier
                    )
                    : Job(
                        kind: kind,
                        meetingID: meetingID,
                        importGenerationID: meeting.processingGenerationID
                    )
                try await runtime.jobStore.enqueue(job)
                noteJobEnqueued(for: meetingID)
            } catch {
                // Ein fehlgeschlagener Folgelauf darf die Aufnahme nicht
                // als gescheitert markieren: der Fehler wird gemeldet und
                // der naechste Lauf versucht es erneut.
                report(Self.message("A follow-up run could not be scheduled.", error))
            }
        }
        self.session = nil
        isRecording = false
        recordingMeetingID = nil
        recordingStartedAt = nil
        microphoneStatus = nil
        liveTranscriptFeed.clearVolatile()
        liveTranscriptRows = liveTranscriptFeed.rows
        activeLiveLaneLocale = nil
        languageDetectionSession = nil
        hasRestartedLiveLanesForDetectedLanguage = false
        recordingLastSelectedLocaleIdentifier = nil
        recordingManualLocaleIdentifier = nil
        // One-shot semantics: the dock choice applies to exactly one
        // recording and returns to the global default afterwards.
        recordingTemplateChoice.resetAfterStop()
        await refreshMeetings()

        // Recording is over: external-capture detection becomes
        // actionable again.
        resumeMeetingDetectionMonitor()
        await releaseNativeGemmaRecordingBarrierAfterCapture()
    }

    private func abortRecordingCleanup() async {
        levelTask?.cancel()
        levelTask = nil
        liveTasks.cancelAndDiscard()
        if let session { _ = try? await session.stop() }
        session = nil
        isRecording = false
        recordingMeetingID = nil
        recordingStartedAt = nil
        microphoneStatus = nil
        activeLiveLaneLocale = nil
        languageDetectionSession = nil
        hasRestartedLiveLanesForDetectedLanguage = false
        recordingLastSelectedLocaleIdentifier = nil
        recordingManualLocaleIdentifier = nil
        recordingTemplateChoice.resetAfterStop()

        // Recording is over: external-capture detection becomes
        // actionable again.
        resumeMeetingDetectionMonitor()
        await releaseNativeGemmaRecordingBarrierAfterCapture()
    }

    private func releaseNativeGemmaRecordingBarrierAfterCapture() async {
        guard nativeGemmaRecordingBarrierIsHeld else { return }
        do {
            try await nativeGemmaRecordingBarrier.release()
            nativeGemmaRecordingBarrierIsHeld = false
        } catch {
            // Keep the held flag set. Native Gemma then remains unavailable until restart.
            report(Self.message(
                "The local model helper remains disabled because its recording barrier could not be released safely.",
                error
            ))
        }
    }

    func setMicrophonePaused(_ paused: Bool) async {
        guard let session, isRecording else { return }
        await session.setPaused(paused, for: .microphone)
        microphoneStatus = await session.status(for: .microphone)
    }

    /// Verbindet den Live-Audiostrom einer Spur mit einer SpeechAnalyzer-
    /// Sitzung. Die Sitzung entsteht erst mit dem ersten Puffer, weil erst
    /// dieser das tatsächliche Format kennt.
    ///
    /// - Parameters:
    ///   - locale: Start-Sprache der Lane (bei Automatic die letzte
    ///     ausdrückliche Wahl bzw. der deterministische Fallback).
    ///   - timelineBaseOffset: Absoluter Meeting-Zeitpunkt des Aufnahme-
    ///     starts; bei angehangenen Aufnahmen nach dem bestehenden Ende.
    ///     Jedes Ereignis und jede Finalausgabe landet auf
    ///     Basis-Offset + lokaler Segmentzeit.
    private func makeLiveTask(
        track: AudioTrack,
        stream: LiveAudioEventStream,
        provider: any TranscriptionProvider,
        locale: Locale,
        timelineBaseOffset: TimeInterval = 0
    ) -> Task<TranscriptOutput?, Never> {
        // Detached: der Puffer-Konsum darf nicht die MainActor-Isolation des
        // Aufrufers erben, sonst läuft die Audioverarbeitung über den Main
        // Thread.
        return Task.detached { [weak self] in
            var liveSession: (any LiveTranscriptionSession)?
            var eventTask: Task<Void, Never>?
            var segmentOffset: TimeInterval = 0
            var activeLocale = locale
            var outputs: [TranscriptOutput] = []
            do {
                for await audioEvent in stream.stream {
                    switch audioEvent {
                    case let .buffer(owned):
                        let buffer = owned.buffer
                        // F8-Restart-Hook: Hat die automatische Erkennung
                        // entschieden, meldet das Modell den Wunsch-Locale;
                        // weicht er ab, endet die laufende Sitzung sauber
                        // (wie bei einem Capture-Gap) und der nächste
                        // Puffer erzeugt eine neue mit dem erkannten Locale.
                        if let desired = await self?.desiredLiveLaneLocale(),
                           desired != activeLocale {
                            if let liveSession {
                                let output = try await liveSession.finish()
                                await eventTask?.value
                                outputs.append(
                                    output.shifted(
                                        by: timelineBaseOffset + segmentOffset
                                    )
                                )
                            }
                            liveSession = nil
                            eventTask = nil
                            activeLocale = desired
                            await self?.clearLiveVolatileText(for: track)
                        }
                        if liveSession == nil {
                            let created = try await provider.liveSession(
                                format: AudioFormat(buffer.format),
                                locale: activeLocale
                            )
                            let offset = timelineBaseOffset + segmentOffset
                            liveSession = created
                            eventTask = Task { [weak self] in
                                for await event in created.events {
                                    await self?.applyLiveEvent(
                                        event.shifted(by: offset),
                                        track: track
                                    )
                                }
                            }
                        }
                        await liveSession?.append(try AudioBuffer(copying: buffer))
                    case .gapStarted:
                        if let liveSession {
                            let output = try await liveSession.finish()
                            await eventTask?.value
                            outputs.append(output.shifted(by: timelineBaseOffset + segmentOffset))
                        }
                        liveSession = nil
                        eventTask = nil
                        await self?.clearLiveVolatileText(for: track)
                    case let .gapEnded(at):
                        segmentOffset = at
                    }
                }
                if let liveSession {
                    let output = try await liveSession.finish()
                    await eventTask?.value
                    outputs.append(output.shifted(by: timelineBaseOffset + segmentOffset))
                }
                guard !outputs.isEmpty else { return nil }
                return TranscriptOutput(
                    localeIdentifier: outputs[0].localeIdentifier,
                    blocks: outputs.flatMap(\.blocks).sorted { $0.start < $1.start }
                )
            } catch {
                await self?.reportLiveError(error, track: track)
                eventTask?.cancel()
                return nil
            }
        }
    }

    private func clearLiveVolatileText(for track: AudioTrack) {
        liveTranscriptFeed.clearVolatile(for: Self.channel(for: track))
        languageDetectionSession?.clearVolatile()
        liveTranscriptRows = liveTranscriptFeed.rows
    }

    private static func channel(for track: AudioTrack) -> TranscriptionChannel {
        switch track {
        case .microphone: .microphone
        case .system: .system
        }
    }

    func applyLiveEvent(_ event: TranscriptionEvent, track: AudioTrack) {
        consumeEventForLanguageDetection(event)
        liveTranscriptFeed.apply(event, for: Self.channel(for: track))
        liveTranscriptRows = liveTranscriptFeed.rows
    }

    /// Sprache, mit der die Live-Lanes gerade transkribieren sollen. Die
    /// detached Live-Tasks fragen sie pro Puffer ab; eine Aenderung durch
    /// die erkannte Sprache startet ihre Sitzungen beim nächsten Puffer neu.
    func desiredLiveLaneLocale() -> Locale {
        activeLiveLaneLocale ?? locale
    }

    /// Fuettert finalisierten und vorlaeufigen Live-Text in den automatischen
    /// Sprachdetektor. Eine entschiedene, von der Start-Sprache abweichende
    /// Erkennung startet die Lanes GENAU EINMAL mit der erkannten Sprache;
    /// alles Unklare behält die Start-Sprache stillschweigend. Text wird nur
    /// gezaehlt (Funktionswort-Profile), niemals geloggt.
    private func consumeEventForLanguageDetection(
        _ event: TranscriptionEvent
    ) {
        guard !hasRestartedLiveLanesForDetectedLanguage,
              var session = languageDetectionSession else { return }
        let outcome: LanguageDetectionSession.Outcome
        switch event {
        case let .final(output):
            outcome = session.appendFinalized(
                output.blocks.map(\.text).joined(separator: "\n")
            )
        case let .volatile(output):
            outcome = session.replaceVolatile(
                output.blocks.map(\.text).joined(separator: "\n")
            )
        }
        languageDetectionSession = session
        guard case let .detected(code) = outcome else { return }
        restartLiveLanesForDetectedLanguage(code)
    }

    private func restartLiveLanesForDetectedLanguage(_ code: String) {
        hasRestartedLiveLanesForDetectedLanguage = true
        // Der Detektor liefert einen Sprachcode ("de"); erst die Auswahl
        // gegen Speechs Angebot mappt ihn auf eine konkrete Locale.
        let resolved = LocaleResolver.select(
            requested: Locale(identifier: code),
            supported: availableLocales
        )
        recordingDetectedLocaleIdentifier = resolved?.identifier ?? code
        recordingLastSelectedLocaleIdentifier = resolved?.identifier ?? code
        if let resolved, resolved != desiredLiveLaneLocale() {
            activeLiveLaneLocale = resolved
        }
    }

    /// Start-Sprache einer Aufnahme: Bei Automatic die zuletzt ausdruecklich
    /// gewaehlte Sprache, solange Speech sie noch anbietet, sonst Speechs
    /// deterministischer Fallback. Ohne Automatic bleibt die gewaehlte
    /// (aufgeloeste) Sprache.
    static func startLocale(
        for selection: TranscriptionLanguageSelection,
        lastUsedExplicitIdentifier: String?,
        availableLocales: [Locale]
    ) -> Locale {
        let fallback = selection.locale
        guard selection.selectsAutomatic else { return fallback }
        guard let identifier = AutomaticStartLanguageResolver
            .startLocaleIdentifier(
                lastUsedExplicit: lastUsedExplicitIdentifier,
                supported: availableLocales
            )
        else { return fallback }
        return Locale(identifier: identifier)
    }

    /// Unterstuetzungspraedikat fuer erkannte Sprachcodes: Nur Sprachen,
    /// die Speech auch transkribieren kann, loesen einen Lane-Restart aus.
    static func detectedLanguageSupportPredicate(
        _ locales: [Locale]
    ) -> @Sendable (String) -> Bool {
        let supportedLanguageCodes = Set(locales.compactMap {
            $0.language.languageCode?.identifier.lowercased()
        })
        return { code in
            supportedLanguageCodes.contains(code.lowercased())
        }
    }

    // MARK: - Mid-recording language switch (F11)

    /// Whether the RecordingStrip language picker may act right now.
    var canChangeRecordingLanguage: Bool {
        isRecording && !isStartingRecording
    }

    /// What the mid-recording picker shows as the current selection: the
    /// latest manual pick wins over a decisive detection, otherwise the
    /// locale the live lanes actually run with (the detected-so-far state
    /// while Automatic is selected).
    var recordingLanguageSelectionID: String {
        recordingManualLocaleIdentifier
            ?? recordingDetectedLocaleIdentifier
            ?? desiredLiveLaneLocale().identifier
    }

    /// Menu label for the picker. Under Automatic it names the current best
    /// guess until the user overrides manually.
    var recordingLanguagePickerTitle: String {
        let name = localizedLanguageName(
            Locale(identifier: recordingLanguageSelectionID)
        )
        guard transcriptionLanguageSelection.selectsAutomatic,
              recordingManualLocaleIdentifier == nil else { return name }
        return name + " (" + String(localized: "automatic") + ")"
    }

    /// Manual language switch DURING a recording (F11). Unlimited by design:
    /// unlike automatic detection, manual picks never pass a restart-once
    /// guard. The choice becomes the desired live-lane locale, so each lane's
    /// next buffer drains its volatile content and restarts with the new
    /// locale; already finalized rows keep their original language.
    ///
    /// Pending automatic detection is cancelled for the rest of this
    /// recording (`languageDetectionSession = nil`), so detection and manual
    /// override cannot fight: an undecided detector stays silent (keptStart)
    /// and the manual choice drives both live lanes and the final ASR job.
    /// The app-wide persisted preference is deliberately untouched; the
    /// switch applies to this recording only.
    func selectRecordingLanguage(_ identifier: String) {
        guard canChangeRecordingLanguage else { return }
        let requested = Locale(identifier: identifier)
        guard !LocaleResolver.identifiersAreEquivalent(
            requested,
            .transcriptionAutomatic
        ) else { return }
        // Resolve against Speech's offer exactly like a detected code would
        // be; an unsupported identifier cannot drive a live session.
        guard let resolved = LocaleResolver.select(
            requested: requested,
            supported: availableLocales
        ) else { return }
        recordingManualLocaleIdentifier = resolved.identifier
        recordingLastSelectedLocaleIdentifier = resolved.identifier
        if resolved != desiredLiveLaneLocale() {
            activeLiveLaneLocale = resolved
        }
        languageDetectionSession = nil
    }

    private func reportLiveError(_ error: any Error, track: AudioTrack) {
        // Live-Transkription ist ein Komfortpfad: ihr Ausfall beendet die
        // Aufnahme nicht, die Originalspuren laufen weiter.
        report("Live transcript (\(track.rawValue)) interrupted: \(error.localizedDescription)")
    }

    private func startLevelPolling(session: RecordingSession) {
        levelTask = Task { [weak self] in
            while !Task.isCancelled {
                if await session.state.isTerminal {
                    await self?.finishAfterSelfStop(session)
                    return
                }
                var updated: [AudioTrack: AudioLevels] = [:]
                for track in AudioTrack.allCases {
                    updated[track] = await session.levels(for: track)
                }
                let microphoneStatus = await session.status(for: .microphone)
                self?.levels = updated
                self?.applyMicrophoneStatus(microphoneStatus)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func finishAfterSelfStop(_ observedSession: RecordingSession) async {
        guard session === observedSession, isRecording else { return }
        await stopRecording()
    }

    private func applyMicrophoneStatus(_ status: RecordingTrackStatus?) {
        let previous = microphoneStatus
        microphoneStatus = status
        guard let previous, let status else { return }
        let wasUnavailable = !previous.deviceAvailable || previous.sourceStalled
        let isUnavailable = !status.deviceAvailable || status.sourceStalled
        if !wasUnavailable, isUnavailable {
            let name = status.deviceName ?? "Microphone"
            let reason = status.deviceAvailable
                ? "stopped responding"
                : "disconnected"
            report(
                "\(name) \(reason). The microphone track is paused; system audio continues.",
                isError: false
            )
        } else if wasUnavailable,
                  !isUnavailable,
                  !status.userPaused {
            let name = status.deviceName ?? "Microphone"
            report(
                "\(name) reconnected. Microphone recording resumed.",
                isError: false
            )
        }
    }

    // MARK: - Import

    func importAudioFile(at url: URL) async {
        guard let runtime else { return }
        do {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            let file = try AVAudioFile(forReading: url)
            let sampleRate = file.fileFormat.sampleRate
            let duration = sampleRate > 0
                ? Double(file.length) / sampleRate
                : 0
            let meeting = try await runtime.library.createMeeting(
                title: url.deletingPathExtension().lastPathComponent,
                status: .processing
            )
            _ = try await runtime.library.registerMediaAsset(
                for: meeting.id,
                sourceURL: url,
                kind: .imported,
                sampleRate: sampleRate,
                duration: duration
            )
            try await runtime.jobStore.enqueue(
                Job.finalASR(for: meeting)
            )
            noteJobEnqueued(for: meeting.id)
            selectedMeetingID = meeting.id
            await refreshMeetings()
        } catch let LibraryError.duplicateProvenance(_, existingMeetingID) {
            report("This file has already been imported.")
            selectedMeetingID = existingMeetingID
        } catch {
            report(Self.message("The import failed.", error))
        }
    }

    // MARK: - Detail

    /// Weckt eine offene MeetingDetailView, wenn fuer ihr Meeting ein Job
    /// eingereiht wird, ohne dass in der Detailansicht selbst geklickt wurde
    /// - nach Aufnahmestopp, Import, einer erneuten Anforderung aus der
    /// Seitenleiste oder einem Retry. Kein Dauer-Polling: Die Detailansicht
    /// liest nur den Zaehler fuer ihr eigenes Meeting und startet ihre
    /// Beobachtungsschleife gezielt neu, wenn er sich aendert.
    private(set) var meetingJobActivity: [MeetingID: UInt64] = [:]

    func noteJobEnqueued(for meetingID: MeetingID) {
        meetingJobActivity[meetingID, default: 0] &+= 1
    }

    func transcript(for meetingID: MeetingID) async -> TranscriptRevision? {
        guard let runtime else { return nil }
        return try? await runtime.library.loadCurrentRevision(meetingID: meetingID)
    }

    func speakerPresentationContext(
        for meetingID: MeetingID
    ) async -> SpeakerPresentationContext {
        guard let runtime else { return .empty }
        let assets = (try? await runtime.library.listMediaAssets(
            meetingID: meetingID
        )) ?? []
        return SpeakerPresentationContext(channelsByNamespace: Dictionary(
            uniqueKeysWithValues: assets.map {
                ($0.id.description, $0.kind.rawValue)
            }
        ))
    }

    /// Ende der Meeting-Zeitachse. Mikro und System laufen innerhalb einer
    /// Aufnahme parallel (das Maximum der Sitzung), angehangene Aufnahmen
    /// verlaengern die Zeitachse dagegen additiv - deshalb das Timeline-
    /// Ende und nicht die laengste Einzelspur.
    func duration(for meetingID: MeetingID) async -> TimeInterval? {
        guard let runtime else { return nil }
        let assets = (try? await runtime.library.listMediaAssets(
            meetingID: meetingID
        )) ?? []
        guard !assets.isEmpty else { return nil }
        return AppendedTimeline.timelineEnd(of: assets)
    }

    func jobs(for meetingID: MeetingID) async -> [StenoDomain.Job] {
        guard let runtime else { return [] }
        guard let meeting = try? await runtime.library.loadMeeting(meetingID) else {
            return []
        }
        let all = (try? await runtime.jobStore.list()) ?? []
        return all.filter {
            $0.meetingID == meetingID
                && $0.processingGenerationID == meeting.processingGenerationID
        }
    }

    private static func defaultMeetingTitle() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return String(localized: "Recording \(formatter.string(from: Date()))")
    }

    /// Final-ASR job for a finished recording. Precedence for the pinned
    /// locale (F11): the LAST mid-recording language decision - a manual
    /// RecordingStrip pick or a decisive automatic detection. Text spoken
    /// before a switch was recognized in its ORIGINAL language; like the
    /// legacy behaviour, the final run re-transcribes in one language and
    /// users can Transcribe Again afterwards. The detection pin (start plus
    /// estimated locale) is still carried when present so a rerun can
    /// reproduce the decision context; without any mid-recording decision,
    /// only an explicitly chosen meeting source locale pins.
    static func finalASRJob(
        for meeting: Meeting,
        languageDetection: TranscriptionLanguageDetectionPin?,
        lastSelectedLocaleIdentifier: String?
    ) -> Job {
        if let lastSelectedLocaleIdentifier {
            return .finalASR(
                meetingID: meeting.id,
                providerID: meeting.transcriptionPlan?.finalProviderID ?? .apple,
                localeIdentifier: lastSelectedLocaleIdentifier,
                processingGenerationID: meeting.processingGenerationID,
                languageDetection: languageDetection
            )
        }
        if let languageDetection,
           let detected = languageDetection.detectedLocaleIdentifier {
            return .finalASR(
                meetingID: meeting.id,
                providerID: meeting.transcriptionPlan?.finalProviderID ?? .apple,
                localeIdentifier: detected,
                processingGenerationID: meeting.processingGenerationID,
                languageDetection: languageDetection
            )
        }
        return .finalASR(for: meeting)
    }
}
