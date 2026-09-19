import Foundation
import Observation
import StenoDomain
import StenoPipeline
import UIKit

/// A system-granted slice of background execution time.
struct BackgroundActivityToken: Hashable, Sendable {
    let rawValue: Int
    init(rawValue: Int) { self.rawValue = rawValue }
}

/// Seam over `UIApplication.beginBackgroundTask` so the deferral policy in
/// `BackgroundProcessingCoordinator` can be tested without a running
/// application. The UIKit implementation maps tokens onto the system's
/// numeric identifiers.
@MainActor
protocol BackgroundActivityProviding: Sendable {
    /// Requests background time. Returns `nil` when the system refuses,
    /// which the coordinator treats as an immediate deferral.
    func begin(
        expirationHandler: @escaping @MainActor @Sendable () async -> Void
    ) -> BackgroundActivityToken?
    func end(_ token: BackgroundActivityToken)
}

struct UIKitBackgroundActivityProvider: BackgroundActivityProviding {
    func begin(
        expirationHandler: @escaping @MainActor @Sendable () async -> Void
    ) -> BackgroundActivityToken? {
        var tokenID: UIBackgroundTaskIdentifier = .invalid
        tokenID = UIApplication.shared.beginBackgroundTask(withName: "Steno pipeline") {
            Task { @MainActor in
                await expirationHandler()
            }
        }
        guard tokenID != .invalid else { return nil }
        return BackgroundActivityToken(rawValue: tokenID.rawValue)
    }

    func end(_ token: BackgroundActivityToken) {
        UIApplication.shared.endBackgroundTask(
            UIBackgroundTaskIdentifier(rawValue: token.rawValue)
        )
    }
}

/// Best-effort guaranteed completion for post-processing jobs that are
/// running when the app is backgrounded.
///
/// iOS grants a short window of background execution time through
/// `beginBackgroundTask`. While it lasts, the pipeline keeps running. When
/// the window expires, the coordinator stops the pipeline at its safe
/// boundary: `PipelineCoordinator.stop()` awaits the active job's task and
/// releases its lease, and the job store's atomicity means an interrupted
/// job reverts to queued rather than surfacing half-written artifacts. The
/// remaining work resumes on the next foreground entry, and until then the
/// sidebar shows an honest "finishes when you return" notice.
///
/// Recording itself needs none of this: the `audio` background mode keeps
/// capture alive regardless, and live transcription rides along with it.
@MainActor
final class BackgroundProcessingCoordinator {
    /// `nonisolated(unsafe)`: written once during init on the main actor,
    /// read only in `deinit`. The coordinator lives as long as `AppModel`,
    /// i.e. for the whole process, so no teardown race exists in practice.
    nonisolated(unsafe) private var observerTokens: (
        enterBackground: NSObjectProtocol,
        enterForeground: NSObjectProtocol
    )?
    /// The job kinds that were still unfinished when background time ran
    /// out. Empty unless a deferral actually happened; the sidebar reads
    /// this through `AppModel.backgroundProcessingDeferred`.
    private(set) var deferredJobKinds: Set<Job.Kind> = []

    struct PipelineControls: Sendable {
        /// Unfinished pipeline job kinds right now (queued or running).
        let unfinishedKinds: @MainActor @Sendable () async -> Set<Job.Kind>
        /// Graceful pipeline stop at a safe boundary.
        let stop: @MainActor @Sendable () async -> Void
        /// Restarts queue consumption after a deferral-induced stop.
        let resume: @MainActor @Sendable () async -> Void
    }

    private let activityProvider: any BackgroundActivityProviding
    private let controls: PipelineControls
    private let onDeferralChange: @MainActor @Sendable (Bool) -> Void
    private var activeToken: BackgroundActivityToken?
    private var lifecycleTask: Task<Void, Never>?

    init(
        activityProvider: any BackgroundActivityProviding = UIKitBackgroundActivityProvider(),
        observesLifecycleNotifications: Bool = true,
        controls: PipelineControls,
        onDeferralChange: @escaping @MainActor @Sendable (Bool) -> Void = { _ in }
    ) {
        self.activityProvider = activityProvider
        self.controls = controls
        self.onDeferralChange = onDeferralChange
        if observesLifecycleNotifications {
            installLifecycleObservers()
        }
    }

    deinit {
        if let observerTokens {
            NotificationCenter.default.removeObserver(observerTokens.enterBackground)
            NotificationCenter.default.removeObserver(observerTokens.enterForeground)
        }
    }

    private func installLifecycleObservers() {
        let center = NotificationCenter.default
        observerTokens = (
            enterBackground: center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    await self?.handleDidEnterBackground()
                }
            },
            enterForeground: center.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    await self?.handleWillEnterForeground()
                }
            }
        )
    }

    /// Called when the app enters the background. Asks for background time
    /// only when there is something to finish; idle apps burn nothing.
    func handleDidEnterBackground() async {
        await serializeLifecycle { await self.processBackgroundEntry() }
    }

    private func processBackgroundEntry() async {
        guard activeToken == nil else { return }
        let kinds = await controls.unfinishedKinds()
        guard !kinds.isEmpty else { return }
        guard let token = activityProvider.begin(expirationHandler: {
            // Strong self is fine: the handler only lives as long as the
            // background task, which this coordinator ends.
            [self] in await self.handleExpiration()
        }) else {
            // No time granted: defer immediately instead of letting the app
            // be suspended mid-job.
            deferTo(kinds)
            await controls.stop()
            return
        }
        activeToken = token
    }

    /// Called when the app returns to the foreground. Releases any granted
    /// time and resumes work that a deferral had stopped.
    func handleWillEnterForeground() async {
        await serializeLifecycle { await self.processForegroundEntry() }
    }

    private func processForegroundEntry() async {
        if let token = activeToken {
            activityProvider.end(token)
            activeToken = nil
        }
        guard !deferredJobKinds.isEmpty else { return }
        deferredJobKinds = []
        onDeferralChange(false)
        await controls.resume()
    }

    func handleExpiration() async {
        await serializeLifecycle { await self.processExpiration() }
    }

    private func processExpiration() async {
        guard let token = activeToken else { return }
        activeToken = nil
        activityProvider.end(token)
        let kinds = await controls.unfinishedKinds()
        guard !kinds.isEmpty else { return }
        deferTo(kinds)
        await controls.stop()
    }

    /// Main-actor isolation alone does not order operations across suspension
    /// points. In particular, restarting a queue before its stop completes is
    /// ignored by PipelineCoordinator and leaves processing permanently idle.
    private func serializeLifecycle(
        _ operation: @escaping @MainActor () async -> Void
    ) async {
        let previous = lifecycleTask
        let task = Task { @MainActor in
            await previous?.value
            await operation()
        }
        lifecycleTask = task
        await task.value
        if lifecycleTask == task { lifecycleTask = nil }
    }

    private func deferTo(_ kinds: Set<Job.Kind>) {
        deferredJobKinds = kinds
        onDeferralChange(true)
    }
}

// MARK: - AppModel wiring

extension AppModel {
    /// Built once, from `AppModel.init`, like the rest of the model-owned
    /// machinery. The controls always read the *current* runtime, because
    /// library switches replace the runtime underneath a living `AppModel`.
    internal func startBackgroundProcessingCoordinator() {
        backgroundProcessingCoordinator = BackgroundProcessingCoordinator(
            controls: .init(
                unfinishedKinds: { [weak self] in
                    await self?.unfinishedPipelineJobKinds() ?? []
                },
                stop: { [weak self] in
                    await self?.stopPipelineForBackground()
                },
                resume: { [weak self] in
                    await self?.resumePipelineAfterBackground()
                }
            ),
            onDeferralChange: { [weak self] deferred in
                self?.backgroundProcessingDeferred = deferred
            }
        )
    }

    /// Queued or running pipeline work right now, across all meetings.
    func unfinishedPipelineJobKinds() async -> Set<Job.Kind> {
        guard let jobStore = runtime?.jobStore else { return [] }
        let jobs = (try? await jobStore.list()) ?? []
        var kinds: Set<Job.Kind> = []
        for job in jobs where job.status == .queued || job.status == .running {
            kinds.insert(job.kind)
        }
        return kinds
    }

    /// Graceful stop at the pipeline's safe boundary: an interrupted job
    /// reverts to queued via the existing atomicity guarantees and is never
    /// half-written.
    func stopPipelineForBackground() async {
        guard let coordinator = runtime?.coordinator else { return }
        await coordinator.stop()
    }

    /// Restarts queue consumption after a deferral-induced stop. No-op when
    /// the queue is already running (`PipelineCoordinator.start` guards it).
    func resumePipelineAfterBackground() async {
        await runtime?.coordinator.start()
    }
}
