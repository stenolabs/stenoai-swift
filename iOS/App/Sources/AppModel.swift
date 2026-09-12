import Foundation
import Observation
import StenoAudioCore
import StenoDiarization
import StenoDemo
import StenoDomain
import StenoIdentity
import StenoIntelligence
import StenoLibrary
import StenoPipeline
import StenoTranscription
import StenoiOSAudio

/// A small seam around the demo actor so the app model can test publication
/// ordering without opening the bundled dataset or a user's library.
struct DemoDataLifecycleClient: Sendable {
    let status: @Sendable () async throws -> DemoLibraryStatus
    let install: @Sendable () async throws -> Void
    let replace: @Sendable (DemoReplacementPolicy) async throws -> DemoLifecycleResult
    let remove: @Sendable () async throws -> DemoLifecycleResult

    static func live(
        library: Library,
        folders: FolderStore
    ) throws -> DemoDataLifecycleClient {
        let seeder = try DemoLibrarySeeder(library: library, folders: folders)
        return DemoDataLifecycleClient(
            status: { try await seeder.status() },
            install: { try await seeder.install() },
            replace: { policy in try await seeder.replace(policy: policy) },
            remove: { try await seeder.remove() }
        )
    }
}

/// Owns the library and the pipeline for the whole process.
///
/// Process-wide rather than per scene: on iPad two windows of the app must
/// show the same library and the same running jobs, and closing one window
/// must not tear the pipeline down.
@MainActor
@Observable
final class AppModel {
    typealias ReviewActionPerformer = @MainActor (
        MeetingReviewController.Action,
        IdentityCluster,
        MeetingReviewData,
        MeetingID,
        Library
    ) async throws -> MeetingReviewData
    typealias ReviewSnapshotLoader = @MainActor (
        MeetingID,
        Library
    ) async throws -> MeetingReviewSnapshot
    typealias PersonsLoader = @MainActor (Library) async throws -> [Person]
    typealias MeetingTrasher = @Sendable (Library, MeetingID) async throws -> URL?
    typealias DemoDataLifecycleClientFactory = @Sendable (
        Library,
        FolderStore
    ) throws -> DemoDataLifecycleClient

    /// The shared, meeting-tagged review state read by every scene. A window
    /// never keeps its own writable meeting/review pair, so a late action for
    /// one meeting cannot replace another meeting and two windows always
    /// observe the same publication.
    struct MeetingReviewPublication {
        let generation: UInt64
        let meeting: Meeting
        let review: MeetingReviewData?
    }

    struct ReviewUpdate {
        let review: MeetingReviewData
        let meeting: Meeting
    }

    enum ModelJobRecoveryIntent: Equatable {
        case speech(locale: Locale)
        case diarization
    }

    private struct RuntimeRecoveryIntent {
        var speechLocaleIdentifiers: Set<String> = []
        var retriesDiarization = false

        static let restartOnly = RuntimeRecoveryIntent()

        init() {}

        init(_ modelRecovery: ModelJobRecoveryIntent) {
            switch modelRecovery {
            case .speech(let locale):
                speechLocaleIdentifiers = [locale.identifier]
            case .diarization:
                retriesDiarization = true
            }
        }

        mutating func merge(_ other: RuntimeRecoveryIntent) {
            speechLocaleIdentifiers.formUnion(other.speechLocaleIdentifiers)
            retriesDiarization = retriesDiarization || other.retriesDiarization
        }
    }

    private(set) var meetings: [Meeting] = []
    private(set) var removedMeetingIDs: Set<MeetingID> = []
    private(set) var folders: [Folder] = []
    private(set) var startupState = IOSStartupState.opening
    private var meetingLibraryIssue: IOSLibraryIssue?
    private var folderLibraryIssue: IOSLibraryIssue?
    private(set) var startupWarnings: [IOSStartupWarning] = []
    private(set) var actionNotice: IOSActionNotice?
    /// True while a background-time expiration deferred pipeline work to
    /// "finishes when you return"; drives the sidebar notice.
    var backgroundProcessingDeferred = false
    @ObservationIgnored var backgroundProcessingCoordinator:
        BackgroundProcessingCoordinator?

    var libraryIssues: [IOSLibraryIssue] {
        [meetingLibraryIssue, folderLibraryIssue].compactMap { $0 }
    }

    /// Read-only compatibility for call sites that can show only one issue.
    var libraryIssue: IOSLibraryIssue? { libraryIssues.first }

    /// Read-only compatibility for older view and test call sites. New code
    /// must write one of the typed categories instead.
    var startupFailure: String? {
        if case .failed(let failure) = startupState {
            return failure.compatibilityMessage
        }
        return libraryIssue?.compatibilityMessage
            ?? actionNotice?.compatibilityMessage
    }

    /// Read-only compatibility projection for the existing top banner.
    var startupWarning: String? {
        guard !startupWarnings.isEmpty else { return nil }
        return startupWarnings
            .map(\.compatibilityMessage)
            .joined(separator: " ")
    }

    var isReady: Bool { startupState == .ready }
    private(set) var demoDataStatus: DemoLibraryStatus?
    private(set) var demoDataOperation: DemoDataOperation?
    private(set) var demoDataResult: DemoLifecycleResult?
    private(set) var demoDataError: String?
    private(set) var demoDataStatusError: String?
    private(set) var demoDataReconciliationError: String?

    // Die externe Dokument-URL lebt nur im vorbereitenden Task, bis StenoKit
    // den privaten Snapshot angelegt hat. Danach speichert die App nur noch
    // Vorschau und Session-ID.
    var meetingTransferImportState: MeetingTransferImportFlowState?
    var meetingTransferSceneID: MeetingTransferSceneID?
    var selectedMeetingID: MeetingID?
    var selectedMeetingSceneID: MeetingTransferSceneID?
    @ObservationIgnored var meetingTransferClient: MeetingTransferImportClient?
    @ObservationIgnored var meetingTransferOperation: Task<Void, Never>?
    @ObservationIgnored var meetingTransferOperationID = UUID()
    @ObservationIgnored var pendingMeetingTransferURL: URL?
    @ObservationIgnored var pendingMeetingTransferSceneID: MeetingTransferSceneID?
    @ObservationIgnored var livingMeetingTransferSceneIDs: [
        MeetingTransferSceneID
    ] = []
    @ObservationIgnored var hasRegisteredMeetingTransferScene = false
    @ObservationIgnored var meetingTransferCancellationRequested = false
    @ObservationIgnored var ownedMeetingTransferSession: MeetingTransferOwnedSession?
    @ObservationIgnored var committedMeetingTransferResultAwaitingCleanup: MeetingTransferImportResult?
    @ObservationIgnored let meetingTransferSecurityScope: MeetingTransferSecurityScopedResource
    @ObservationIgnored private let meetingTransferClientWasInjected: Bool
    @ObservationIgnored private let meetingListLoader: (@MainActor @Sendable () async throws -> [Meeting])?

    /// One session controller for the process.
    ///
    /// `AVAudioSession` is shared state; two controllers would both observe
    /// and both activate it, and whichever deactivated last would silently win.
    let audioSession: AudioSessionController

    /// The running recording, owned by the process rather than by a view.
    ///
    /// Recording is a state, not a place. While the view owned it, navigating
    /// to a meeting tore the view down and with it the recording, which is the
    /// one thing this app must never do quietly. It also makes the iPad case
    /// work at all: two windows must show the same run, and closing one must
    /// not end it.
    let recording: RecordingModel

    /// Explicit, persisted transcription language. Never `Locale.current`.
    let language = TranscriptionLanguage()

    /// Apple speech assets for the explicitly selected language.
    let models: IOSModelInstallationState

    /// Optional local speaker separation bundle. Its consent and readiness
    /// are intentionally independent from Apple's speech assets.
    let diarizationModels: IOSModelInstallationState

    /// The user's explicit live/final provider choice. A choice is intent,
    /// not a guarantee of availability; see `isTranscriptionModelInstalled`.
    let transcriptionModels: TranscriptionModelSettings

    /// Resolves a chosen provider ID to a running instance, for both the
    /// pipeline (final ASR) and the live recording path.
    private let injectedTranscriptionRegistry: TranscriptionProviderRegistry?

    /// Wird bei jedem Zugriff aus der aktuellen Wahl gebaut, damit ein
    /// umgelegter Schalter beim naechsten Aufnahmestart wirkt. Die Registry
    /// haelt nur Fabriken, keine geladenen Modelle.
    var transcriptionRegistry: TranscriptionProviderRegistry {
        injectedTranscriptionRegistry ?? .standard(
            modelDirectory: try? LibraryLocation.modelCacheURL(),
            experimentalFeatures: transcriptionModels.experimentalFeatures
        )
    }
    let transcriptionCatalog: TranscriptionModelCatalog

    /// Optional Parakeet bundle. Same shape as `diarizationModels`: its own
    /// coordinator, its own consent, independent of Apple's speech assets.
    let transcriptionModelInstaller: IOSModelInstallationState

    private(set) var runtime: PipelineRuntime?
    private var folderStore: FolderStore?
    /// Monotonically identifies the paired runtime and folder index.
    ///
    /// Folder work crosses actor boundaries. A task therefore must not publish
    /// data it read from a runtime that has since been detached or replaced.
    private var runtimeGeneration: UInt64 = 0
    private var storeGeneration: UInt64 = 0
    private var folderMutationGeneration: UInt64 = 0
    private var meetingRefreshGeneration: UInt64 = 0
    private var folderRefreshGeneration: UInt64 = 0
    private var activeFolderIssueRetryGeneration: UInt64?
    private var folderStateFailure: String?
    private var runtimeTransitionBarrierIsActive = false
    private var activeFolderOperationID: UInt64?
    private var nextFolderOperationID: UInt64 = 0
    private var folderOperationWaiters: [CheckedContinuation<Void, Never>] = []
    private var pendingFolderReload = false
    private var coalescedFolderReloadTask: Task<Void, Never>?
    private var pendingRuntimeRecoveryAfterRecording: RuntimeRecoveryIntent?
    private var bootstrapTask: Task<Void, Never>?
    private var notesSessions: MeetingNotesSessionPool?
    var meetingTransferExportRoots: Set<URL> = []
    private let runtimeChanges = RuntimeChangeSerializer()
    // Not `private`: read and written from `AppModel+Review.swift`, which
    // Swift's file-scoped `private` would otherwise shut out.
    let reviewActionPerformer: ReviewActionPerformer
    let reviewSnapshotLoader: ReviewSnapshotLoader
    let personsLoader: PersonsLoader
    var reviewActionsInFlight: Set<MeetingID> = []
    var reviewErrorsByMeeting: [MeetingID: String] = [:]
    var reviewPublicationsByMeeting: [MeetingID: MeetingReviewPublication] = [:]
    var reviewMutationGenerations: [MeetingID: UInt64] = [:]
    var reviewViewGenerations: [MeetingID: UInt64] = [:]
    var issuedReviewLoadTickets: [MeetingID: UInt64] = [:]
    var acceptedReviewLoadTickets: [MeetingID: UInt64] = [:]
    /// Exact meeting ownership for transcript writes. A second iPad window
    /// fails before its first suspension instead of racing the current parent
    /// check and presenting a generic persistence error.
    var transcriptEditsInFlight: Set<MeetingID> = []
    let beforeTranscriptEditAppend: @Sendable () async -> Void
    private let prepareLibraryBackup: @Sendable (URL, URL) throws -> Void
    private let refreshLanguage: @MainActor @Sendable (
        TranscriptionLanguage
    ) async -> Void
    private let textModelProviderResolver: TextModelProviderResolver
    private let pipelineStarter: @MainActor @Sendable (
        URL,
        Locale,
        @escaping TextModelProviderResolver
    ) async throws -> PipelineRuntime
    private let folderStoreOpener: @Sendable (LibraryLayout) throws -> FolderStore
    private let folderStoreDeletion: @Sendable (
        FolderStore,
        FolderID
    ) async throws -> FolderDeletionResult?
    private let meetingFolderSetter: @Sendable (
        Library,
        Set<MeetingID>,
        FolderID?
    ) async throws -> [Meeting]
    private let meetingTrasher: MeetingTrasher
    private let beforeMeetingFolderSet: @Sendable () async -> Void
    private let beforeRuntimeTransitionDetach: @Sendable () async -> Void
    private let afterRuntimeTransitionBarrierStarts: @Sendable () async -> Void
    private let didRegisterFolderOperationWaiter: @Sendable () -> Void
    private let afterCoalescedFolderReload: @Sendable () async -> Void
    private let beforeRecordingStart: @Sendable () async -> Void
    private let recordingStarter: @MainActor @Sendable (
        RecordingModel,
        Locale,
        Bool
    ) async -> Void
    private let didScheduleCoalescedFolderReload: @Sendable () -> Void
    let runtimeMeetingLoader: @Sendable (Library) async throws -> [Meeting]
    let folderListLoader: @Sendable (FolderStore) async throws -> [Folder]
    private let demoDataClientFactory: DemoDataLifecycleClientFactory
    private let libraryURL: URL
    let meetingTransferTemporaryDirectory: @Sendable () -> URL

    init(
        prepareLibraryBackup: @escaping @Sendable (URL, URL) throws -> Void
            = LibraryBackupPolicy.prepareAndVerify,
        refreshLanguage: @escaping @MainActor @Sendable (
            TranscriptionLanguage
        ) async -> Void = { language in
            await language.refresh()
        },
        textModelProviderResolver: @escaping TextModelProviderResolver =
            TextModelSettings.resolveProvider,
        startPipeline: (@MainActor @Sendable (
            URL,
            Locale,
            @escaping TextModelProviderResolver
        ) async throws -> PipelineRuntime)? = nil,
        folderStoreOpener: @escaping @Sendable (LibraryLayout) throws -> FolderStore
            = FolderStore.open,
        deleteFolder: @escaping @Sendable (
            FolderStore,
            FolderID
        ) async throws -> FolderDeletionResult? = { store, folderID in
            try store.deleteFolder(folderID)
        },
        setMeetingFolders: @escaping @Sendable (
            Library,
            Set<MeetingID>,
            FolderID?
        ) async throws -> [Meeting] = { library, meetingIDs, folderID in
            try library.setMeetingFolders(meetingIDs, folderID: folderID)
        },
        meetingTrasher: @escaping MeetingTrasher = { library, meetingID in
            try library.trashMeeting(meetingID)
        },
        beforeMeetingFolderSet: @escaping @Sendable () async -> Void = {},
        beforeRuntimeTransitionDetach: @escaping @Sendable () async -> Void = {},
        afterRuntimeTransitionBarrierStarts: @escaping @Sendable () async -> Void = {},
        didRegisterFolderOperationWaiter: @escaping @Sendable () -> Void = {},
        afterCoalescedFolderReload: @escaping @Sendable () async -> Void = {},
        beforeRecordingStart: @escaping @Sendable () async -> Void = {},
        recordingStarter: (@MainActor @Sendable (
            RecordingModel,
            Locale,
            Bool
        ) async -> Void)? = nil,
        didScheduleCoalescedFolderReload: @escaping @Sendable () -> Void = {},
        loadMeetings: @escaping @Sendable (Library) async throws -> [Meeting] = {
            library in
            try library.listMeetings()
        },
        loadFolders: @escaping @Sendable (FolderStore) async throws -> [Folder] = {
            store in
            try store.listFolders()
        },
        demoDataClientFactory: @escaping DemoDataLifecycleClientFactory = {
            library, folders in
            try DemoDataLifecycleClient.live(library: library, folders: folders)
        },
        meetingTransferTemporaryDirectory: @escaping @Sendable () -> URL = {
            FileManager.default.temporaryDirectory
        },
        meetingTransferClient: MeetingTransferImportClient? = nil,
        meetingTransferSecurityScope: MeetingTransferSecurityScopedResource = .live,
        meetingListLoader: (@MainActor @Sendable () async throws -> [Meeting])? = nil,
        speechModels: IOSModelInstallationState? = nil,
        diarizationModels: IOSModelInstallationState? = nil,
        transcriptionModels: TranscriptionModelSettings = TranscriptionModelSettings(),
        transcriptionRegistry: TranscriptionProviderRegistry? = nil,
        transcriptionCatalog: TranscriptionModelCatalog = .standard,
        transcriptionModelInstaller: IOSModelInstallationState? = nil,
        beforeTranscriptEditAppend: @escaping @Sendable () async -> Void = {},
        libraryURL: URL = LibraryLocation.libraryURL(),
        reviewActionPerformer: ReviewActionPerformer? = nil,
        reviewSnapshotLoader: ReviewSnapshotLoader? = nil,
        personsLoader: PersonsLoader? = nil
    ) {
        injectedTranscriptionRegistry = transcriptionRegistry
        let modelSettings = transcriptionModels
        let registrySource: @MainActor () -> TranscriptionProviderRegistry = {
            transcriptionRegistry ?? .standard(
                modelDirectory: try? LibraryLocation.modelCacheURL(),
                experimentalFeatures: modelSettings.experimentalFeatures
            )
        }
        let session = AudioSessionController()
        audioSession = session
        recording = RecordingModel(
            session: session,
            transcriptionRegistry: registrySource
        )
        models = speechModels ?? IOSModelInstallationState(
            coordinator: ModelInstallationCoordinator(installers: [
                SpeechAssetInstaller(assets: SystemSpeechAssets()),
            ]),
            consent: .speech()
        )
        self.diarizationModels = diarizationModels ?? Self.makeDiarizationModelState()
        self.transcriptionModels = transcriptionModels
        self.transcriptionCatalog = transcriptionCatalog
        self.transcriptionModelInstaller = transcriptionModelInstaller
            ?? Self.makeTranscriptionModelInstallerState()
        self.beforeTranscriptEditAppend = beforeTranscriptEditAppend
        self.libraryURL = libraryURL
        self.prepareLibraryBackup = prepareLibraryBackup
        self.refreshLanguage = refreshLanguage
        self.textModelProviderResolver = textModelProviderResolver
        pipelineStarter = startPipeline ?? { url, locale, resolver in
            try await AppModel.startLivePipeline(
                at: url,
                locale: locale,
                textModelProviderResolver: resolver,
                transcriptionRegistry: registrySource()
            )
        }
        self.folderStoreOpener = folderStoreOpener
        folderStoreDeletion = deleteFolder
        meetingFolderSetter = setMeetingFolders
        self.meetingTrasher = meetingTrasher
        self.beforeMeetingFolderSet = beforeMeetingFolderSet
        self.beforeRuntimeTransitionDetach = beforeRuntimeTransitionDetach
        self.afterRuntimeTransitionBarrierStarts = afterRuntimeTransitionBarrierStarts
        self.didRegisterFolderOperationWaiter = didRegisterFolderOperationWaiter
        self.afterCoalescedFolderReload = afterCoalescedFolderReload
        self.beforeRecordingStart = beforeRecordingStart
        self.recordingStarter = recordingStarter ?? { [transcriptionModels] recording, locale, wasChosenExplicitly in
            await recording.start(
                locale: locale,
                languageWasChosenExplicitly: wasChosenExplicitly,
                plan: TranscriptionPlan(
                    liveProviderID: transcriptionModels.liveProviderID,
                    finalProviderID: transcriptionModels.finalProviderID
                )
            )
        }
        self.didScheduleCoalescedFolderReload = didScheduleCoalescedFolderReload
        runtimeMeetingLoader = loadMeetings
        folderListLoader = loadFolders
        self.demoDataClientFactory = demoDataClientFactory
        self.meetingTransferTemporaryDirectory = meetingTransferTemporaryDirectory
        self.meetingTransferClient = meetingTransferClient
        meetingTransferClientWasInjected = meetingTransferClient != nil
        self.meetingTransferSecurityScope = meetingTransferSecurityScope
        self.meetingListLoader = meetingListLoader
        self.reviewActionPerformer = reviewActionPerformer ?? { action, cluster, data, meetingID, library in
            try await MeetingReviewController(library: library).perform(
                action,
                on: cluster,
                data: data,
                meetingID: meetingID
            )
        }
        self.reviewSnapshotLoader = reviewSnapshotLoader ?? { meetingID, library in
            try await MeetingReviewAssembler.loadMeetingAndReview(
                library: library,
                meetingID: meetingID
            )
        }
        self.personsLoader = personsLoader ?? { library in
            try await IdentityStore(layout: library.layout).listPersons()
        }
        startBackgroundProcessingCoordinator()
        recording.didBecomeIdle = { [weak self] in
            Task { @MainActor in
                await self?.recordingDidBecomeIdle()
            }
        }
    }

    /// Verifies the local backup boundary, then opens the library and starts
    /// the pipeline.
    ///
    /// Same `startPipeline` as the Mac, including the recovery sweep and the
    /// job recovery, gefolgt von `CaptureRecovery.run`. Beides ist noetig:
    /// der Sweep markiert ein Meeting nur als unterbrochen, erst
    /// `CaptureRecovery` adoptiert die unregistrierten CAF-Dateien als
    /// Originalspuren und reiht den Final-ASR-Lauf ein. Ohne den zweiten
    /// Schritt ueberlebte die Aufnahme den Absturz auf der Platte, blieb
    /// aber unsichtbar - und genau das behauptete dieser Kommentar vorher
    /// bereits, ohne dass der Aufruf existierte.
    ///
    /// Models are no longer downloaded by the providers themselves. iOS uses
    /// separate `ModelInstallationCoordinator` instances and consent records
    /// for Apple speech assets and optional speaker separation. A missing
    /// model never blocks library startup or recording.
    func bootstrap() async {
        // Scene lifecycle calls must not enter between a configuration change
        // and its ordered restart. Model installation likewise owns this gap
        // until it can requeue failed work against a stopped coordinator.
        guard !models.isInstalling,
              !diarizationModels.isInstalling,
              !runtimeChanges.isRunning else { return }
        await startOrJoinBootstrap()
    }

    /// Retries a visible fatal startup failure without the scene-lifecycle
    /// gates used by `bootstrap()`. A retry button must never silently do
    /// nothing because a model or configuration task currently owns a gate.
    func retryStartup() async {
        if let bootstrapTask {
            await bootstrapTask.value
            return
        }
        guard case .failed = startupState else { return }
        await startOrJoinBootstrap()
    }

    private func startOrJoinBootstrap() async {
        if let bootstrapTask {
            await bootstrapTask.value
            return
        }
        guard runtime == nil else { return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performBootstrap()
        }
        bootstrapTask = task
        await task.value
    }

    private func performBootstrap() async {
        defer { bootstrapTask = nil }
        startupState = .opening
        var replacementRuntimeWarnings: [IOSStartupWarning] = []
        await refreshLanguage(language)

        let validationRoot = LibraryLayout(root: libraryURL).transferValidationRoot
        do {
            try prepareLibraryBackup(libraryURL, validationRoot)
        } catch {
            startupState = .failed(.libraryProtection(error.localizedDescription))
            return
        }

        let runtime: PipelineRuntime
        do {
            runtime = try await pipelineStarter(
                libraryURL,
                language.locale,
                textModelProviderResolver
            )
        } catch {
            startupState = .failed(.runtimeOpening(error.localizedDescription))
            return
        }

        self.runtime = runtime
        clearLibraryIssues()
        let folderStoreFailure: String?
        do {
            folderStore = try folderStoreOpener(runtime.library.layout)
            folders = []
            folderStoreFailure = nil
        } catch {
            folderStore = nil
            folders = []
            folderStoreFailure = String(localized: "The folders could not be loaded. (\(error.localizedDescription))")
        }
        advanceRuntimeGeneration()
        advanceStoreGeneration()
        folderStateFailure = folderStoreFailure
        if let folderStoreFailure {
            reportLibraryIssue(.folders(folderStoreFailure))
        }
        if !meetingTransferClientWasInjected {
            meetingTransferClient = MeetingTransferImportClient(
                service: MeetingTransferImportService(
                    library: runtime.library,
                    jobStore: runtime.jobStore
                )
            )
        }
        meetingTransferClientDidBecomeReady()
        let notesSessions = self.notesSessions ?? MeetingNotesSessionPool(
            store: MeetingNotesStore(layout: runtime.library.layout)
        )
        self.notesSessions = notesSessions
        // Gestrandete Capture-Dateien eines harten Abbruchs als
        // Originalspuren adoptieren, wie auf dem Mac
        // (`App/Sources/AppModel.swift`). Fehler bleiben pro Meeting und
        // Datei isoliert, damit alle anderen Spuren weiter adoptiert
        // werden und der Nutzer die Ausnahmen trotzdem sieht.
        do {
            let recovery = try await CaptureRecovery.run(
                library: runtime.library,
                jobStore: runtime.jobStore
            )
            if let message = Self.captureRecoveryFailureMessage(recovery.failures) {
                replacementRuntimeWarnings.append(.captureRecovery(message))
            }
        } catch {
            replacementRuntimeWarnings.append(.captureRecovery(String(localized: "Interrupted recordings could not be inspected. Existing recording files remain stored. (\(error.localizedDescription))")))
        }
        // Without this the record button has nowhere to write, so it stays
        // disabled rather than producing an audio file nobody can find.
        recording.attach(runtime: runtime, notesSessions: notesSessions)
        if let snapshot = runtimeSnapshot() {
            _ = await reloadMeetings(for: snapshot, operation: nil)
        }
        await models.refresh(for: language.locale)
        do {
            _ = try await MissingSpeechModelJobRetrier.requeue(
                jobStore: runtime.jobStore,
                locale: language.locale,
                modelIsReady: models.isReady(for: language.locale) == true
            )
        } catch {
            reportStartupWarning(.missingModelRequeue(error.localizedDescription))
        }
        await diarizationModels.refresh(for: language.locale)
        await transcriptionModelInstaller.refresh(for: language.locale)
        if let message = Self.pipelineStartupWarningMessage(
            for: runtime.startupWarnings
        ) {
            replacementRuntimeWarnings.append(.pipeline(message))
        }
        replaceRuntimeStartupWarnings(with: replacementRuntimeWarnings)
        startupState = .ready
        scheduleCoalescedFolderReloadIfPossible()
    }

    nonisolated static func pipelineStartupWarningMessage(
        for warnings: [PipelineStartupWarning]
    ) -> String? {
        guard !warnings.isEmpty else { return nil }
        let orphanedMediaCount = warnings.reduce(into: 0) { count, warning in
            if case .orphanedMedia = warning { count += 1 }
        }
        let importedMeetingCount = warnings.count - orphanedMediaCount
        var messages: [String] = []
        if orphanedMediaCount == 1 {
            messages.append(String(localized: "Steno found an original recording file that could not be safely registered. The file remains stored and needs attention."))
        } else if orphanedMediaCount > 1 {
            messages.append(String(localized: "Steno found \(orphanedMediaCount) original recording files that could not be safely registered. The files remain stored and need attention."))
        }
        if importedMeetingCount == 1 {
            messages.append(String(localized: "One imported meeting needs attention because its processing could not be resumed. Other meetings and recording remain available."))
        } else if importedMeetingCount > 1 {
            messages.append(String(localized: "\(importedMeetingCount) imported meetings need attention because their processing could not be resumed. Other meetings and recording remain available."))
        }
        return messages.joined(separator: " ")
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

    /// Replaces the process runtime after a language or model change.
    ///
    /// Detaching both owners is one synchronous main-actor operation and
    /// happens before stopping the old coordinator or starting the new
    /// bootstrap. If capture is active, the old runtime remains untouched so
    /// its normal stop/finalization path can preserve the recording.
    func restartPipelineAfterConfigurationChange() async {
        await restartPipeline(recovery: .restartOnly)
    }

    private func restartPipeline(recovery: RuntimeRecoveryIntent) async {
        await invalidateAndWaitForFolderOperation()
        defer { endRuntimeTransitionBarrier() }
        guard let detached = detachRuntimeIfIdle() else {
            if recording.isActive {
                scheduleRuntimeRecoveryAfterRecording(recovery)
            }
            return
        }
        if let runtime = detached.runtime {
            await runtime.coordinator.stop()
            await requeueModelJobs(recovery, in: runtime.jobStore)
        }
        await startOrJoinBootstrap()
        if detached.runtime == nil, let runtime {
            await requeueModelJobs(recovery, in: runtime.jobStore)
        }
    }

    /// Sprachwechsel, wie auf dem Mac (`App/Sources/AppModel.swift:465`).
    ///
    /// Der Koordinator haelt seine Locale unveraenderlich aus `bootstrap()`.
    /// Ohne den Neustart nutzte die naechste Live-Transkription die neue
    /// Sprache, der danach eingereihte Final-ASR-Lauf aber bis zum
    /// App-Neustart die alte - und der finale Lauf ist der, der zaehlt.
    ///
    /// Waehrend einer Aufnahme gesperrt: den Koordinator unter einer
    /// laufenden Aufnahme wegzuziehen, ist genau das, was diese App nie
    /// still tun darf.
    func setLanguage(_ identifier: String) async {
        guard canChangeLanguage else { return }
        // Derselbe Wert zaehlt, solange noch niemand bestaetigt hat: auf
        // bestehenden Installationen steht in `selectedID` bereits die
        // frueher abgeleitete Sprache, und der Picker zeigt genau sie an.
        // Wuerde die erneute Auswahl hier verworfen, liesse sie sich nie
        // bestaetigen, ohne vorher auf eine andere Sprache zu wechseln.
        let isConfirmation = !language.wasChosenExplicitly
        guard identifier != language.selectedID || isConfirmation else { return }
        await runtimeChanges.run { [weak self] in
            await self?.performLanguageSwitch(identifier)
        }
    }

    private func performLanguageSwitch(_ identifier: String) async {
        // The outer guard may wait behind another serialized mutation. Check
        // the bootstrap lock again before persisting the language choice.
        guard bootstrapTask == nil,
              !recording.isActive,
              !models.isInstalling,
              !diarizationModels.isInstalling else { return }
        // Nach dem Warten noch einmal pruefen, mit derselben Regel wie
        // draussen. Zwei gleiche Auswahlen koennen sich einreihen, bevor die
        // erste `selectedID` gesetzt hat; ohne diese Zeile stoppte und
        // startete die zweite den Koordinator ein zweites Mal, ohne dass
        // sich etwas geaendert haette.
        guard identifier != language.selectedID || !language.wasChosenExplicitly else {
            return
        }
        language.select(identifier)
        await restartPipelineAfterConfigurationChange()
        await models.refresh(for: language.locale)
    }

    /// Ob ein Sprachwechsel gerade moeglich ist. Die Oberflaeche soll den
    /// Grund zeigen koennen, statt einen wirkungslosen Regler anzubieten.
    var canChangeLanguage: Bool {
        bootstrapTask == nil
            && !recording.isActive
            && !models.isInstalling
            && !diarizationModels.isInstalling
            && !runtimeChanges.isRunning
            && meetingTransferImportState == nil
    }

    var canInstallSpeechModel: Bool {
        bootstrapTask == nil
            && !recording.isActive
            && !models.isInstalling
            && !diarizationModels.isInstalling
            && !runtimeChanges.isRunning
            && meetingTransferImportState == nil
    }

    func allowAndInstallSpeechModel() async {
        // Do not grant consent or start an installer while a pipeline with an
        // already captured configuration is still being constructed.
        guard canInstallSpeechModel else { return }
        let locale = language.locale
        let installed = await models.allowAndInstall(
            for: locale,
            recordingIsActive: recording.isActive
        )
        guard installed else { return }

        await runtimeChanges.run { [weak self] in
            guard let self else { return }
            // `isInstalling` becomes false immediately before the installer
            // returns. If a new scene entered that narrow gap, finish its
            // bootstrap and then perform this requested restart in order.
            if let bootstrapTask = self.bootstrapTask {
                await bootstrapTask.value
            }
            await self.restartPipeline(
                recovery: RuntimeRecoveryIntent(.speech(locale: locale))
            )
        }
    }

    private struct DetachedRuntime {
        let runtime: PipelineRuntime?
    }

    private func detachRuntimeIfIdle() -> DetachedRuntime? {
        guard recording.detachRuntimeIfIdle() else { return nil }
        let detached = DetachedRuntime(runtime: runtime)
        runtime = nil
        folderStore = nil
        advanceRuntimeGeneration()
        advanceStoreGeneration()
        folderStateFailure = nil
        clearLibraryIssues()
        folders = []
        startupState = .opening
        return detached
    }

    func revokeSpeechModelConsent() async {
        await models.revoke()
    }

    var canInstallDiarizationModels: Bool {
        bootstrapTask == nil
            && !recording.isActive
            && !models.isInstalling
            && !diarizationModels.isInstalling
            && !runtimeChanges.isRunning
            && meetingTransferImportState == nil
    }

    var canStartRecording: Bool {
        recording.canRecord
            && !runtimeTransitionBarrierIsActive
            && !runtimeChanges.isRunning
            && bootstrapTask == nil
    }

    var canChangeTranscriptionModels: Bool { !recording.isActive }

    /// Snapshot of the currently chosen live/final providers. Pinned once at
    /// recording start (`recordingStarter`'s default), same as the Mac.
    func currentTranscriptionPlan() -> TranscriptionPlan {
        TranscriptionPlan(
            liveProviderID: transcriptionModels.liveProviderID,
            finalProviderID: transcriptionModels.finalProviderID
        )
    }

    func transcriptionModelName(_ id: TranscriptionProviderID) -> String {
        transcriptionCatalog.descriptor(for: id)?.displayName ?? id.rawValue
    }

    /// Whether a model is really installed, not merely listed in the
    /// catalog. Apple needs no separate installation; everything else
    /// depends on `transcriptionModelInstaller`. A not-installed model must
    /// never look selectable.
    func isTranscriptionModelInstalled(_ id: TranscriptionProviderID) -> Bool {
        id == .apple || transcriptionModelInstaller.isReady(for: language.locale) == true
    }

    /// The explicit Apple retry offer: a failed Parakeet run suggests
    /// Apple, but never switches on its own. This call is the user's
    /// consent.
    func retryFinalASRWithApple(_ failedJob: Job) async {
        guard let runtime,
              failedJob.kind == .finalASR,
              failedJob.status == .failed
        else { return }
        guard let operation = beginLibraryOperation() else {
            reportActionNotice(.appleRetryQueue(
                AppModelLibraryOperationError.operationInProgress.localizedDescription
            ))
            return
        }
        defer { endFolderOperation(operation) }
        do {
            try await runtime.jobStore.enqueue(Job.finalASR(
                meetingID: failedJob.meetingID,
                providerID: .apple,
                localeIdentifier: failedJob.localeIdentifier
                    ?? language.locale.identifier,
                processingGenerationID: failedJob.processingGenerationID
            ))
        } catch {
            reportActionNotice(.appleRetryQueue(error.localizedDescription))
        }
    }

    @discardableResult
    func startRecording() async -> Bool {
        guard canStartRecording else { return false }
        await beforeRecordingStart()
        guard canStartRecording else { return false }
        let selection = language.recordingSelection
        await recordingStarter(
            recording,
            selection.locale,
            selection.effectiveLocaleWasChosenExplicitly
        )
        return true
    }

    func recordingDidBecomeIdle() async {
        while !recording.isActive,
              let recovery = pendingRuntimeRecoveryAfterRecording {
            pendingRuntimeRecoveryAfterRecording = nil
            await runtimeChanges.run { [weak self] in
                await self?.restartPipeline(recovery: recovery)
            }
        }
    }

    func scheduleModelJobRecoveryAfterRecording(_ recovery: ModelJobRecoveryIntent) {
        scheduleRuntimeRecoveryAfterRecording(RuntimeRecoveryIntent(recovery))
    }

    func stopRecording() async {
        await recording.stop()
        await reloadMeetings()
        await recordingDidBecomeIdle()
    }

    func allowAndInstallDiarizationModels() async {
        guard canInstallDiarizationModels else { return }
        let installed = await diarizationModels.allowAndInstall(
            for: language.locale,
            recordingIsActive: recording.isActive
        )
        guard installed else { return }

        await runtimeChanges.run { [weak self] in
            guard let self else { return }
            if let bootstrapTask = self.bootstrapTask {
                await bootstrapTask.value
            }
            await self.restartPipeline(
                recovery: RuntimeRecoveryIntent(.diarization)
            )
        }
    }

    private func scheduleRuntimeRecoveryAfterRecording(
        _ recovery: RuntimeRecoveryIntent
    ) {
        if pendingRuntimeRecoveryAfterRecording == nil {
            pendingRuntimeRecoveryAfterRecording = recovery
        } else {
            pendingRuntimeRecoveryAfterRecording?.merge(recovery)
        }
    }

    private func requeueModelJobs(
        _ recovery: RuntimeRecoveryIntent,
        in jobStore: JobStore
    ) async {
        var failures: [String] = []
        for identifier in recovery.speechLocaleIdentifiers.sorted() {
            do {
                _ = try await MissingSpeechModelJobRetrier.requeue(
                    jobStore: jobStore,
                    locale: Locale(identifier: identifier)
                )
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        if recovery.retriesDiarization {
            do {
                _ = try await MissingDiarizationModelJobRetrier.requeue(
                    jobStore: jobStore
                )
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        if !failures.isEmpty {
            reportStartupWarning(.missingModelRequeue(
                failures.joined(separator: " ")
            ))
        }
    }

    func revokeDiarizationModelConsent() async {
        await diarizationModels.revoke()
    }

    func cancelDiarizationModelInstallForBackground() async {
        guard diarizationModels.isInstalling else { return }
        await diarizationModels.cancelInstall()
    }

    func reloadMeetings() async {
        guard activeFolderOperationID == nil, !runtimeTransitionBarrierIsActive else {
            requestCoalescedFolderReload()
            return
        }
        if let meetingListLoader {
            let refreshGeneration = beginMeetingRefresh()
            do {
                let loadedMeetings = try await meetingListLoader()
                guard isCurrentMeetingRefresh(refreshGeneration) else { return }
                meetings = loadedMeetings
                clearLibraryIssue(.meetings)
            } catch {
                guard isCurrentMeetingRefresh(refreshGeneration) else { return }
                reportLibraryIssue(.meetings(error.localizedDescription))
            }
            return
        }
        guard let snapshot = runtimeSnapshot() else { return }
        _ = await reloadMeetings(for: snapshot, operation: nil)
    }

    /// Retries only the index represented by the visible issue. It never
    /// starts or replaces a valid pipeline runtime.
    func retryLibraryIssue() async {
        guard let issue = libraryIssue else { return }
        await retryLibraryIssue(issue)
    }

    func retryLibraryIssue(_ requestedIssue: IOSLibraryIssue) async {
        guard libraryIssue(withID: requestedIssue.id) != nil,
              activeFolderOperationID == nil,
              !runtimeTransitionBarrierIsActive,
              let snapshot = runtimeSnapshot()
        else { return }

        switch requestedIssue.id {
        case .meetings:
            let refreshGeneration = beginMeetingRefresh()
            clearLibraryIssue(.meetings)
            await retryMeetingList(
                for: snapshot,
                refreshGeneration: refreshGeneration
            )
        case .folders:
            let refreshGeneration = beginFolderRefresh()
            activeFolderIssueRetryGeneration = refreshGeneration
            defer {
                if activeFolderIssueRetryGeneration == refreshGeneration {
                    activeFolderIssueRetryGeneration = nil
                    scheduleCoalescedFolderReloadIfPossible()
                }
            }
            clearLibraryIssue(.folders)
            await retryFolderList(
                for: snapshot,
                refreshGeneration: refreshGeneration
            )
        }
    }

    private func retryMeetingList(
        for snapshot: RuntimeFolderSnapshot,
        refreshGeneration: UInt64
    ) async {
        do {
            let loadedMeetings: [Meeting]
            if let meetingListLoader {
                loadedMeetings = try await meetingListLoader()
            } else {
                loadedMeetings = try await runtimeMeetingLoader(snapshot.runtime.library)
            }
            guard isCurrent(snapshot),
                  isCurrentMeetingRefresh(refreshGeneration) else { return }
            meetings = loadedMeetings
        } catch {
            guard isCurrent(snapshot),
                  isCurrentMeetingRefresh(refreshGeneration) else { return }
            reportLibraryIssue(.meetings(error.localizedDescription))
        }
    }

    private func retryFolderList(
        for snapshot: RuntimeFolderSnapshot,
        refreshGeneration: UInt64
    ) async {
        do {
            let reopenedStore = try folderStoreOpener(snapshot.runtime.library.layout)
            let loadedFolders = try await folderListLoader(reopenedStore)
            guard isCurrent(snapshot),
                  isCurrentFolderRefresh(refreshGeneration) else { return }
            folderStore = reopenedStore
            folders = loadedFolders
            folderStateFailure = nil
            advanceStoreGeneration()
        } catch {
            guard isCurrent(snapshot),
                  isCurrentFolderRefresh(refreshGeneration) else { return }
            let message = String(localized: "The folders could not be loaded. (\(error.localizedDescription))")
            folderStateFailure = message
            reportLibraryIssue(.folders(message))
        }
    }

    /// Demo installation changes meetings and the folder index together. It
    /// therefore shares the existing structural-operation boundary with
    /// folder moves, Trash and runtime replacement instead of inventing a
    /// second local busy flag.
    func refreshDemoDataStatus() async {
        await performDemoDataOperation(.checkingStatus) { _ in
            nil
        }
    }

    func installDemoData() async {
        await performDemoDataOperation(.installing) { client in
            try await client.install()
            return nil
        }
    }

    func replaceDemoData(replacingEditedMeetings: Bool) async {
        let policy: DemoReplacementPolicy = replacingEditedMeetings
            ? .replaceModifiedMeetings
            : .keepModifiedMeetings
        await performDemoDataOperation(.replacing) { client in
            try await client.replace(policy)
        }
    }

    func removeDemoData() async {
        await performDemoDataOperation(.removing) { client in
            try await client.remove()
        }
    }

    private func performDemoDataOperation(
        _ operationKind: DemoDataOperation,
        action: @escaping @Sendable (DemoDataLifecycleClient) async throws -> DemoLifecycleResult?
    ) async {
        guard let operation = beginLibraryOperation() else { return }
        defer { endFolderOperation(operation) }

        // A structural mutation can make a prior status false before the
        // next reconciliation returns. Only the operation that acquired the
        // lease may invalidate it; a rejected parallel request must leave the
        // shared publication for its owner to finish.
        demoDataStatus = nil
        if operationKind != .checkingStatus {
            demoDataError = nil
            demoDataResult = nil
        }
        demoDataStatusError = nil
        demoDataReconciliationError = nil
        demoDataOperation = operationKind
        defer { demoDataOperation = nil }

        let snapshot: RuntimeFolderSnapshot
        do {
            snapshot = try folderOperationSnapshot()
        } catch {
            publishDemoDataSetupError(for: operationKind)
            return
        }

        let client: DemoDataLifecycleClient
        do {
            guard let store = snapshot.folderStore else {
                throw AppModelFolderError.storeUnavailable
            }
            client = try demoDataClientFactory(snapshot.runtime.library, store)
        } catch {
            guard isCurrent(snapshot, operation: operation) else { return }
            publishDemoDataSetupError(for: operationKind)
            return
        }

        let lifecycleResult: DemoLifecycleResult?
        let lifecycleError: Error?
        do {
            lifecycleResult = try await action(client)
            lifecycleError = nil
        } catch {
            lifecycleResult = nil
            lifecycleError = error
        }

        guard isCurrent(snapshot, operation: operation) else { return }

        let refreshedStatus: DemoLibraryStatus?
        let statusError: Error?
        do {
            refreshedStatus = try await client.status()
            statusError = nil
        } catch {
            refreshedStatus = nil
            statusError = error
        }

        guard isCurrent(snapshot, operation: operation) else { return }
        let reloadResult = await reloadMeetings(
            for: snapshot,
            operation: operation,
            reportsFailuresToStartup: false
        )
        guard isCurrent(snapshot, operation: operation) else { return }

        if operationKind != .checkingStatus {
            demoDataResult = lifecycleResult
            demoDataError = lifecycleError.map { _ in
                String(localized: DemoDataPresentation.lifecycleFailureDetail)
            }
        }
        demoDataStatus = refreshedStatus
        demoDataStatusError = statusError.map { _ in
            String(localized: DemoDataPresentation.statusFailureDetail)
        }
        demoDataReconciliationError = demoDataReconciliationMessage(for: reloadResult)
    }

    private func publishDemoDataSetupError(
        for operationKind: DemoDataOperation
    ) {
        if operationKind == .checkingStatus {
            demoDataStatusError = String(
                localized: DemoDataPresentation.statusFailureDetail
            )
        } else {
            demoDataError = String(
                localized: DemoDataPresentation.lifecycleFailureDetail
            )
        }
    }

    private func demoDataReconciliationMessage(
        for reloadResult: FolderReloadResult
    ) -> String? {
        switch reloadResult {
        case .published:
            nil
        case .foldersUnavailable(_):
            String(
                localized: DemoDataPresentation.folderReconciliationFailureDetail
            )
        case .meetingsUnavailable(_):
            String(
                localized: DemoDataPresentation.meetingReconciliationFailureDetail
            )
        case .stale:
            String(localized: DemoDataPresentation.reconciliationStaleError)
        }
    }

    struct TrashUndoReceipt: Identifiable {
        let id = UUID()
        let meetingID: MeetingID
        let title: String
        let trashedURL: URL
        let runtimeGeneration: UInt64
        let libraryRoot: URL
        let processingGenerationID: MeetingTransferGenerationID?
    }

    private(set) var trashUndoReceipts: [TrashUndoReceipt] = []

    var pendingTrashUndo: TrashUndoReceipt? {
        trashUndoReceipts.last { $0.runtimeGeneration == runtimeGeneration && $0.libraryRoot == runtime?.library.layout.root }
    }

    func restoreLastTrashedMeeting() async throws -> MeetingID? {
        guard let receipt = pendingTrashUndo else { return nil }
        return try await restoreTrashedMeeting(receipt)
    }

    func recentlyDeletedMeetings() async throws -> LibraryTrashStore.Listing {
        guard let snapshot = runtimeSnapshot() else { throw MeetingDeletionError.runtimeUnavailable }
        let listing = try LibraryTrashStore(layout: snapshot.runtime.library.layout).list()
        guard isCurrent(snapshot) else { throw MeetingDeletionError.operationInvalidated }
        return listing
    }

    func restoreDeletedMeeting(_ entry: LibraryTrashStore.Entry) async throws -> MeetingID {
        guard let snapshot = runtimeSnapshot() else { throw MeetingDeletionError.runtimeUnavailable }
        let current = try LibraryTrashStore(layout: snapshot.runtime.library.layout).entries()
        guard let stored = current.first(where: { $0.id == entry.id }),
              stored.directory == entry.directory,
              stored.meeting.processingGenerationID == entry.meeting.processingGenerationID else {
            throw MeetingDeletionError.operationInvalidated
        }
        return try await restoreTrashedMeeting(TrashUndoReceipt(
            meetingID: stored.meeting.id, title: stored.meeting.title, trashedURL: stored.directory,
            runtimeGeneration: snapshot.generation, libraryRoot: snapshot.runtime.library.layout.root,
            processingGenerationID: stored.meeting.processingGenerationID
        ))
    }

    private func restoreTrashedMeeting(_ receipt: TrashUndoReceipt) async throws -> MeetingID {
        guard let operation = beginLibraryOperation() else {
            throw MeetingDeletionError.operationInProgress
        }
        defer { endFolderOperation(operation) }
        guard let snapshot = runtimeSnapshot(), snapshot.generation == receipt.runtimeGeneration else {
            throw MeetingDeletionError.operationInvalidated
        }
        let layout = snapshot.runtime.library.layout
        try LibraryMutationCoordination.withExclusiveAccess(layout: layout) {
            let destination = layout.meetingDirectory(receipt.meetingID)
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw CocoaError(.fileWriteFileExists)
            }
            let encoded = try Data(contentsOf: receipt.trashedURL.appendingPathComponent("meeting.json"))
            let original = try JSONDecoder().decode(Meeting.self, from: encoded)
            guard original.schemaVersion == Meeting.currentSchemaVersion,
                  original.id == receipt.meetingID,
                  original.processingGenerationID == receipt.processingGenerationID else {
                throw MeetingDeletionError.operationInvalidated
            }
            try FileManager.default.moveItem(at: receipt.trashedURL, to: destination)
        }
        trashUndoReceipts.removeAll { $0.trashedURL == receipt.trashedURL }
        removedMeetingIDs.remove(receipt.meetingID)
        notesSessions?.completeMeetingRestoration(receipt.meetingID)
        _ = await reloadMeetings(for: snapshot, operation: operation)
        return receipt.meetingID
    }

    func deleteMeeting(_ meetingID: MeetingID) async throws -> MeetingDeletionOutcome {
        guard bootstrapTask == nil, let notesSessions else {
            throw MeetingDeletionError.runtimeUnavailable
        }
        guard let operation = beginLibraryOperation() else {
            throw MeetingDeletionError.operationInProgress
        }
        defer { endFolderOperation(operation) }

        guard let snapshot = runtimeSnapshot() else {
            throw MeetingDeletionError.runtimeUnavailable
        }
        try MeetingDeletionRuntimeGuard.requireDeletionAllowed(
            meetingID: meetingID,
            recordingIsActive: recording.isActive,
            recordingMeetingID: recording.meetingID
        )

        let deletedMeeting = try await snapshot.runtime.library.loadMeeting(meetingID)
        do {
            try await notesSessions.prepareForMeetingRemoval(meetingID)
            let jobs = try await snapshot.runtime.jobStore.list().filter {
                $0.meetingID == meetingID
                    && ($0.status == .queued || $0.status == .running)
            }
            for job in jobs {
                do {
                    try await snapshot.runtime.coordinator.cancel(jobID: job.id)
                } catch PipelineError.cancellationTooLate {
                    throw MeetingDeletionError.processingCommitInProgress
                }
            }
            guard isCurrent(snapshot, operation: operation) else {
                throw MeetingDeletionError.operationInvalidated
            }
            if let trashedURL = try await meetingTrasher(snapshot.runtime.library, meetingID) {
                trashUndoReceipts.append(TrashUndoReceipt(
                    meetingID: meetingID, title: deletedMeeting.title, trashedURL: trashedURL,
                    runtimeGeneration: snapshot.generation, libraryRoot: snapshot.runtime.library.layout.root,
                    processingGenerationID: deletedMeeting.processingGenerationID
                ))
            }
        } catch {
            notesSessions.cancelMeetingRemoval(meetingID)
            throw error
        }

        removedMeetingIDs.insert(meetingID)
        notesSessions.completeMeetingRemoval(meetingID)
        clearReviewStateAfterMeetingRemoval(meetingID)
        meetings.removeAll { $0.id == meetingID }

        let cleanupWarning: String?
        do {
            _ = try await snapshot.runtime.jobStore.removeJobs(meetingID: meetingID)
            cleanupWarning = nil
        } catch {
            cleanupWarning =
                "The meeting was moved to Trash, but its processing records could not be cleaned up. (\(error.localizedDescription))"
        }
        _ = await reloadMeetings(for: snapshot, operation: operation)
        return MeetingDeletionOutcome(cleanupWarning: cleanupWarning)
    }

    struct RuntimeFolderSnapshot {
        let generation: UInt64
        let storeGeneration: UInt64
        let folderMutationGeneration: UInt64
        let runtime: PipelineRuntime
        let folderStore: FolderStore?
    }

    struct FolderOperationToken: Equatable {
        let id: UInt64
    }

    enum FolderReloadResult: Equatable {
        case published
        case foldersUnavailable(String)
        case meetingsUnavailable(String)
        case stale
    }

    func runtimeSnapshot() -> RuntimeFolderSnapshot? {
        guard let runtime else { return nil }
        return RuntimeFolderSnapshot(
            generation: runtimeGeneration,
            storeGeneration: storeGeneration,
            folderMutationGeneration: folderMutationGeneration,
            runtime: runtime,
            folderStore: folderStore
        )
    }

    func folderOperationSnapshot() throws -> RuntimeFolderSnapshot {
        guard let snapshot = runtimeSnapshot() else {
            throw AppModelFolderError.runtimeUnavailable
        }
        guard snapshot.folderStore != nil else {
            throw AppModelFolderError.storeUnavailable
        }
        return snapshot
    }

    func isCurrent(
        _ snapshot: RuntimeFolderSnapshot,
        operation: FolderOperationToken? = nil
    ) -> Bool {
        guard runtimeGeneration == snapshot.generation,
              storeGeneration == snapshot.storeGeneration,
              folderMutationGeneration == snapshot.folderMutationGeneration else { return false }
        guard let operation else { return activeFolderOperationID == nil }
        return activeFolderOperationID == operation.id
    }

    private func advanceRuntimeGeneration() {
        runtimeGeneration &+= 1
        meetingRefreshGeneration &+= 1
        folderRefreshGeneration &+= 1
        activeFolderIssueRetryGeneration = nil
    }

    private func advanceStoreGeneration() {
        storeGeneration &+= 1
        folderRefreshGeneration &+= 1
    }

    private func advanceFolderMutationGeneration() {
        folderMutationGeneration &+= 1
    }

    @discardableResult
    private func beginMeetingRefresh() -> UInt64 {
        meetingRefreshGeneration &+= 1
        return meetingRefreshGeneration
    }

    @discardableResult
    private func beginFolderRefresh() -> UInt64 {
        folderRefreshGeneration &+= 1
        return folderRefreshGeneration
    }

    private func isCurrentMeetingRefresh(_ generation: UInt64) -> Bool {
        meetingRefreshGeneration == generation
    }

    private func isCurrentFolderRefresh(_ generation: UInt64) -> Bool {
        folderRefreshGeneration == generation
    }

    /// Reads both indexes through one runtime snapshot and publishes them only
    /// if that exact snapshot still owns the screen after every await.
    @discardableResult
    func reloadMeetings(
        for snapshot: RuntimeFolderSnapshot,
        operation: FolderOperationToken?,
        reportsFailuresToStartup: Bool = true
    ) async -> FolderReloadResult {
        let meetingRefresh = beginMeetingRefresh()
        let folderRefresh = beginFolderRefresh()
        let loadedMeetings: [Meeting]
        do {
            loadedMeetings = try await runtimeMeetingLoader(snapshot.runtime.library)
        } catch {
            guard isCurrent(snapshot, operation: operation),
                  isCurrentMeetingRefresh(meetingRefresh) else {
                return staleReloadResult(for: operation)
            }
            let message = error.localizedDescription
            if reportsFailuresToStartup {
                reportLibraryIssue(.meetings(message))
            }
            return .meetingsUnavailable(message)
        }

        guard isCurrent(snapshot, operation: operation),
              isCurrentMeetingRefresh(meetingRefresh),
              isCurrentFolderRefresh(folderRefresh) else {
            return staleReloadResult(for: operation)
        }
        guard let store = snapshot.folderStore else {
            meetings = loadedMeetings
            folders = []
            clearLibraryIssue(.meetings)
            let message = folderStateFailure
                ?? String(localized: "The folders could not be loaded. (The folder index is not available.)")
            if reportsFailuresToStartup {
                reportFolderAvailabilityFailure(message)
            }
            return .foldersUnavailable(message)
        }

        do {
            let loadedFolders = try await folderListLoader(store)
            guard isCurrent(snapshot, operation: operation),
                  isCurrentMeetingRefresh(meetingRefresh),
                  isCurrentFolderRefresh(folderRefresh) else {
                return staleReloadResult(for: operation)
            }
            meetings = loadedMeetings
            folders = loadedFolders
            folderStateFailure = nil
            clearLibraryIssues()
            return .published
        } catch {
            guard isCurrent(snapshot, operation: operation),
                  isCurrentMeetingRefresh(meetingRefresh),
                  isCurrentFolderRefresh(folderRefresh) else {
                return staleReloadResult(for: operation)
            }
            meetings = loadedMeetings
            folders = []
            clearLibraryIssue(.meetings)
            let message = String(localized: "The folders could not be loaded. (\(error.localizedDescription))")
            if reportsFailuresToStartup {
                reportFolderAvailabilityFailure(message)
            }
            return .foldersUnavailable(message)
        }
    }

    /// Use this only after a failed folder recovery. The meeting index remains
    /// independently readable, whereas retaining a former folder tree would
    /// show IDs that may no longer exist on disk.
    @discardableResult
    func publishReadableMeetingsWithUnavailableFolders(
        for snapshot: RuntimeFolderSnapshot,
        failure: String,
        operation: FolderOperationToken
    ) async -> FolderReloadResult {
        do {
            let loadedMeetings = try await runtimeMeetingLoader(snapshot.runtime.library)
            guard isCurrent(snapshot, operation: operation) else { return .stale }
            meetings = loadedMeetings
            folders = []
            clearLibraryIssue(.meetings)
            reportFolderAvailabilityFailure(failure)
            return .foldersUnavailable(failure)
        } catch {
            guard isCurrent(snapshot, operation: operation) else { return .stale }
            folders = []
            let meetingMessage =
                "The meetings could not be reloaded. (\(error.localizedDescription))"
            reportLibraryIssue(.meetings(meetingMessage))
            reportFolderAvailabilityFailure(failure)
            return .meetingsUnavailable("\(failure) \(meetingMessage)")
        }
    }

    func beginFolderOperation() -> FolderOperationToken? {
        guard let token = beginLibraryOperation() else {
            if runtimeTransitionBarrierIsActive {
                reportFolderFailure(
                    "The folder action could not start.",
                    AppModelFolderError.runtimeTransitionInProgress
                )
            } else {
                reportFolderFailure(
                    "The folder action could not start.",
                    AppModelFolderError.operationInProgress
                )
            }
            return nil
        }
        return token
    }

    /// Lets visible controls disable before they would collide with a shared
    /// library mutation. The mutation boundary remains authoritative.
    var libraryActionIsInFlight: Bool {
        runtimeTransitionBarrierIsActive || activeFolderOperationID != nil
    }

    /// Shared exclusion boundary for structural library mutations and every
    /// user-started processing request that must not cross a successful Trash.
    func beginLibraryOperation() -> FolderOperationToken? {
        guard !runtimeTransitionBarrierIsActive else {
            return nil
        }
        guard activeFolderOperationID == nil else {
            return nil
        }
        nextFolderOperationID &+= 1
        advanceFolderMutationGeneration()
        let token = FolderOperationToken(id: nextFolderOperationID)
        activeFolderOperationID = token.id
        return token
    }

    func endFolderOperation(_ operation: FolderOperationToken) {
        guard activeFolderOperationID == operation.id else { return }
        activeFolderOperationID = nil
        advanceFolderMutationGeneration()
        let waiters = folderOperationWaiters
        folderOperationWaiters = []
        for waiter in waiters { waiter.resume() }
        scheduleCoalescedFolderReloadIfPossible()
    }

    func setMeetingFolders(
        _ meetingIDs: Set<MeetingID>,
        to folderID: FolderID?,
        in snapshot: RuntimeFolderSnapshot,
        operation: FolderOperationToken
    ) async throws -> [Meeting] {
        await beforeMeetingFolderSet()
        guard isCurrent(snapshot, operation: operation) else {
            throw AppModelFolderError.operationInvalidated
        }
        return try await meetingFolderSetter(snapshot.runtime.library, meetingIDs, folderID)
    }

    func deleteFolderIndex(
        _ folderID: FolderID,
        from store: FolderStore
    ) async throws -> FolderDeletionResult? {
        try await folderStoreDeletion(store, folderID)
    }

    func freshFolderStore(for snapshot: RuntimeFolderSnapshot) throws -> FolderStore {
        try folderStoreOpener(snapshot.runtime.library.layout)
    }

    func adoptFolderStore(
        _ store: FolderStore,
        for snapshot: RuntimeFolderSnapshot,
        operation: FolderOperationToken
    ) -> RuntimeFolderSnapshot? {
        guard isCurrent(snapshot, operation: operation) else { return nil }
        folderStore = store
        advanceStoreGeneration()
        return RuntimeFolderSnapshot(
            generation: runtimeGeneration,
            storeGeneration: storeGeneration,
            folderMutationGeneration: folderMutationGeneration,
            runtime: snapshot.runtime,
            folderStore: store
        )
    }

    private func invalidateAndWaitForFolderOperation() async {
        runtimeTransitionBarrierIsActive = true
        await afterRuntimeTransitionBarrierStarts()
        if activeFolderOperationID != nil {
            await withCheckedContinuation { continuation in
                folderOperationWaiters.append(continuation)
                didRegisterFolderOperationWaiter()
            }
        }
        await beforeRuntimeTransitionDetach()
    }

    private func endRuntimeTransitionBarrier() {
        runtimeTransitionBarrierIsActive = false
        scheduleCoalescedFolderReloadIfPossible()
    }

    private func staleReloadResult(
        for operation: FolderOperationToken?
    ) -> FolderReloadResult {
        if operation == nil { requestCoalescedFolderReload() }
        return .stale
    }

    private func requestCoalescedFolderReload() {
        pendingFolderReload = true
        scheduleCoalescedFolderReloadIfPossible()
    }

    private func scheduleCoalescedFolderReloadIfPossible() {
        guard pendingFolderReload,
              activeFolderOperationID == nil,
              activeFolderIssueRetryGeneration == nil,
              !runtimeTransitionBarrierIsActive,
              runtime != nil,
              coalescedFolderReloadTask == nil else { return }
        didScheduleCoalescedFolderReload()
        coalescedFolderReloadTask = Task { @MainActor [weak self] in
            await self?.performCoalescedFolderReload()
        }
    }

    private func performCoalescedFolderReload() async {
        defer {
            coalescedFolderReloadTask = nil
            scheduleCoalescedFolderReloadIfPossible()
        }
        guard pendingFolderReload,
              activeFolderOperationID == nil,
              activeFolderIssueRetryGeneration == nil,
              !runtimeTransitionBarrierIsActive,
              runtime != nil else { return }
        pendingFolderReload = false
        await reloadMeetings()
        await afterCoalescedFolderReload()
    }

    func reportLibraryIssue(_ issue: IOSLibraryIssue) {
        switch issue {
        case .meetings:
            meetingLibraryIssue = issue
        case .folders:
            folderLibraryIssue = issue
        }
    }

    private func libraryIssue(withID id: IOSLibraryIssue.ID) -> IOSLibraryIssue? {
        switch id {
        case .meetings:
            meetingLibraryIssue
        case .folders:
            folderLibraryIssue
        }
    }

    private func clearLibraryIssue(_ id: IOSLibraryIssue.ID) {
        switch id {
        case .meetings:
            meetingLibraryIssue = nil
        case .folders:
            folderLibraryIssue = nil
        }
    }

    private func clearLibraryIssues() {
        meetingLibraryIssue = nil
        folderLibraryIssue = nil
    }

    func reportStartupWarning(_ warning: IOSStartupWarning) {
        if !startupWarnings.contains(warning) {
            startupWarnings.append(warning)
        }
    }

    private func replaceRuntimeStartupWarnings(
        with replacements: [IOSStartupWarning]
    ) {
        startupWarnings.removeAll { warning in
            switch warning {
            case .captureRecovery, .pipeline:
                true
            case .missingModelRequeue:
                false
            }
        }
        for warning in replacements {
            reportStartupWarning(warning)
        }
    }

    func reportActionNotice(_ notice: IOSActionNotice) {
        actionNotice = notice
    }

    func clearStartupWarnings() {
        startupWarnings = []
    }

    func clearActionNotice() {
        actionNotice = nil
    }

    func reportFolderFailure(_ summary: String, _ error: Error) {
        reportActionNotice(.folderMutation(
            "\(summary) (\(error.localizedDescription))"
        ))
    }

    /// Same shape as `reportFolderFailure`, kept separate so the message
    /// stays about drafts even though both write the one shared banner.
    func reportDraftCreationFailure(_ error: Error) {
        reportActionNotice(.draftCreation(error.localizedDescription))
    }

    func reportFolderAvailabilityFailure(_ message: String) {
        folderStateFailure = message
        reportLibraryIssue(.folders(message))
    }

    func reportFolderStateReloaded() {
        reportActionNotice(.folderStateReload(
            "The folder no longer exists and the current library state was reloaded."
        ))
    }

    func reportFolderPartialRecoveryFailure(
        _ restorationError: Error,
        reloadResult: FolderReloadResult
    ) {
        let context: String
        switch reloadResult {
        case let .foldersUnavailable(message), let .meetingsUnavailable(message):
            context = message
        case .published, .stale:
            context = "The current folder index was reloaded."
        }
        reportActionNotice(.partialRecovery(
            "\(context) The folder could not be deleted and some meeting assignments could not be restored. \(restorationError.localizedDescription)"
        ))
    }

    /// The request is retained until the normal split/compact route can find
    /// the meeting in the list it renders.
    func consumeSelectedMeetingIDIfAvailable(
        for sceneID: MeetingTransferSceneID
    ) -> MeetingID? {
        guard let selectedMeetingID,
              selectedMeetingSceneID == sceneID,
              isLivingMeetingTransferScene(sceneID),
              meetings.contains(where: { $0.id == selectedMeetingID }) else {
            return nil
        }
        self.selectedMeetingID = nil
        selectedMeetingSceneID = nil
        return selectedMeetingID
    }

    func isLivingMeetingTransferScene(_ sceneID: MeetingTransferSceneID) -> Bool {
        livingMeetingTransferSceneIDs.contains(sceneID)
    }

    func consumeSelectedMeetingIDIfAvailable() -> MeetingID? {
        guard let selectedMeetingSceneID else { return nil }
        return consumeSelectedMeetingIDIfAvailable(for: selectedMeetingSceneID)
    }

    // MARK: - Reading a meeting
    //
    // Same calls as the Mac (`AppModel.swift:525-544`, `AppModel+Review.swift`).
    // Transcript and speaker review stay read-only here. Notes use the shared
    // editing session below, which owns their complete persistence path.

    func meeting(_ meetingID: MeetingID) async -> Meeting? {
        guard let runtime else { return nil }
        return try? await runtime.library.loadMeeting(meetingID)
    }

    func transcript(for meetingID: MeetingID) async -> TranscriptRevision? {
        guard let runtime else { return nil }
        return try? await runtime.library.loadCurrentRevision(meetingID: meetingID)
    }

    func currentRevisionPointer(
        for meetingID: MeetingID
    ) async -> CurrentRevisionPointer? {
        guard let runtime else { return nil }
        return try? await runtime.library
            .loadCurrentRevisionPointer(meetingID: meetingID)
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

    func meetingDiarizationState(
        for meetingID: MeetingID
    ) async -> MeetingDiarizationJobState {
        guard let runtime else { return .unavailable }
        do {
            return try await MeetingDiarizationRequest.status(
                library: runtime.library,
                jobStore: runtime.jobStore,
                meetingID: meetingID,
                modelsReady: diarizationModels.isReady(for: language.locale) == true
            )
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func requestMeetingDiarization(
        for meetingID: MeetingID
    ) async -> MeetingDiarizationJobState {
        guard let runtime else { return .unavailable }
        guard let operation = beginLibraryOperation() else {
            return .failed(AppModelLibraryOperationError.operationInProgress.localizedDescription)
        }
        defer { endFolderOperation(operation) }
        do {
            return try await MeetingDiarizationRequest.request(
                library: runtime.library,
                jobStore: runtime.jobStore,
                meetingID: meetingID,
                modelsReady: diarizationModels.isReady(for: language.locale) == true
            )
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func adoptPendingMeetingDiarization(
        for meetingID: MeetingID,
        expectedCurrentRevisionID: RevisionID
    ) async -> MeetingDiarizationJobState {
        guard let runtime else { return .unavailable }
        guard let operation = beginLibraryOperation() else {
            return .failed(AppModelLibraryOperationError.operationInProgress.localizedDescription)
        }
        defer { endFolderOperation(operation) }
        do {
            return try await MeetingDiarizationRequest.adoptPendingResult(
                library: runtime.library,
                jobStore: runtime.jobStore,
                meetingID: meetingID,
                expectedCurrentRevisionID: expectedCurrentRevisionID,
                modelsReady: diarizationModels.isReady(for: language.locale) == true
            )
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func notesSession(for meetingID: MeetingID) async -> MeetingNotesEditingSession? {
        guard let notesSessions else { return nil }
        return await notesSessions.session(for: meetingID)
    }

    /// Alle Jobs eines Meetings, ungefiltert nach Art - im Unterschied zu
    /// `jobs(for:)` in `AppModel+Reports.swift`, das nur die
    /// Protokoll-Jobs liefert. Wird fuer das Apple-Retry-Angebot bei einem
    /// fehlgeschlagenen Parakeet-Lauf gebraucht.
    func meetingJobs(for meetingID: MeetingID) async -> [Job] {
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

    /// End of the recording timeline, including appended recording segments.
    /// Concurrent microphone and system tracks do not add to each other.
    func duration(for meetingID: MeetingID) async -> TimeInterval? {
        guard let runtime else { return nil }
        let assets = (try? await runtime.library.listMediaAssets(
            meetingID: meetingID
        )) ?? []
        guard !assets.isEmpty else { return nil }
        return AppendedTimeline.timelineEnd(of: assets)
    }

    /// Where the library sits, for the diagnostics screen and for pointing the
    /// user at the Files app.
    var libraryPath: String {
        libraryURL.path(percentEncoded: false)
    }

    private static func startLivePipeline(
        at libraryURL: URL,
        locale: Locale,
        textModelProviderResolver: @escaping TextModelProviderResolver,
        transcriptionRegistry: TranscriptionProviderRegistry
    ) async throws -> PipelineRuntime {
        try await startPipeline(
            at: libraryURL,
            // Der Provider wird je Job aufgeloest statt fest verdrahtet, wie
            // am Mac: ein finalASR-Job traegt seinen gepinnten Provider aus
            // `meeting.transcriptionPlan`. iOS hat keine Systemspur, also
            // bekommt ein Import weiterhin das Mikrofon-Kanal-Label, nicht
            // "System" wie am Mac.
            transcriptionProviderResolver: { providerID, assetKind in
                let resolvedKind: MediaAsset.Kind = assetKind == .imported
                    ? .micTrack
                    : assetKind
                return try transcriptionRegistry.resolve(providerID, for: resolvedKind)
            },
            diarizationProvider: FluidSortformerProvider(
                modelCacheDirectory: try LibraryLocation.modelCacheURL()
            ),
            textModelProviderResolver: textModelProviderResolver,
            locale: locale
        )
    }

    private static func makeDiarizationModelState() -> IOSModelInstallationState {
        let consent = ModelConsent.diarization()
        do {
            let installer = DiarizationModelInstaller(
                modelCacheDirectory: try LibraryLocation.modelCacheURL(),
                manifest: try ModelChecksumManifest.bundled()
            )
            return IOSModelInstallationState(
                coordinator: ModelInstallationCoordinator(installers: [installer]),
                consent: consent
            )
        } catch {
            return IOSModelInstallationState(
                unavailableBundle: DiarizationModelInstaller.expectedBundleDescription,
                consent: consent,
                errorMessage: error.localizedDescription
            )
        }
    }

    private static func makeTranscriptionModelInstallerState() -> IOSModelInstallationState {
        let consent = ModelConsent.parakeet()
        do {
            let installer = ParakeetModelInstaller(
                modelCacheDirectory: try LibraryLocation.modelCacheURL(),
                manifest: try ParakeetModelInstaller.bundledManifest()
            )
            return IOSModelInstallationState(
                coordinator: ModelInstallationCoordinator(installers: [installer]),
                consent: consent
            )
        } catch {
            let descriptor = TranscriptionModelCatalog.standard.descriptor(for: .parakeetTDTv3)
            return IOSModelInstallationState(
                unavailableBundle: ModelBundleDescription(
                    id: .parakeetTDTv3,
                    title: descriptor?.displayName ?? "FluidAudio Parakeet TDT",
                    source: .huggingFace,
                    approximateBytes: descriptor?.approximateDownloadBytes ?? 483_307_520
                ),
                consent: consent,
                errorMessage: error.localizedDescription
            )
        }
    }
}
