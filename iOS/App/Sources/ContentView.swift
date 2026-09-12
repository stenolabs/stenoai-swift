import StenoDomain
import SwiftUI

/// The app's frame.
///
/// `NavigationSplitView` on purpose, not a stack: in compact width it collapses
/// to a stack by itself, so iPhone and iPad are two states of one hierarchy
/// rather than two view trees to maintain.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var meetingTransferSceneID = MeetingTransferSceneID()
    @State private var restoreFailure: String?
    @State private var dismissedUndoID: UUID?
    @State private var sidebarRevealEvents = IOSSidebarRevealEventState()

    /// Each window starts on Home with an explicit matching sidebar selection.
    @State private var router = NavigationRouter()

    /// Explicit rather than left to `NavigationSplitView`'s own default: once
    /// the sidebar collapses (a compact rotation, a manual swipe) it has no
    /// other way back without this binding.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        VStack(spacing: 0) {
            // Only when the user is somewhere else. On the recording screen
            // itself the strip would repeat what fills the screen already.
            if model.recording.isActive, router.selection != .recording {
                RecordingStrip { router.selection = .recording }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            startupBanners
            trashUndoBanner
            splitView
        }
        .alert("Restore meeting", isPresented: Binding(get: { restoreFailure != nil }, set: { if !$0 { restoreFailure = nil } })) {
            Button("OK") { restoreFailure = nil }
        } message: { Text(restoreFailure ?? "") }
        .animation(.default, value: model.recording.isActive)
        .focusedSceneValue(router)
        .alert(
            router.meetingActionAlert?.title ?? "Meeting",
            isPresented: meetingActionAlertIsPresented
        ) {
            Button("OK") { router.meetingActionAlert = nil }
        } message: {
            Text(router.meetingActionAlert?.message ?? "")
        }
        .onAppear {
            model.registerMeetingTransferScene(meetingTransferSceneID)
        }
        .onDisappear {
            model.unregisterMeetingTransferScene(meetingTransferSceneID)
        }
        .onOpenURL { url in
            guard url.pathExtension.caseInsensitiveCompare("stenomeeting") == .orderedSame else {
                return
            }
            model.previewMeetingPackage(at: url, sceneID: meetingTransferSceneID)
        }
        .onChange(of: model.selectedMeetingID) { _, _ in
            consumeSelectedMeetingIfAvailable()
        }
        .onChange(of: model.meetings.map(\.id), initial: true) { _, _ in
            consumeSelectedMeetingIfAvailable()
        }
        .onChange(of: model.removedMeetingIDs, initial: true) { _, removedMeetingIDs in
            router.reconcileSelectedMeeting(removedMeetingIDs: removedMeetingIDs)
        }
        .task {
            consumeSelectedMeetingIfAvailable()
        }
        .sheet(
            isPresented: Binding(
                get: { model.isPresentingMeetingTransfer(in: meetingTransferSceneID) },
                set: { if !$0 { model.dismissMeetingTransferSheet(for: meetingTransferSceneID) } }
            )
        ) {
            MeetingTransferImportSheet(sceneID: meetingTransferSceneID)
                .environment(model)
        }
    }

    @ViewBuilder
    private var trashUndoBanner: some View {
        if let receipt = model.pendingTrashUndo, receipt.id != dismissedUndoID {
            HStack(spacing: 12) {
                Text("Moved to Trash").lineLimit(1)
                Spacer(minLength: 0)
                Button("Undo") {
                    Task {
                        do {
                            if let id = try await model.restoreLastTrashedMeeting() { router.select(.meeting(id)) }
                        } catch { restoreFailure = String(localized: "The meeting could not be restored.") }
                    }
                }
                .frame(minHeight: 44)
                .fixedSize(horizontal: true, vertical: false)
                .disabled(model.libraryActionIsInFlight)
                .accessibilityHint(receipt.title)
                Button("Dismiss", systemImage: "xmark") { dismissedUndoID = receipt.id }
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .padding(.horizontal)
            .background(.bar)
        }
    }

    private func consumeSelectedMeetingIfAvailable() {
        guard let meetingID = model.consumeSelectedMeetingIDIfAvailable(
            for: meetingTransferSceneID
        ) else {
            return
        }
        sidebarRevealEvents.request(meetingID)
    }

    private var meetingActionAlertIsPresented: Binding<Bool> {
        Binding(
            get: { router.meetingActionAlert != nil },
            set: { if !$0 { router.meetingActionAlert = nil } }
        )
    }

    private func completeSidebarReveal(
        _ request: IOSSidebarRevealRequest,
        selection: SidebarItem
    ) {
        guard selection == .meeting(request.meetingID),
              sidebarRevealEvents.consume(request)
        else { return }
        router.selection = sizeClass == .compact
            ? MeetingTransferNavigation.compactSelection(for: request.meetingID)
            : MeetingTransferNavigation.splitSelection(for: request.meetingID)
    }

    private var splitView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            MeetingSidebarView(
                selection: $router.selection,
                router: router,
                revealRequest: sidebarRevealEvents.pending,
                onRevealApplied: completeSidebarReveal
            )
        } detail: {
            startupDetail
        }
    }

    @ViewBuilder
    private var startupBanners: some View {
        ForEach(model.startupWarnings.indices, id: \.self) { index in
            Label {
                Text(model.startupWarnings[index].message)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(.callout)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
        ForEach(model.libraryIssues) { issue in
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Label {
                    Text(issue.explanation)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(issue.retryTitle) {
                    Task { await model.retryLibraryIssue(issue) }
                }
                .buttonStyle(.bordered)
            }
            .font(.callout)
            .foregroundStyle(Steno.Colors.error)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
        if let notice = model.actionNotice {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Label {
                    Text(notice.message)
                } icon: {
                    Image(systemName: "info.circle")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Dismiss") { model.clearActionNotice() }
                    .buttonStyle(.borderless)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    @ViewBuilder
    private var startupDetail: some View {
        switch model.startupState {
        case .opening:
            IOSStartupOpeningView()
        case .failed(let failure):
            IOSStartupFailedView(failure: failure) {
                await model.retryStartup()
            }
        case .ready:
            selectedDetail
        }
    }

    @ViewBuilder
    private var selectedDetail: some View {
        switch router.selection?.detailRoute {
            case .chat:
                LibraryChatView()
            case .home:
                HomeView(router: router)
            case .meeting(let id):
                if model.meetings.contains(where: { $0.id == id }) {
                    MeetingDetailView(
                        meetingID: id,
                        router: router,
                        showAudioReadiness: { router.selection = .readiness }
                    )
                } else {
                    ContentUnavailableView(
                        "Meeting not found",
                        systemImage: "questionmark.folder"
                    )
                }
            case .readiness:
                AudioReadinessView(session: model.audioSession)
            case .languageModels:
                TextModelSettingsView()
            case .transcriptionModels:
                TranscriptionModelSettingsView()
            case .demoData:
                DemoDataSettingsView()
            case .recording, .none:
                RecordingView(showReadiness: { router.selection = .readiness })
        }
    }
}

struct IOSStartupOpeningView: View {
    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text(IOSStartupState.opening.title)
                .font(.headline)
            Text("Steno is checking and opening the local library.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .navigationTitle("Steno")
    }
}

struct IOSStartupFailedView: View {
    let failure: IOSStartupFailure
    let retry: () async -> Void

    var body: some View {
        ContentUnavailableView {
            Label(failure.title, systemImage: "externaldrive.badge.xmark")
        } description: {
            Text(failure.explanation)
        } actions: {
            Button("Try Again") {
                Task { await retry() }
            }
            .buttonStyle(.borderedProminent)
        }
        .navigationTitle("Steno")
    }
}

/// One selection type for both widths.
///
/// `NavigationSplitView` only pushes in compact width when the sidebar row is
/// an actual selection; a button that quietly swaps the detail view works on
/// iPad and does nothing visible on iPhone. Routing meetings and tools through
/// the same selection keeps both widths on one mechanism.
enum SidebarItem: Hashable {
    case meeting(MeetingID)
    case chat
    case home
    case recording
    case readiness
    case languageModels
    case transcriptionModels
    case demoData

    var detailRoute: SidebarDetailRoute {
        switch self {
        case .meeting(let meetingID):
            .meeting(meetingID)
        case .chat:
            .chat
        case .home:
            .home
        case .recording:
            .recording
        case .readiness:
            .readiness
        case .languageModels:
            .languageModels
        case .transcriptionModels:
            .transcriptionModels
        case .demoData:
            .demoData
        }
    }

    var toolTitle: String {
        switch self {
        case .demoData:
            String(localized: DemoDataPresentation.toolTitle)
        default:
            ""
        }
    }

    var systemImage: String {
        switch self {
        case .demoData: "rectangle.3.group"
        default: ""
        }
    }
}

enum SidebarDetailRoute: Equatable {
    case meeting(MeetingID)
    case chat
    case home
    case recording
    case readiness
    case languageModels
    case transcriptionModels
    case demoData
}

/// Importe verwenden in beiden Breiten dieselbe vorhandene Navigation statt
/// eine Detail-Sonderroute zu praesentieren.
enum MeetingTransferNavigation {
    static func compactSelection(for meetingID: MeetingID) -> SidebarItem {
        .meeting(meetingID)
    }

    static func splitSelection(for meetingID: MeetingID) -> SidebarItem {
        .meeting(meetingID)
    }
}
