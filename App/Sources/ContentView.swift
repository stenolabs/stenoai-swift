import Foundation
import StenoDomain
import SwiftUI
import UniformTypeIdentifiers

enum MacWindowPresentation {
    static let meetingsTitle: LocalizedStringResource = "Meetings"
    static let minimumContentSize = CGSize(width: 980, height: 560)
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            WindowStableSidebar {
                HomeStatusHeader(model: model)
            } content: {
                MeetingSidebarView(selection: $model.selectedMeetingIDs)
            }
            .navigationSplitViewColumnWidth(
                min: 220,
                ideal: Steno.Layout.sidebarIdealWidth,
                max: 320
            )
        } detail: {
            WindowStableDetail {
                // Aufnahme ist ein Zustand des Meetings, kein Modus der App.
                // Vorher ersetzte sie die ganze Detailflaeche, egal welches
                // Meeting gewaehlt war - ausgerechnet im Gespraech, wo man
                // nachschlagen will, war die Bibliothek unerreichbar. Der Streifen
                // bleibt sichtbar und haelt den Rueckweg offen.
                VStack(spacing: 0) {
                    if model.isRecording {
                        RecordingStrip()
                    }
                    detailContent
                }
            }
            .animation(statusAnimation, value: model.notice)
            .animation(statusAnimation, value: model.startupState)
        }
        .onChange(of: model.pendingTrashUndo, initial: true) { _, window in
            if window != nil { model.registerTrashUndo(with: undoManager) }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if case .failed(let failure) = model.startupState,
                   MacGlobalStatusSurface.startupFailure == .top {
                    MacStartupFailedView(failure: failure) {
                        await model.retryStartup()
                    }
                    .transition(statusTransition(edge: .top))
                }
                if let notice = model.notice,
                   MacGlobalStatusSurface.notice(isError: notice.isError) == .top {
                    noticeBanner(notice)
                        .transition(statusTransition(edge: .top))
                }
                if model.startupState == .ready {
                    ForEach(model.startupWarnings) { warning in
                        MacStartupWarningBanner(warning: warning)
                    }
                    ForEach(model.libraryIssues) { issue in
                        MacLibraryIssueBanner(
                            issue: issue,
                            isRetrying: model.retryingLibraryIssueIDs.contains(issue.id)
                        ) {
                            await model.retryLibraryIssue(issue)
                        }
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $model.wantsAudioImport,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                Task { await model.importAudioFile(at: url) }
            }
        }
        .fileImporter(
            isPresented: $model.wantsMeetingTransferImport,
            allowedContentTypes: [.stenoMeetingTransfer],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    model.previewMeetingPackage(at: url)
                }
            case .failure(let error):
                if (error as? CocoaError)?.code != .userCancelled {
                    model.report(verbatim: AppModel.message("The meeting package could not be opened.", error))
                }
            }
        }
        .onOpenURL { url in
            guard url.pathExtension.caseInsensitiveCompare("stenomeeting") == .orderedSame else {
                return
            }
            model.previewMeetingPackage(at: url)
        }
        .sheet(
            isPresented: Binding(
                get: { model.meetingTransferImportState != nil },
                set: { if !$0 { model.closeMeetingTransferImport() } }
            )
        ) {
            MeetingTransferImportView()
                .environment(model)
                .interactiveDismissDisabled(
                    model.meetingTransferImportState?.isBusy == true
                )
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, !model.isRecording else { return false }
            Task { await model.importAudioFile(at: url) }
            return true
        }
        // Eine Meldungsleiste fuer alles, was der Benutzer erfahren muss,
        // unabhaengig davon, welche Ansicht gerade offen ist. Sie blockiert
        // nicht und verschwindet erst auf Klick.
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                if let trashUndo = model.pendingTrashUndo {
                    HStack(alignment: .bottom) {
                        UndoDeleteToast(
                            window: trashUndo,
                            onUndo: { Task { await model.restoreTrashedMeetings() } },
                            onExpire: { model.expireTrashUndoIfElapsed() }
                        )
                        Spacer()
                    }
                    .padding(.horizontal, Steno.Space.m)
                    .transition(statusTransition(edge: .bottom))
                }
                if let export = model.audioExportActivity,
                   MacGlobalStatusSurface.audioExport == .bottom {
                    audioExportBanner(export)
                        .transition(statusTransition(edge: .bottom))
                }
                if let notice = model.notice,
                   MacGlobalStatusSurface.notice(isError: notice.isError) == .bottom {
                    noticeBanner(notice)
                        .transition(statusTransition(edge: .bottom))
                }
            }
            .animation(statusAnimation, value: model.notice)
            .animation(statusAnimation, value: model.audioExportActivity)
            .animation(statusAnimation, value: model.pendingTrashUndo)
        }
        .overlay {
            if model.isCommandPalettePresented {
                CommandPaletteView(model: model) {
                    model.isCommandPalettePresented = false
                }
            }
        }
        .frame(
            minWidth: MacWindowPresentation.minimumContentSize.width,
            minHeight: MacWindowPresentation.minimumContentSize.height
        )
    }

    private var statusMotionPolicy: MacStatusMotionPolicy {
        MacStatusMotionPolicy(reduceMotion: accessibilityReduceMotion)
    }

    private var statusAnimation: Animation? {
        statusMotionPolicy == .reduced ? nil : .default
    }

    private func statusTransition(edge: Edge) -> AnyTransition {
        guard statusMotionPolicy.usesPositionalMovement else { return .opacity }
        return .move(edge: edge).combined(with: .opacity)
    }

    private func audioExportBanner(_ export: AudioExportActivity) -> some View {
        HStack(spacing: 10) {
            ProgressView(value: export.fraction)
                .frame(width: 120)
            Text("Exporting \(export.fileName) \(Int(export.fraction * 100))%")
                .font(.callout)
                .lineLimit(1)
            Spacer()
        }
        .padding(8)
        .background(.bar)
    }

    private func noticeBanner(_ notice: AppModel.Notice) -> some View {
        HStack(spacing: 8) {
            Image(systemName: notice.isError
                ? "exclamationmark.triangle.fill"
                : "info.circle")
                .foregroundStyle(notice.isError ? Steno.Colors.error : .secondary)
            Text(notice.text)
                .font(.callout)
                .textSelection(.enabled)
            Spacer()
            Button("OK") { model.dismissNotice() }
                .controlSize(.small)
        }
        .padding(8)
        .background(.bar)
    }
}

/// Scrollbare Transkripte und Protokolle duerfen ihre gesamte ideale Hoehe
/// nicht als Mindesthoehe an das Fenster weiterreichen. `GeometryReader`
/// uebernimmt ausschliesslich den bereits verfuegbaren Fensterplatz; der
/// Inhalt bleibt darin normal scrollbar.
struct WindowStableDetail<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        GeometryReader { _ in
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Keeps a dynamic sidebar header and its scrollable content inside the size
/// proposed by `NavigationSplitView`. `GeometryReader` forms a one-way size
/// boundary; inside it, a normal stack gives the list the remaining height
/// without feeding the header's ideal height back into the split view.
struct WindowStableSidebar<Header: View, Content: View>: View {
    private let header: Header
    private let content: Content

    init(
        @ViewBuilder header: () -> Header,
        @ViewBuilder content: () -> Content
    ) {
        self.header = header()
        self.content = content()
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                header
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(
                width: geometry.size.width,
                height: geometry.size.height,
                alignment: .top
            )
        }
    }
}

struct MultiMeetingSelectionView: View {
    let count: Int

    var body: some View {
        ContentUnavailableView {
            Label(
                "\(count) Meetings Selected",
                systemImage: "rectangle.stack.fill"
            )
        } description: {
            Text("Move the selected meetings to a folder or to the Trash.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(MacWindowPresentation.meetingsTitle)
    }
}

extension ContentView {
    @ViewBuilder
    var detailContent: some View {
        switch model.startupState {
        case .opening:
            MacStartupOpeningView()
        case .failed:
            MacStartupUnavailableView()
        case .ready:
            readyDetailContent
        }
    }

    @ViewBuilder
    private var readyDetailContent: some View {
        if model.selectedMeetingIDs.count > 1 {
            MultiMeetingSelectionView(count: model.selectedMeetingIDs.count)
        } else if model.isRecording,
                  model.selectedMeetingID == model.recordingMeetingID
        {
            RecordingView()
                // Ohne Titel steht waehrend der Aufnahme nur "Steno" im
                // Fenster - man sieht nicht, worin man gerade aufnimmt.
                .navigationTitle(recordingTitle)
                .navigationSubtitle("Recording")
        } else if let meetingID = model.selectedMeetingID {
            MeetingDetailView(meetingID: meetingID)
                .id(meetingID)
        } else if model.isRecording {
            // Waehrend einer Aufnahme ohne Auswahl: der Streifen oben sagt
            // schon alles Noetige, hier braucht es keinen zweiten Hinweis auf
            // dieselbe Sache.
            ContentUnavailableView(
                "No meeting selected",
                systemImage: "waveform",
                description: Text("Pick a meeting to look something up while you record.")
            )
            .navigationTitle(MacWindowPresentation.meetingsTitle)
        } else {
            LegacyHomeView()
        }
    }

    var recordingTitle: String {
        model.meetings.first { $0.id == model.recordingMeetingID }?.title
            ?? String(localized: MacWindowPresentation.meetingsTitle)
    }
}
