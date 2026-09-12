import Foundation
import StenoDomain
import StenoLibrary
import SwiftUI

/// Persistiert ausschließlich bewusste Disclosure-Aktionen.
/// Temporäre Such- und Reveal-Zustände werden von der View getrennt berechnet.
@MainActor
struct IOSFolderDisclosureStore {
    private static let key = "steno.ios.sidebar.expandedFolders"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> Set<FolderID> {
        Set((defaults.stringArray(forKey: Self.key) ?? []).compactMap { value in
            UUID(uuidString: value).map(FolderID.init(rawValue:))
        })
    }

    @discardableResult
    func setExpanded(
        _ isExpanded: Bool,
        for folderID: FolderID
    ) -> Set<FolderID> {
        var folderIDs = load()
        if isExpanded {
            folderIDs.insert(folderID)
        } else {
            folderIDs.remove(folderID)
        }
        write(folderIDs)
        return folderIDs
    }

    @discardableResult
    func add(_ additions: Set<FolderID>) -> Set<FolderID> {
        var folderIDs = load()
        folderIDs.formUnion(additions)
        write(folderIDs)
        return folderIDs
    }

    @discardableResult
    func remove(_ folderID: FolderID) -> Set<FolderID> {
        var folderIDs = load()
        folderIDs.remove(folderID)
        write(folderIDs)
        return folderIDs
    }

    private func write(_ folderIDs: Set<FolderID>) {
        defaults.set(
            folderIDs.map(\.description).sorted(),
            forKey: Self.key
        )
    }
}

@MainActor
enum IOSSidebarRevealApplication {
    /// Schreibt die bestaetigte Elternkette zuerst und meldet die vorhandene
    /// Meetingroute erst danach als navigationsbereit.
    @discardableResult
    static func apply(
        _ request: IOSSidebarRevealRequest,
        presentation: IOSMeetingSidebarPresentation,
        disclosureStore: IOSFolderDisclosureStore,
        updateExpansion: (Set<FolderID>) -> Void,
        selectionReady: (IOSSidebarRevealRequest, SidebarItem) -> Void
    ) -> Bool {
        guard let reveal = presentation.navigationReveal(
            for: request.meetingID,
            persisted: []
        ) else { return false }
        let expanded = disclosureStore.add(reveal.expandedFolderIDs)
        updateExpansion(expanded)
        selectionReady(request, reveal.selection)
        return true
    }
}

/// Ein ruhiger Archivbaum fuer iPhone und iPad.
///
/// Ordner sind reine Disclosure-Zeilen. Nur Meetings und Werkzeuge tragen
/// Navigationswerte, damit `.meeting` die einzige Detailroute bleibt.
struct MeetingSidebarView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: SidebarItem?
    let router: NavigationRouter
    let revealRequest: IOSSidebarRevealRequest?
    let onRevealApplied: (IOSSidebarRevealRequest, SidebarItem) -> Void

    @State private var query = ""
    @State private var searchAllContent = true
    @State private var contentHits: [MeetingContentGroup] = []
    @State private var searchFailure = false
    @State private var searchingContent = false
    @State private var showsRecentlyDeleted = false
    @State private var persistedExpandedFolderIDs = IOSFolderDisclosureStore().load()
    @State private var folderNameOperation: FolderNameOperation?
    @State private var folderName = ""
    @State private var folderDeleteTarget: Folder?
    @State private var retranscribeTarget: Meeting?
    @State private var deleteTarget: Meeting?
    @State private var actionAlert: MeetingActionAlert?
    @State private var targetedFolderID: FolderID?
    @State private var isFoldersHeadingTargeted = false
    @State private var targetedUnfiledSectionID: String?

    private let disclosureStore = IOSFolderDisclosureStore()

    var body: some View {
        actionPresentationContent
            .sheet(isPresented: $showsRecentlyDeleted) {
                RecentlyDeletedView { id in router.select(.meeting(id)) }
            }
    }

    private var navigationContent: some View {
        List(selection: $selection) {
            Section {
                NavigationLink(value: SidebarItem.home) {
                    Label("Home", systemImage: "house")
                }
                NavigationLink(value: SidebarItem.chat) {
                    Label("Chat", systemImage: "bubble.left.and.bubble.right")
                }
                Button { showsRecentlyDeleted = true } label: {
                    Label("Recently deleted", systemImage: "trash")
                }
            }
            if !model.libraryIssues.isEmpty {
                Section("Library") {
                    ForEach(model.libraryIssues) { issue in
                        Label {
                            Text(issue.title)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle")
                        }
                        .font(.body)
                        .foregroundStyle(Steno.Colors.error)
                        Button(issue.retryTitle) {
                            Task { await model.retryLibraryIssue(issue) }
                        }
                    }
                }
            }
            if model.backgroundProcessingDeferred {
                Section("Processing") {
                    Label {
                        Text(
                            "Paused in the background. It finishes when you return to Steno."
                        )
                    } icon: {
                        Image(systemName: "moon.zzz")
                    }
                    .font(.body)
                    .foregroundStyle(.secondary)
                }
            }

            if isSearching && searchAllContent && !searchFailure {
                Section("Search results") {
                    if searchingContent { ProgressView() }
                    ForEach(contentHits.filter { hit in model.meetings.contains { $0.id == hit.meetingID } }, id: \.meetingID) { hit in
                        if let meeting = model.meetings.first(where: { $0.id == hit.meetingID }) {
                            NavigationLink(value: SidebarItem.meeting(meeting.id)) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(meeting.title).font(.headline)
                                    if let snippet = hit.hits.first?.snippet {
                                        Text(snippet).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                    }
                                }
                            }
                        }
                    }
                    if !searchingContent && contentHits.isEmpty {
                        Text("No results").foregroundStyle(.secondary)
                    }
                }
            } else {
                Section {
                    foldersHeading
                    ForEach(presentation.tree.folderNodes) { node in
                        rootFolder(node)
                    }
                }

                if presentation.tree.folderNodes.isEmpty,
                   presentation.tree.unfiledSections.isEmpty
                {
                    Section {
                        Text(emptyMeetingMessage)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .selectionDisabled()
                    }
                }

                ForEach(presentation.tree.unfiledSections) { section in
                    Section {
                        ForEach(section.meetings, id: \.id) { meeting in
                            meetingRow(meeting)
                        }
                    } header: {
                        unfiledSectionHeader(section)
                    }
                }
            }

            Section("Tools") {
                NavigationLink(value: SidebarItem.recording) {
                    Label("Record", systemImage: "record.circle")
                }
                NavigationLink(value: SidebarItem.readiness) {
                    Label("Audio readiness", systemImage: "waveform")
                }
                NavigationLink(value: SidebarItem.languageModels) {
                    Label("Language models", systemImage: "brain")
                }
                NavigationLink(value: SidebarItem.transcriptionModels) {
                    Label("Transcription models", systemImage: "waveform.and.mic")
                }
                NavigationLink(value: SidebarItem.demoData) {
                    Label(DemoDataPresentation.toolTitle, systemImage: SidebarItem.demoData.systemImage)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Steno")
        .searchable(text: $query, prompt: searchAllContent ? "Search All Content" : "Search Titles")
        .safeAreaInset(edge: .top) {
            if isSearching {
                VStack {
                    Picker("Search scope", selection: $searchAllContent) {
                        Text("Titles").tag(false)
                        Text("All Content").tag(true)
                    }
                    .pickerStyle(.segmented)
                    if searchFailure {
                        Text("Content search is unavailable. Showing title matches.").font(.caption)
                    }
                }
                .padding(.horizontal)
            }
        }
        .task(id: IOSContentSearchRequest(query: query, allContent: searchAllContent,
                                          runtimeGeneration: model.runtimeSnapshot()?.generation,
                                          meetings: model.meetings)) {
            contentHits = []
            searchFailure = false
            guard isSearching, searchAllContent else { searchingContent = false; return }
            searchingContent = true
            do {
                try await Task.sleep(for: .milliseconds(200))
                let groups = try await model.searchMeetingContents(query)
                try Task.checkCancellation()
                let titleMatches = MeetingSearch.matching(model.meetings, query: query)
                let indexedIDs = Set(groups.map(\.meetingID))
                contentHits = titleMatches.filter { !indexedIDs.contains($0.id) }.map {
                    MeetingContentGroup(meetingID: $0.id, hits: [])
                } + groups
                searchingContent = false
            } catch is CancellationError {
                if !Task.isCancelled { searchingContent = false }
            } catch {
                guard !Task.isCancelled else { return }
                searchFailure = true
                searchingContent = false
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                newMeetingButton
            }
        }
        .onChange(of: revealRequest, initial: true) { _, request in
            guard let request else { return }
            revealMeeting(request)
        }
    }

    private var actionPresentationContent: some View {
        AnyView(navigationContent)
        .alert(
            folderNameOperation?.title ?? "Folder",
            isPresented: folderNameOperationIsPresented
        ) {
            TextField("Name", text: $folderName)
            Button("Cancel", role: .cancel) {}
            Button(folderNameOperation?.actionTitle ?? "Save") {
                commitFolderNameOperation()
            }
            .disabled(normalizedFolderName.isEmpty)
        } message: {
            if let message = folderNameOperation?.message {
                Text(message)
            }
        }
        .confirmationDialog(
            folderDeleteTarget.flatMap {
                presentation.folderDeletionConfirmation(for: $0.id)?.title
            } ?? "Delete folder?",
            isPresented: folderDeleteIsPresented,
            titleVisibility: .visible,
            presenting: folderDeleteTarget
        ) { folder in
            Button("Delete Folder", role: .destructive) {
                deleteFolder(folder)
            }
            Button("Cancel", role: .cancel) {}
        } message: { folder in
            if let confirmation = presentation.folderDeletionConfirmation(
                for: folder.id
            ) {
                Text(confirmation.message)
            }
        }
        .alert(
            retranscribeTarget.map {
                MeetingActionCopy.retranscriptionTitle(meetingTitle: $0.title)
            } ?? "",
            isPresented: retranscribeTargetIsPresented,
            presenting: retranscribeTarget
        ) { meeting in
            Button("Transcribe Again") {
                retranscribeTarget = nil
                Task {
                    do {
                        try await model.requestRetranscription(meetingID: meeting.id)
                        selection = .meeting(meeting.id)
                    } catch {
                        actionAlert = .retranscriptionFailure(error.localizedDescription)
                    }
                }
            }
            Button("Cancel", role: .cancel) { retranscribeTarget = nil }
        } message: { _ in
            Text(MeetingActionCopy.retranscriptionMessage)
        }
        .confirmationDialog(
            deleteTarget.map {
                MeetingActionCopy.deletionTitle(meetingTitle: $0.title)
            } ?? "",
            isPresented: deleteTargetIsPresented,
            titleVisibility: .visible,
            presenting: deleteTarget
        ) { meeting in
            Button(MeetingActionCopy.deletionConfirmationLabel, role: .destructive) {
                deleteTarget = nil
                deleteMeeting(meeting)
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: { _ in
            Text(MeetingActionCopy.deletionMessage)
        }
        .alert(
            actionAlert?.title ?? "Meeting",
            isPresented: actionAlertIsPresented
        ) {
            Button("OK") { actionAlert = nil }
        } message: {
            Text(actionAlert?.message ?? "")
        }
    }

    private var newMeetingButton: some View {
        Menu {
            Button {
                selection = .recording
                let actions = StenoCommandActions(model: model)
                Task { await actions.start() }
            } label: {
                Label("Start Recording", systemImage: "record.circle")
            }
            .disabled(!StenoCommandState(model: model, router: router).canStartRecording)

            Button {
                let destinationRouter = router
                let actions = StenoCommandActions(model: model)
                Task { await actions.createDraft(in: destinationRouter) }
            } label: {
                Label("New Meeting Notes", systemImage: "note.text.badge.plus")
            }
            .disabled(!StenoCommandState(model: model, router: router).canCreateDraft)
        } label: {
            Label("New Meeting", systemImage: "plus")
        }
        .accessibilityLabel("New Meeting")
        .accessibilityHint("Choose whether to start recording or create meeting notes.")
        .accessibilityIdentifier("meeting-new")
    }

    private var presentation: IOSMeetingSidebarPresentation {
        IOSMeetingSidebarPresentation(
            folders: model.folders,
            meetings: model.meetings,
            query: query
        )
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var effectiveExpandedFolderIDs: Set<FolderID> {
        presentation.effectiveExpandedFolderIDs(
            persisted: persistedExpandedFolderIDs
        )
    }

    private var emptyMeetingMessage: LocalizedStringResource {
        IOSMeetingSidebarPresentation.emptyMeetingMessage(
            isReady: model.isReady,
            query: query
        )
    }

    // MARK: - Folders

    private var foldersHeading: some View {
        let dropSurface = IOSSidebarNoFolderDropSurface.foldersHeading
        return HStack(spacing: Steno.Space.s) {
            Label("Folders", systemImage: "folder")
                .font(.headline)
            Spacer(minLength: Steno.Space.s)
            Button {
                beginCreatingFolder(parentFolderID: nil)
            } label: {
                Image(systemName: "folder.badge.plus")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Steno.Colors.brand)
            .disabled(model.runtime == nil)
            .accessibilityLabel("Create folder")
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
        .selectionDisabled()
        .accessibilityIdentifier("meeting-sidebar-folders-heading")
        .accessibilityHint(dropSurface.accessibilityHint)
        .contextMenu {
            Button {
                beginCreatingFolder(parentFolderID: nil)
            } label: {
                Label("New Folder\u{2026}", systemImage: "folder.badge.plus")
            }
            .disabled(model.runtime == nil)
        }
        .dropDestination(for: IOSSidebarDragPayload.self) { payloads, _ in
            acceptDrop(payloads, onto: dropSurface)
        } isTargeted: { targeted in
            isFoldersHeadingTargeted = targeted
        }
        .listRowBackground(
            isFoldersHeadingTargeted
                ? Steno.Colors.brand.opacity(0.12)
                : Color.clear
        )
    }

    private func unfiledSectionHeader(
        _ section: MeetingSection
    ) -> some View {
        let dropSurface = IOSSidebarNoFolderDropSurface.unfiledSection(section.id)
        let isTargeted = targetedUnfiledSectionID == section.id
        return Text(section.title)
            .font(.caption)
            .foregroundStyle(isTargeted ? Steno.Colors.brand : Color.secondary)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
            .accessibilityHint(dropSurface.accessibilityHint)
            .dropDestination(for: IOSSidebarDragPayload.self) { payloads, _ in
                acceptDrop(payloads, onto: dropSurface)
            } isTargeted: { targeted in
                if targeted {
                    targetedUnfiledSectionID = section.id
                } else if targetedUnfiledSectionID == section.id {
                    targetedUnfiledSectionID = nil
                }
            }
            .background(
                isTargeted ? Steno.Colors.brand.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
    }

    private func rootFolder(_ node: MeetingFolderNode) -> some View {
        DisclosureGroup(isExpanded: disclosureBinding(for: node.id)) {
            ForEach(node.children) { child in
                childFolder(child)
            }
            ForEach(node.meetings, id: \.id) { meeting in
                meetingRow(meeting)
            }
            if node.meetings.isEmpty, node.children.isEmpty {
                emptyFolderRow
            }
        } label: {
            folderLabel(node, font: .headline)
                .selectionDisabled()
        }
    }

    private func childFolder(_ node: MeetingFolderNode) -> some View {
        DisclosureGroup(isExpanded: disclosureBinding(for: node.id)) {
            ForEach(node.meetings, id: \.id) { meeting in
                meetingRow(meeting)
            }
            if node.meetings.isEmpty {
                emptyFolderRow
            }
        } label: {
            folderLabel(node, font: .body)
                .selectionDisabled()
        }
    }

    private func folderLabel(
        _ node: MeetingFolderNode,
        font: Font
    ) -> some View {
        let isTargeted = targetedFolderID == node.id
        return HStack(spacing: Steno.Space.s) {
            Label {
                Text(node.folder.name)
            } icon: {
                folderIcon(node.folder)
            }
            .font(font)
            Spacer(minLength: Steno.Space.s)
            Menu {
                folderMenu(node.folder)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Folder actions for \(node.folder.name)")
        }
            .foregroundStyle(isTargeted ? Steno.Colors.brand : Color.primary)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
            .contextMenu { folderMenu(node.folder) }
            .accessibilityIdentifier("meeting-sidebar-folder-\(node.id.description)")
            .accessibilityValue(
                "\(node.meetings.count) direct meetings, \(node.children.count) subfolders"
            )
            .draggable(IOSSidebarDragPayload.folder(node.id))
            .dropDestination(for: IOSSidebarDragPayload.self) { payloads, _ in
                acceptDrop(payloads, ontoFolder: node.id)
            } isTargeted: { targeted in
                if targeted {
                    targetedFolderID = node.id
                } else if targetedFolderID == node.id {
                    targetedFolderID = nil
                }
            }
            .background(
                isTargeted ? Steno.Colors.brand.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
    }

    /// Renders the folder's chosen symbol tinted with its color token. A
    /// folder without an explicit icon or color keeps the default look.
    private func folderIcon(_ folder: Folder) -> some View {
        Image(
            systemName: folder.icon?.rawValue ?? "folder"
        )
        .foregroundStyle(folder.colorToken?.sidebarColor ?? Color.primary)
    }

    private func setFolderColor(_ token: FolderColorToken?, of folder: Folder) {
        Task {
            await model.setFolderColor(token, of: folder.id)
        }
    }

    private func setFolderIcon(_ icon: FolderIcon?, of folder: Folder) {
        Task {
            await model.setFolderIcon(icon, of: folder.id)
        }
    }

    private var emptyFolderRow: some View {
        Text("No meetings")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .selectionDisabled()
    }

    @ViewBuilder
    private func folderMenu(_ folder: Folder) -> some View {
        if let policy = presentation.folderActionPolicy(for: folder.id) {
            if policy.canCreateChild {
                Button {
                    beginCreatingFolder(parentFolderID: folder.id)
                } label: {
                    Label("New Subfolder\u{2026}", systemImage: "folder.badge.plus")
                }
            }

            Button {
                beginRenamingFolder(folder)
            } label: {
                Label("Rename\u{2026}", systemImage: "pencil")
            }

            Menu("Color", systemImage: "paintpalette") {
                Button("None") {
                    setFolderColor(nil, of: folder)
                }
                ForEach(FolderColorToken.allCases, id: \.self) { token in
                    Button(token.rawValue.capitalized) {
                        setFolderColor(token, of: folder)
                    }
                }
            }
            Menu("Icon", systemImage: "square.grid.2x2") {
                Button("Default") {
                    setFolderIcon(nil, of: folder)
                }
                ForEach(FolderIcon.allCases, id: \.self) { icon in
                    Button {
                        setFolderIcon(icon, of: folder)
                    } label: {
                        Label(icon.rawValue, systemImage: icon.rawValue)
                    }
                }
            }
            Divider()

            Button {
                moveFolder(folder.id, up: true)
            } label: {
                Label("Move Up", systemImage: "arrow.up")
            }
            .disabled(!policy.canMoveUp)

            Button {
                moveFolder(folder.id, up: false)
            } label: {
                Label("Move Down", systemImage: "arrow.down")
            }
            .disabled(!policy.canMoveDown)

            if !policy.parentDestinations.isEmpty {
                Menu("Move into Folder", systemImage: "folder") {
                    ForEach(policy.parentDestinations) { destination in
                        Button(destination.title) {
                            execute(.moveFolder(folder.id, destination.folderID))
                        }
                    }
                }
            }

            if policy.canMoveToRoot {
                Button {
                    execute(.moveFolder(folder.id, nil))
                } label: {
                    Label("Move to Top Level", systemImage: "arrow.up.to.line")
                }
            }

            Divider()

            Button(role: .destructive) {
                folderDeleteTarget = folder
            } label: {
                Label("Delete Folder\u{2026}", systemImage: "trash")
            }
        }
    }

    private func disclosureBinding(for folderID: FolderID) -> Binding<Bool> {
        Binding(
            get: { effectiveExpandedFolderIDs.contains(folderID) },
            set: { isExpanded in
                guard !isSearching else { return }
                persistedExpandedFolderIDs = disclosureStore.setExpanded(
                    isExpanded,
                    for: folderID
                )
            }
        )
    }

    // MARK: - Meetings

    private func meetingRow(_ meeting: Meeting) -> some View {
        NavigationLink(value: SidebarItem.meeting(meeting.id)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title)
                    .font(.body)
                    .lineLimit(2)
                DemoBadge(meeting: meeting)
                Text(
                    meeting.createdAt,
                    format: .dateTime.day().month().hour().minute()
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .accessibilityIdentifier("meeting-sidebar-meeting-\(meeting.id.description)")
        .contextMenu { meetingMenu(meeting) }
        .draggable(IOSSidebarDragPayload.meeting(meeting.id))
    }

    @ViewBuilder
    private func meetingMenu(_ meeting: Meeting) -> some View {
        let policy = presentation.meetingActionPolicy(for: meeting.id)
        Menu("Move to Folder", systemImage: "folder") {
            IOSMeetingMoveActions(policy: policy) { folderID in
                execute(.moveMeeting(meeting.id, folderID))
            }
        }
        Divider()
        Button {
            retranscribeTarget = meeting
        } label: {
            Label("Transcribe Again...", systemImage: "waveform")
        }
        .disabled(!MeetingActionPolicy.canRetranscribe(status: meeting.status))

        Divider()

        Button(role: .destructive) {
            deleteTarget = meeting
        } label: {
            Label("Move to Trash...", systemImage: "trash")
        }
        .disabled(!MeetingActionPolicy.canDelete(status: meeting.status))
    }

    // MARK: - Mutations

    private func acceptDrop(
        _ payloads: [IOSSidebarDragPayload],
        ontoFolder destinationFolderID: FolderID
    ) -> Bool {
        guard payloads.count == 1 else { return false }
        let decision = presentation.dropDecision(
            for: payloads[0],
            ontoFolder: destinationFolderID
        )
        guard decision != .reject else { return false }
        execute(decision)
        return true
    }

    private func acceptDrop(
        _ payloads: [IOSSidebarDragPayload],
        onto surface: IOSSidebarNoFolderDropSurface
    ) -> Bool {
        guard payloads.count == 1 else { return false }
        let decision = presentation.dropDecision(
            for: payloads[0],
            onto: surface
        )
        guard decision != .reject else { return false }
        execute(decision)
        return true
    }

    private func execute(_ decision: IOSSidebarDropDecision) {
        switch decision {
        case let .moveMeeting(meetingID, folderID):
            Task {
                guard await model.moveMeeting(meetingID, to: folderID) else { return }
                if let folderID {
                    revealFolder(folderID)
                }
            }
        case let .moveFolder(folderID, parentFolderID):
            Task {
                guard await model.moveFolder(folderID, to: parentFolderID) else { return }
                revealFolder(folderID)
            }
        case .reject:
            break
        }
    }

    private func moveFolder(_ folderID: FolderID, up: Bool) {
        Task {
            guard await model.moveFolder(folderID, up: up) else { return }
            revealFolder(folderID)
        }
    }

    private func beginCreatingFolder(parentFolderID: FolderID?) {
        folderName = ""
        folderNameOperation = .create(parentFolderID: parentFolderID)
    }

    private func beginRenamingFolder(_ folder: Folder) {
        folderName = folder.name
        folderNameOperation = .rename(folder)
    }

    private var normalizedFolderName: String {
        folderName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commitFolderNameOperation() {
        guard let operation = folderNameOperation,
              !normalizedFolderName.isEmpty
        else { return }
        let name = normalizedFolderName
        switch operation {
        case .create(let parentFolderID):
            Task {
                guard let folder = await model.createFolder(
                    named: name,
                    parentFolderID: parentFolderID
                ) else { return }
                revealFolder(folder.id)
            }
        case .rename(let folder):
            Task {
                _ = await model.renameFolder(folder.id, to: name)
            }
        }
    }

    private func deleteFolder(_ folder: Folder) {
        Task {
            guard await model.deleteFolder(folder.id) else { return }
            persistedExpandedFolderIDs = disclosureStore.remove(folder.id)
        }
    }

    private func deleteMeeting(_ meeting: Meeting) {
        Task {
            do {
                let outcome = try await model.deleteMeeting(meeting.id)
                if selection == .meeting(meeting.id) {
                    selection = .recording
                }
                if let warning = outcome.cleanupWarning {
                    actionAlert = .cleanupWarning(warning)
                }
            } catch {
                actionAlert = .deletionFailure(error.localizedDescription)
            }
        }
    }

    private func revealMeeting(_ request: IOSSidebarRevealRequest) {
        IOSSidebarRevealApplication.apply(
            request,
            presentation: presentation,
            disclosureStore: disclosureStore,
            updateExpansion: { expanded in
                persistedExpandedFolderIDs = expanded
            },
            selectionReady: onRevealApplied
        )
    }

    private func revealFolder(_ folderID: FolderID) {
        let expanded = presentation.expandedFolderIDs(
            revealing: folderID,
            persisted: []
        )
        guard !expanded.isEmpty else { return }
        persistedExpandedFolderIDs = disclosureStore.add(expanded)
    }

    private var folderNameOperationIsPresented: Binding<Bool> {
        Binding(
            get: { folderNameOperation != nil },
            set: { if !$0 { folderNameOperation = nil } }
        )
    }

    private var folderDeleteIsPresented: Binding<Bool> {
        Binding(
            get: { folderDeleteTarget != nil },
            set: { if !$0 { folderDeleteTarget = nil } }
        )
    }

    private var retranscribeTargetIsPresented: Binding<Bool> {
        Binding(
            get: { retranscribeTarget != nil },
            set: { if !$0 { retranscribeTarget = nil } }
        )
    }

    private var deleteTargetIsPresented: Binding<Bool> {
        Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )
    }

    private var actionAlertIsPresented: Binding<Bool> {
        Binding(
            get: { actionAlert != nil },
            set: { if !$0 { actionAlert = nil } }
        )
    }
}

private enum FolderNameOperation: Identifiable {
    case create(parentFolderID: FolderID?)
    case rename(Folder)

    var id: String {
        switch self {
        case .create(let parentFolderID):
            parentFolderID.map { "create:\($0.description)" } ?? "create:root"
        case .rename(let folder):
            "rename:\(folder.id.description)"
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .create(let parentFolderID):
            parentFolderID == nil ? "New Folder" : "New Subfolder"
        case .rename:
            "Rename Folder"
        }
    }

    var actionTitle: LocalizedStringResource {
        switch self {
        case .create: "Create"
        case .rename: "Rename"
        }
    }

    var message: LocalizedStringResource? {
        switch self {
        case .create(let parentFolderID) where parentFolderID != nil:
            "Subfolders can contain meetings but no further folders."
        case .create, .rename:
            nil
        }
    }
}

extension FolderColorToken {
    /// The fixed sidebar tint for the token. Deliberately not derived from
    /// system accent colors so every folder keeps a recognizable hue.
    fileprivate var sidebarColor: Color {
        switch self {
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .teal: .teal
        }
    }
}

private struct IOSContentSearchRequest: Equatable {
    let query: String
    let allContent: Bool
    let runtimeGeneration: UInt64?
    let meetings: [Meeting]
}
