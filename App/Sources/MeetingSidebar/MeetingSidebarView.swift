import StenoDomain
import StenoLibrary
import SwiftUI

struct MeetingSidebarView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: Set<MeetingID>

    @State private var renameTarget: Meeting?
    @State private var renameTitle = ""
    @State private var deleteTarget: MeetingTrashRequest?
    @State private var folderRenameTarget: Folder?
    @State private var folderName = ""
    @State private var folderDeleteTarget: Folder?
    @State private var isCreatingFolder = false
    @State private var newFolderParentID: FolderID?
    @State private var query = ""
    @State private var searchScope: MeetingSidebarSearchScope = .allContent
    @State private var contentHits: [MeetingSidebarContentHit] = []
    @State private var contentSearchTask: Task<Void, Never>?
    @State private var contentIndexStore: MeetingSidebarContentIndexStore?
    @State private var retranscribeTarget: Meeting?
    @State private var audioExportRequest: AudioExportDialogRequest?
    @State private var audioExportLoadRequestID: UUID?
    @State private var persistedExpandedFolderIDs = FolderDisclosureStore().load()
    @State private var targetedFolderID: FolderID?
    @State private var isFolderHeadingTargeted = false
    @State private var isMovingMeetings = false
    @State private var appearanceFolderID: FolderID?
    @State private var appearancePickerKind: FolderAppearancePickerKind?

    private var appearancePopoverIsPresented: Binding<Bool> {
        Binding(
            get: { appearancePickerKind != nil && appearanceFolderID != nil },
            set: { if !$0 { appearancePickerKind = nil } }
        )
    }

    private let disclosureStore = FolderDisclosureStore()

    var body: some View {
        list
            .modifier(FolderDialogs(
                folderName: $folderName,
                isCreating: $isCreatingFolder,
                newFolderParentID: $newFolderParentID,
                renameTarget: $folderRenameTarget,
                deleteTarget: $folderDeleteTarget,
                disclosureStore: disclosureStore
            ))
            .confirmationDialog(
                "Which track?",
                isPresented: Binding(
                    get: { audioExportRequest != nil },
                    set: { if !$0 { audioExportRequest = nil } }
                ),
                titleVisibility: .visible,
                presenting: audioExportRequest
            ) { request in
                ForEach(request.options) { option in
                    Button(option.label) {
                        let target = request.meeting
                        audioExportRequest = nil
                        switch option {
                        case let .original(asset, _):
                            Task {
                                await model.exportAudioTrack(asset, of: target.id)
                            }
                        case let .stereoM4A(microphone, system):
                            Task {
                                await model.exportStereoAudio(
                                    microphone: microphone,
                                    system: system,
                                    of: target.id
                                )
                            }
                        }
                    }
                    .disabled(
                        option.kind == .stereoM4A
                            && model.audioExportActivity != nil
                    )
                }
                Button("Cancel", role: .cancel) { audioExportRequest = nil }
            } message: { _ in
                Text("The original stays in the library; this saves a copy.")
            }
            .modifier(MeetingDialogs(
                renameTitle: $renameTitle,
                renameTarget: $renameTarget,
                deleteTarget: $deleteTarget,
                retranscribeTarget: $retranscribeTarget
            ))
    }

    private var list: some View {
        List(selection: $selection) {
            if showsContentResults {
                ForEach(renderableContentHits, id: \.meetingID) { hit in
                    contentHitRow(hit)
                }
            } else {
                folderHeading
                ForEach(tree.folderNodes) { node in
                    rootFolder(node)
                }
                ForEach(tree.unfiledSections) { section in
                    dateSection(section)
                }
            }
        }
        .listStyle(.sidebar)
        .contextMenu(forSelectionType: MeetingID.self) { meetingIDs in
            if let context = meetingCommandContext(for: meetingIDs) {
                meetingSelectionMenu(context)
            }
        }
        .focusedSceneValue(
            \.stenoMeetingCommandContext,
            meetingCommandContext(for: selection)
        )
        .onDeleteCommand {
            guard let context = meetingCommandContext(for: selection),
                  context.availability.canMoveToTrash else { return }
            context.moveToTrash()
        }
        .toolbar(id: MacToolbarID.sidebar.rawValue) {
            ToolbarItem(
                id: MacToolbarItemID.newFolder.rawValue,
                placement: .primaryAction
            ) {
                Button {
                    beginCreatingFolder(parentFolderID: nil)
                } label: {
                    Label("New folder", systemImage: "folder.badge.plus")
                }
                .help("Create a folder")
                .disabled(model.runtime == nil)
            }
            .defaultCustomization(
                MacToolbarPresentation.defaultCustomization(
                    for: .newFolder,
                    in: .sidebar
                )
            )
        }
        .navigationTitle(MacWindowPresentation.meetingsTitle)
        .searchable(
            text: $query,
            placement: .sidebar,
            prompt: searchScope == .titles ? "Search Titles" : "Search All Content"
        )
        .safeAreaInset(edge: .top, spacing: 0) {
            if isSearching {
                Picker("Search scope", selection: $searchScope) {
                    Text("Titles").tag(MeetingSidebarSearchScope.titles)
                    Text("All Content").tag(MeetingSidebarSearchScope.allContent)
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .labelsHidden()
                .padding(.horizontal, Steno.Space.s)
                .padding(.top, Steno.Space.xs)
            }
        }
        .overlay {
            if model.meetings.isEmpty, model.folders.isEmpty {
                ContentUnavailableView(
                    "No meetings yet",
                    systemImage: "tray",
                    description: Text("Recordings and imports appear here.")
                )
                .allowsHitTesting(false)
            } else if showsContentResults,
                      renderableContentHits.isEmpty {
                ContentUnavailableView.search(text: query)
                    .allowsHitTesting(false)
            } else if !showsContentResults,
                      allTreeMeetingIDs.isEmpty, isSearching {
                ContentUnavailableView.search(text: query)
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: query) { _, _ in
            scheduleContentSearch()
            pruneSelection()
        }
        .onChange(of: searchScope) { _, _ in
            scheduleContentSearch()
            pruneSelection()
        }
        .onDisappear {
            contentSearchTask?.cancel()
        }
        .onChange(of: model.meetings) { _, _ in
            if !isMovingMeetings {
                pruneSelection()
            }
        }
        .onChange(of: model.folders) { _, folders in
            let existing = Set(folders.map(\.id))
            persistedExpandedFolderIDs.formIntersection(existing)
            disclosureStore.save(persistedExpandedFolderIDs)
            pruneSelection()
        }
    }

    private var folderHeading: some View {
        HStack {
            Text("Folders")
                .font(.caption.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button {
                beginCreatingFolder(parentFolderID: nil)
            } label: {
                Image(systemName: "plus")
                    .font(.caption.weight(.semibold))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .disabled(model.runtime == nil)
            .help("New folder")
            .accessibilityLabel("New folder")
            .accessibilityHint("Create a folder")
        }
        .foregroundStyle(
            isFolderHeadingTargeted
                ? Color(nsColor: .selectedControlTextColor)
                : Color.secondary
        )
        .padding(.top, Steno.Space.s)
        .listRowSeparator(.hidden)
        .selectionDisabled()
        .dropDestination(for: SidebarDragPayload.self) { payloads, _ in
            guard payloads.count == 1,
                  case let .folder(folderID) = payloads[0],
                  MeetingSidebarDropPolicy.canPromote(
                      folder: folderID,
                      folders: model.folders
                  )
            else { return false }
            Task {
                _ = await model.moveFolder(folderID, to: nil)
            }
            return true
        } isTargeted: { isTargeted in
            isFolderHeadingTargeted = isTargeted
        }
        .dropConfiguration { session in
            dropConfigurationForFolderHeading(session)
        }
        .background(
            isFolderHeadingTargeted
                ? Color(nsColor: .selectedContentBackgroundColor)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 5)
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
            folderLabel(node)
                .selectionDisabled()
        }
        .springLoadingBehavior(.enabled)
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
            folderLabel(node)
                .selectionDisabled()
        }
        .springLoadingBehavior(.enabled)
    }

    private func folderLabel(_ node: MeetingFolderNode) -> some View {
        let isTargeted = MeetingSidebarDropPresentation.isTargeted(
            node.id,
            targetedFolderID: targetedFolderID
        )

        return HStack(spacing: Steno.Space.s) {
            Label {
                Text(node.folder.name)
            } icon: {
                folderIcon(node.folder)
            }
            Spacer(minLength: Steno.Space.xs)
        }
            .foregroundStyle(
                isTargeted
                    ? Color(nsColor: .selectedControlTextColor)
                    : Color.primary
            )
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .contextMenu {
                folderMenu(folderCommandContext(node))
                Divider()
                Button("Change Color…") {
                    appearanceFolderID = node.folder.id
                    appearancePickerKind = .color
                }
                Button("Change Icon…") {
                    appearanceFolderID = node.folder.id
                    appearancePickerKind = .icon
                }
            }
            .focusable()
            .focusedValue(
                \.stenoFolderCommandContext,
                folderCommandContext(node)
            )
            .accessibilityValue(
                "\(node.meetings.count) direct meetings, \(node.children.count) subfolders"
            )
            .draggable(SidebarDragPayload(folderID: node.id)) {
                SidebarDragPreview(
                    title: node.folder.name,
                    systemImage: node.folder.icon?.rawValue ?? "folder"
                )
            }
            .popover(
                isPresented: appearancePopoverIsPresented,
                arrowEdge: .leading
            ) {
                folderAppearancePopover
            }
            .dragConfiguration(MeetingSidebarDragContract.sourceConfiguration)
            .dropDestination(for: SidebarDragPayload.self) { payloads, _ in
                guard payloads.count == 1 else { return false }
                switch payloads[0] {
                case .meetings:
                    guard let meetingIDs = MeetingSidebarDropPolicy
                        .meetingIDsToAttempt(payloads[0])
                    else { return false }
                    moveMeetings(meetingIDs, to: node.id)
                    return true
                case let .folder(folderID):
                    guard MeetingSidebarDropPolicy.canMove(
                        folder: folderID,
                        onto: node.id,
                        folders: model.folders
                    ) else { return false }
                    moveFolder(folderID, to: node.id)
                    return true
                }
            } isTargeted: { isTargeted in
                updateFolderTarget(node.id, isTargeted: isTargeted)
            }
            .dropConfiguration { session in
                dropConfiguration(session, for: node.id)
            }
            .background(
                isTargeted
                    ? Color(nsColor: .selectedContentBackgroundColor)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 5)
            )
            .animation(.easeOut(duration: 0.12), value: isTargeted)
    }

    /// Renders the folder's chosen symbol tinted with its color token. A
    /// folder without an explicit icon or color keeps the default look.
    private func folderIcon(_ folder: Folder) -> some View {
        let symbol = folder.icon?.rawValue ?? MeetingSidebarDropPresentation.symbolName
        return Image(systemName: symbol)
            .foregroundStyle(folder.colorToken?.sidebarColor ?? Color.primary)
    }

    @ViewBuilder
    private var folderAppearancePopover: some View {
        switch appearancePickerKind {
        case .color:
            if let folder = currentAppearanceFolder {
                FolderColorPickerPopover(folder: folder)
            }
        case .icon:
            if let folder = currentAppearanceFolder {
                FolderIconPickerPopover(folder: folder)
            }
        case nil:
            EmptyView()
        }
    }

    private var currentAppearanceFolder: Folder? {
        appearanceFolderID.flatMap { folderID in
            model.folders.first { $0.id == folderID }
        }
    }

    private var emptyFolderRow: some View {
        Text("Empty - move a meeting here")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .listRowSeparator(.hidden)
            .selectionDisabled()
    }

    @ViewBuilder
    private func dateSection(_ section: MeetingSection) -> some View {
        Text(LocalizedStringKey(section.title))
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, Steno.Space.s)
            .listRowSeparator(.hidden)
            .selectionDisabled()
        ForEach(section.meetings, id: \.id) { meeting in
            meetingRow(meeting)
        }
    }

    private func meetingRow(_ meeting: Meeting) -> some View {
        let draggedMeetingIDs = MeetingSidebarSelectionPolicy.draggedIDs(
            startingAt: meeting.id,
            selection: selection
        )

        return VStack(alignment: .leading, spacing: 2) {
            Text(meeting.title)
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(
                    meeting.createdAt,
                    format: .dateTime.day().month().hour().minute()
                )
                if meeting.status != .ready {
                    StatusBadge(status: meeting.status)
                }
                if DemoBadge.isVisible(for: meeting) {
                    DemoBadge()
                }
                if model.meetingsWithAudio.contains(meeting.id) {
                    Image(systemName: "waveform")
                        .help("Audio available - voice samples and speaker naming possible")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .tag(meeting.id)
        .draggable(SidebarDragPayload(meetingIDs: draggedMeetingIDs)) {
            SidebarDragPreview(
                title: meeting.title,
                systemImage: "waveform",
                itemCount: draggedMeetingIDs.count
            )
        }
        .dragConfiguration(MeetingSidebarDragContract.sourceConfiguration)
    }

    @ViewBuilder
    private func meetingSelectionMenu(
        _ context: MacMeetingCommandContext
    ) -> some View {
        if context.meetingIDs.count > 1 {
            Menu("Move \(context.meetingIDs.count) Meetings") {
                meetingDestinationMenu(context)
            }
            .disabled(!context.availability.canMove)
            Divider()
        } else if context.meetingIDs.count == 1 {
            Button("Rename…", action: context.rename)
                .disabled(!context.availability.canRename)
            Menu("Move to Folder") {
                meetingDestinationMenu(context)
                Divider()
                Button("New Folder…", action: context.createFolder)
            }
            .disabled(!context.availability.canMove)
            Divider()
            Button("Transcribe Again…", action: context.retranscribe)
                .disabled(!context.availability.canRetranscribe)
            Button("Export as Markdown…", action: context.exportMarkdown)
                .disabled(!context.availability.canExportMarkdown)
            Button("Export Audio…", action: context.exportAudio)
                .disabled(!context.availability.canExportAudio)
            Divider()
        }
        if !context.meetingIDs.isEmpty {
            Button(role: .destructive, action: context.moveToTrash) {
                Text(MeetingTrashRequest.menuTitle(
                    meetingCount: context.meetingIDs.count
                ))
            }
            .disabled(!context.availability.canMoveToTrash)
        }
    }

    private func meetingCommandContext(
        for meetingIDs: Set<MeetingID>
    ) -> MacMeetingCommandContext? {
        guard !meetingIDs.isEmpty else { return nil }
        let selectedMeetings = model.meetings.filter {
            meetingIDs.contains($0.id)
        }
        guard selectedMeetings.count == meetingIDs.count else { return nil }
        let meeting = selectedMeetings.count == 1
            ? selectedMeetings[0]
            : nil
        let capturedMeetingIDs = meetingIDs
        let destinations = model.folders.map {
            MacMeetingFolderDestination(
                id: $0.id,
                name: $0.name,
                parentFolderID: $0.parentFolderID
            )
        }
        let availability = MacMeetingCommandAvailability(
            meetings: model.meetings,
            selectedMeetingIDs: capturedMeetingIDs,
            meetingsWithAudio: model.meetingsWithAudio,
            isRecording: model.isRecording
                || model.isStartingRecording
                || model.isMovingMeetingsToTrash,
            hasRuntime: model.runtime != nil
        )
        let trashRequest = MeetingTrashRequest(meetings: selectedMeetings)

        return MacMeetingCommandContext(
            meetingIDs: capturedMeetingIDs,
            availability: availability,
            folderDestinations: destinations,
            rename: {
                guard let meeting else { return }
                renameTitle = meeting.title
                renameTarget = meeting
            },
            moveToFolder: { destinationID in
                moveMeetings(capturedMeetingIDs, to: destinationID)
            },
            createFolder: {
                beginCreatingFolder(parentFolderID: nil)
            },
            retranscribe: {
                guard let meeting else { return }
                retranscribeTarget = meeting
            },
            exportMarkdown: {
                guard let meeting else { return }
                let action = MacFocusedAsyncAction(target: meeting.id) {
                    await model.exportMeetingToFile($0)
                }
                Task { await action() }
            },
            exportAudio: {
                guard let meeting else { return }
                beginAudioExport(for: meeting)
            },
            moveToTrash: {
                guard availability.canMoveToTrash,
                      let trashRequest else { return }
                deleteTarget = trashRequest
            }
        )
    }

    private func folderCommandContext(
        _ node: MeetingFolderNode
    ) -> MacFolderCommandContext {
        let folder = node.folder
        let siblings = model.folders.filter {
            $0.parentFolderID == folder.parentFolderID
        }
        let siblingIndex = siblings.firstIndex { $0.id == folder.id }
        let destinations = MeetingSidebarFolderMenuPolicy
            .nestingDestinations(for: folder, folders: model.folders)
            .map {
                MacMeetingFolderDestination(
                    id: $0.id,
                    name: $0.name,
                    parentFolderID: $0.parentFolderID
                )
            }
        let hasRuntime = model.runtime != nil
        let availability = MacFolderCommandAvailability(
            canCreateSubfolder: hasRuntime && folder.parentFolderID == nil,
            canRename: hasRuntime,
            canMoveUp: hasRuntime && (siblingIndex ?? 0) > 0,
            canMoveDown: hasRuntime
                && siblingIndex.map { siblings.indices.contains($0 + 1) } == true,
            canMoveToTopLevel: hasRuntime && folder.parentFolderID != nil,
            canDelete: hasRuntime
        )

        return MacFolderCommandContext(
            folderID: folder.id,
            folderName: folder.name,
            availability: availability,
            nestingDestinations: destinations,
            createSubfolder: {
                beginCreatingFolder(parentFolderID: folder.id)
            },
            rename: {
                folderName = folder.name
                folderRenameTarget = folder
            },
            moveUp: {
                let action = MacFocusedAsyncAction(target: folder.id) {
                    await model.moveFolder($0, up: true)
                }
                Task { await action() }
            },
            moveDown: {
                let action = MacFocusedAsyncAction(target: folder.id) {
                    await model.moveFolder($0, up: false)
                }
                Task { await action() }
            },
            moveIntoFolder: { destinationID in
                moveFolder(folder.id, to: destinationID)
            },
            moveToTopLevel: {
                moveFolder(folder.id, to: nil)
            },
            delete: {
                folderDeleteTarget = folder
            }
        )
    }

    private func beginAudioExport(for meeting: Meeting) {
        let loadRequestID = UUID()
        audioExportLoadRequestID = loadRequestID
        Task {
            let request = await AudioExportDialogRequest.load(for: meeting) {
                await model.audioExportOptions(for: $0)
            }
            guard audioExportLoadRequestID == loadRequestID else { return }
            audioExportLoadRequestID = nil
            guard let request else {
                model.report("No readable audio tracks are available for export.")
                return
            }
            audioExportRequest = request
        }
    }

    @ViewBuilder
    private func meetingDestinationMenu(
        _ context: MacMeetingCommandContext
    ) -> some View {
        ForEach(normalTree.folderNodes) { root in
            Menu(root.folder.name) {
                Button("Move Here") { context.moveToFolder(root.id) }
                ForEach(root.children) { child in
                    Button(child.folder.name) {
                        context.moveToFolder(child.id)
                    }
                }
            }
        }
        if !normalTree.folderNodes.isEmpty {
            Divider()
        }
        Button("None") { context.moveToFolder(nil) }
    }

    @ViewBuilder
    private func folderMenu(_ context: MacFolderCommandContext) -> some View {
        if context.availability.canCreateSubfolder {
            Button("New Subfolder…", action: context.createSubfolder)
        }
        Button("Rename…", action: context.rename)
            .disabled(!context.availability.canRename)
        Divider()
        Button("Move Up", action: context.moveUp)
            .disabled(!context.availability.canMoveUp)
        Button("Move Down", action: context.moveDown)
            .disabled(!context.availability.canMoveDown)
        if !context.nestingDestinations.isEmpty {
            Menu("Move into Folder") {
                ForEach(context.nestingDestinations) { destination in
                    Button(destination.name) {
                        context.moveIntoFolder(destination.id)
                    }
                }
            }
        }
        if context.availability.canMoveToTopLevel {
            Button("Move to Top Level", action: context.moveToTopLevel)
        }
        Divider()
        Button(
            "Delete Folder…",
            role: .destructive,
            action: context.delete
        )
        .disabled(!context.availability.canDelete)
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var tree: MeetingSidebarTree {
        MeetingSidebarTree.build(
            for: MeetingSearch.matching(model.meetings, query: query),
            folders: model.folders,
            hidesEmptyFolders: isSearching
        )
    }

    private var normalTree: MeetingSidebarTree {
        MeetingSidebarTree.build(
            for: model.meetings,
            folders: model.folders
        )
    }

    /// True while the "all content" scope renders cross-meeting hit rows
    /// instead of the folder/meeting tree.
    private var showsContentResults: Bool {
        searchScope == .allContent && isSearching
    }

    /// Hits whose meeting still exists; the derived index can lag behind
    /// deletions until its next incremental update.
    private var renderableContentHits: [MeetingSidebarContentHit] {
        let known = Set(model.meetings.map(\.id))
        return contentHits.filter { known.contains($0.meetingID) }
    }

    private func title(for meetingID: MeetingID) -> String {
        model.meetings.first { $0.id == meetingID }?.title ?? ""
    }

    /// One sidebar row per meeting hit: title plus emphasized snippet.
    /// Tagging with the meeting ID makes tapping select the meeting just
    /// like a title result row.
    private func contentHitRow(_ hit: MeetingSidebarContentHit) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title(for: hit.meetingID))
                .lineLimit(1)
            Text(MeetingSnippetEmphasis.attributed(
                snippet: hit.snippet,
                query: query
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
        .padding(.vertical, 2)
        .tag(hit.meetingID)
    }

    /// Debounces "all content" searches: rapid keystrokes coalesce for
    /// 150 ms before a single `MeetingSearchIndex.search` runs. The FTS5
    /// work executes on the index actor, never the main thread; only the
    /// routed hit assignment hops back. The index opens the SAME SQLite
    /// database AppModel already rebuilt at startup, through its own WAL
    /// reader connection, created lazily on the first content search.
    private func scheduleContentSearch() {
        contentSearchTask?.cancel()
        guard searchScope == .allContent, isSearching else {
            contentHits = []
            return
        }
        let trimmedQuery = query.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmedQuery.isEmpty else {
            contentHits = []
            return
        }
        if contentIndexStore == nil,
           let layout = model.runtime?.library.layout {
            contentIndexStore = MeetingSidebarContentIndexStore(layout: layout)
        }
        guard let indexStore = contentIndexStore else { return }
        contentSearchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            guard let index = indexStore.currentIndex() else { return }
            do {
                let groups = try await index.search(trimmedQuery, limit: 50)
                guard !Task.isCancelled else { return }
                contentHits = MeetingSidebarSearchRouter.results(
                    query: trimmedQuery,
                    scope: .allContent,
                    meetings: model.meetings,
                    contentGroups: groups
                )
            } catch {
                // Derived index hiccup: keep the previous hits instead of
                // flashing an empty result list.
            }
        }
    }

    private var effectiveExpandedFolderIDs: Set<FolderID> {
        MeetingSidebarVisibility.effectiveExpandedFolderIDs(
            in: tree,
            persisted: persistedExpandedFolderIDs,
            isSearching: isSearching
        )
    }

    private var allTreeMeetingIDs: Set<MeetingID> {
        var result = Set(
            tree.unfiledSections.flatMap(\.meetings).map(\.id)
        )
        for root in tree.folderNodes {
            result.formUnion(root.meetings.map(\.id))
            for child in root.children {
                result.formUnion(child.meetings.map(\.id))
            }
        }
        return result
    }

    private func disclosureBinding(for folderID: FolderID) -> Binding<Bool> {
        Binding(
            get: { effectiveExpandedFolderIDs.contains(folderID) },
            set: { expanded in
                guard !isSearching else { return }
                if expanded {
                    persistedExpandedFolderIDs.insert(folderID)
                } else {
                    persistedExpandedFolderIDs.remove(folderID)
                }
                disclosureStore.save(persistedExpandedFolderIDs)
                if !expanded {
                    pruneSelection()
                }
            }
        )
    }

    private func pruneSelection() {
        var pruned = MeetingSidebarVisibility.prunedSelection(
            selection,
            in: tree,
            expandedFolderIDs: effectiveExpandedFolderIDs
        )
        if showsContentResults {
            // Content hit rows live outside the title tree; keep selected
            // meetings that are still rendered as content hits.
            pruned.formUnion(
                selection.intersection(
                    Set(renderableContentHits.map(\.meetingID))
                )
            )
        }
        selection = pruned
    }

    private func beginCreatingFolder(parentFolderID: FolderID?) {
        folderName = ""
        newFolderParentID = parentFolderID
        isCreatingFolder = true
    }

    private func moveMeetings(
        _ meetingIDs: Set<MeetingID>,
        to folderID: FolderID?
    ) {
        isMovingMeetings = true
        Task {
            let moved = await model.moveMeetings(meetingIDs, to: folderID)
            if moved, let folderID {
                expandPath(to: folderID)
            }
            isMovingMeetings = false
            pruneSelection()
        }
    }

    private func moveFolder(_ folderID: FolderID, to parentFolderID: FolderID?) {
        Task {
            guard await model.moveFolder(folderID, to: parentFolderID) else {
                return
            }
            if parentFolderID != nil {
                expandPath(to: folderID)
            }
        }
    }

    private func expandPath(to folderID: FolderID) {
        persistedExpandedFolderIDs = MeetingSidebarVisibility.expandedFolderIDs(
            persistedExpandedFolderIDs,
            revealing: folderID,
            folders: model.folders
        )
        disclosureStore.save(persistedExpandedFolderIDs)
    }

    private func canMoveSibling(_ folder: Folder, offset: Int) -> Bool {
        let siblings = model.folders.filter {
            $0.parentFolderID == folder.parentFolderID
        }
        guard let index = siblings.firstIndex(where: { $0.id == folder.id }) else {
            return false
        }
        return siblings.indices.contains(index + offset)
    }

    private func updateFolderTarget(
        _ folderID: FolderID,
        isTargeted: Bool
    ) {
        if isTargeted {
            targetedFolderID = folderID
        } else if targetedFolderID == folderID {
            targetedFolderID = nil
        }
    }

    private func isValidLocalDrop(
        _ session: DropSession,
        onto folderID: FolderID
    ) -> Bool {
        MeetingSidebarDropPolicy.canNegotiateLocalMove(
            itemCount: session.itemsCount,
            hasLocalSession: session.localSession != nil,
            suggestsMove: session.suggestedOperations.contains(.move),
            targetExists: model.folders.contains(where: { $0.id == folderID })
        )
    }

    private func dropConfiguration(
        _ session: DropSession,
        for folderID: FolderID
    ) -> DropConfiguration {
        var configuration = DropConfiguration(
            operation: isValidLocalDrop(session, onto: folderID)
                ? MeetingSidebarDragContract.destinationOperation
                : .forbidden
        )
        configuration.acceptedItemCount = 1
        return configuration
    }

    private func isValidFolderHeadingDrop(_ session: DropSession) -> Bool {
        MeetingSidebarDropPolicy.canNegotiateLocalMove(
            itemCount: session.itemsCount,
            hasLocalSession: session.localSession != nil,
            suggestsMove: session.suggestedOperations.contains(.move),
            targetExists: !model.folders.isEmpty
        )
    }

    private func dropConfigurationForFolderHeading(
        _ session: DropSession
    ) -> DropConfiguration {
        var configuration = DropConfiguration(
            operation: isValidFolderHeadingDrop(session)
                ? MeetingSidebarDragContract.destinationOperation
                : .forbidden
        )
        configuration.acceptedItemCount = 1
        return configuration
    }
}

/// Renders a search snippet with every occurrence of a query term
/// emphasized, using the same case-, diacritic- and width-insensitive
/// comparison as the search itself (`MeetingSearch.normalized`).
private enum MeetingSnippetEmphasis {
    static func attributed(snippet: String, query: String) -> AttributedString {
        let terms = query
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { !MeetingSearch.normalized($0).isEmpty }
        var result = AttributedString()
        var cursor = snippet.startIndex
        for range in mergedMatchRanges(of: terms, in: snippet) {
            result += AttributedString(snippet[cursor..<range.lowerBound])
            var emphasized = AttributedString(snippet[range])
            emphasized.font = .caption.weight(.semibold)
            emphasized.foregroundColor = .primary
            result += emphasized
            cursor = range.upperBound
        }
        result += AttributedString(snippet[cursor...])
        return result
    }

    private static func mergedMatchRanges(
        of terms: [String],
        in snippet: String
    ) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        for term in terms {
            var searchStart = snippet.startIndex
            while let range = snippet.range(
                of: term,
                options: [
                    .caseInsensitive,
                    .diacriticInsensitive,
                    .widthInsensitive,
                ],
                range: searchStart..<snippet.endIndex
            ) {
                guard !range.isEmpty else { break }
                ranges.append(range)
                searchStart = range.upperBound
            }
        }
        guard !ranges.isEmpty else { return [] }
        ranges.sort { $0.lowerBound < $1.lowerBound }
        var merged = [ranges[0]]
        for range in ranges.dropFirst() {
            let last = merged[merged.count - 1]
            if range.lowerBound <= last.upperBound {
                merged[merged.count - 1] =
                    min(last.lowerBound, range.lowerBound)
                    ..< max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}

private struct FolderDialogs: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var folderName: String
    @Binding var isCreating: Bool
    @Binding var newFolderParentID: FolderID?
    @Binding var renameTarget: Folder?
    @Binding var deleteTarget: Folder?
    let disclosureStore: FolderDisclosureStore

    func body(content: Content) -> some View {
        let createValidation = SidebarNameValidation.evaluate(
            name: folderName,
            parentFolderID: newFolderParentID,
            currentFolderID: nil,
            folders: model.folders
        )
        let renameValidation = SidebarNameValidation.evaluate(
            name: folderName,
            parentFolderID: renameTarget?.parentFolderID,
            currentFolderID: renameTarget?.id,
            folders: model.folders
        )

        content
            .alert(
                newFolderParentID == nil ? "New folder" : "New subfolder",
                isPresented: $isCreating
            ) {
                TextField("Name", text: $folderName)
                Button("Create") {
                    guard let name = createValidation.normalizedName else {
                        return
                    }
                    let parentFolderID = newFolderParentID
                    isCreating = false
                    Task {
                        _ = await model.createFolder(
                            named: name,
                            parentFolderID: parentFolderID
                        )
                    }
                }
                .disabled(!createValidation.canSubmit)
                Button("Cancel", role: .cancel) { isCreating = false }
            } message: {
                if let message = createValidation.message {
                    Text(message)
                }
            }
            .alert(
                "Rename folder",
                isPresented: Binding(
                    get: { renameTarget != nil },
                    set: { if !$0 { renameTarget = nil } }
                ),
                presenting: renameTarget
            ) { folder in
                TextField("Name", text: $folderName)
                Button("Rename") {
                    guard let name = renameValidation.normalizedName else {
                        return
                    }
                    let target = folder.id
                    renameTarget = nil
                    Task { await model.renameFolder(target, to: name) }
                }
                .disabled(!renameValidation.canSubmit)
                Button("Cancel", role: .cancel) { renameTarget = nil }
            } message: { _ in
                if let message = renameValidation.message {
                    Text(message)
                }
            }
            .confirmationDialog(
                deleteTarget.map { "Delete the folder \u{201C}\($0.name)\u{201D}?" } ?? "",
                isPresented: Binding(
                    get: { deleteTarget != nil },
                    set: { if !$0 { deleteTarget = nil } }
                ),
                titleVisibility: .visible,
                presenting: deleteTarget
            ) { folder in
                Button("Delete folder", role: .destructive) {
                    let target = folder.id
                    deleteTarget = nil
                    Task {
                        if await model.deleteFolder(target) {
                            disclosureStore.remove(target)
                        }
                    }
                }
                Button("Cancel", role: .cancel) { deleteTarget = nil }
            } message: { folder in
                if model.folders.contains(where: {
                    $0.parentFolderID == folder.id
                }) {
                    Text("Only the folder goes away. Its meetings stay in the library, and its subfolders move to the top level.")
                } else {
                    Text("Only the folder goes away. Its meetings stay in the library and move back to the date list.")
                }
            }
    }
}

private struct MeetingDialogs: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var renameTitle: String
    @Binding var renameTarget: Meeting?
    @Binding var deleteTarget: MeetingTrashRequest?
    @Binding var retranscribeTarget: Meeting?

    func body(content: Content) -> some View {
        let renameValidation = MeetingTitleValidation.evaluate(title: renameTitle)

        content
            .confirmationDialog(
                retranscribeTarget.map { "Transcribe \u{201C}\($0.title)\u{201D} again?" } ?? "",
                isPresented: Binding(
                    get: { retranscribeTarget != nil },
                    set: { if !$0 { retranscribeTarget = nil } }
                ),
                titleVisibility: .visible,
                presenting: retranscribeTarget
            ) { meeting in
                Button("Transcribe Again") {
                    let target = meeting.id
                    retranscribeTarget = nil
                    Task { await model.requestRetranscription(meetingID: target) }
                }
                Button("Cancel", role: .cancel) { retranscribeTarget = nil }
            } message: { _ in
                Text("A new transcript is added; the current one stays available as an earlier version. Speaker assignments for this meeting have to be confirmed again afterwards.")
            }
            .alert(
                "Rename meeting",
                isPresented: Binding(
                    get: { renameTarget != nil },
                    set: { if !$0 { renameTarget = nil } }
                ),
                presenting: renameTarget
            ) { meeting in
                TextField("Title", text: $renameTitle)
                Button("Rename") {
                    guard let title = renameValidation.normalizedTitle else {
                        return
                    }
                    let target = meeting.id
                    renameTarget = nil
                    Task { await model.renameMeeting(target, to: title) }
                }
                .disabled(!renameValidation.canSubmit)
                Button("Cancel", role: .cancel) { renameTarget = nil }
            } message: { _ in
                if let message = renameValidation.message {
                    Text(message)
                } else {
                    Text("The new title only affects how the meeting is displayed; the originals stay unchanged.")
                }
            }
            .confirmationDialog(
                deleteTarget.map {
                    String(localized: $0.confirmationTitle)
                } ?? "",
                isPresented: Binding(
                    get: { deleteTarget != nil },
                    set: { if !$0 { deleteTarget = nil } }
                ),
                titleVisibility: .visible,
                presenting: deleteTarget
            ) { request in
                Button(role: .destructive) {
                    let targets = request.meetingIDs
                    deleteTarget = nil
                    Task { await model.deleteMeetings(targets) }
                } label: {
                    Text(request.actionTitle)
                }
                Button("Cancel", role: .cancel) { deleteTarget = nil }
            } message: { request in
                Text(request.message)
            }
    }
}

private struct SidebarDragPreview: View {
    let title: String
    let systemImage: String
    var itemCount = 1

    var body: some View {
        HStack(spacing: Steno.Space.s) {
            Image(systemName: systemImage)
                .foregroundStyle(Color.accentColor)
            Text(title)
                .lineLimit(1)
            if itemCount > 1 {
                Text("\(itemCount)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(
                        Color(nsColor: .selectedControlTextColor)
                    )
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor, in: Capsule())
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: 260, alignment: .leading)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule()
                .stroke(Color.primary.opacity(0.14), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
    }
}

private struct StatusBadge: View {
    let status: Meeting.Status

    var body: some View {
        Text(label)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var label: LocalizedStringKey {
        switch status {
        case .draft: "Draft"
        case .recording: "Recording"
        case .interrupted: "Interrupted"
        case .processing: "Processing"
        case .ready: "Ready"
        }
    }

    private var color: Color {
        switch status {
        case .draft: .secondary
        case .recording: Steno.Colors.recording
        case .interrupted: Steno.Colors.uncertain
        case .processing: Steno.Colors.running
        case .ready: Steno.Colors.confirmed
        }
    }
}

/// Which appearance sheet is anchored to a folder row.
private enum FolderAppearancePickerKind {
    case color
    case icon
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

/// Popover listing the fixed eight-color palette plus a reset entry.
private struct FolderColorPickerPopover: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let folder: Folder

    var body: some View {
        VStack(alignment: .leading, spacing: Steno.Space.s) {
            Text("Folder Color")
                .font(.headline)
            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(28)), count: 4),
                spacing: Steno.Space.s
            ) {
                ForEach(FolderColorToken.allCases, id: \.self) { token in
                    Button {
                        select(token)
                    } label: {
                        Circle()
                            .fill(token.sidebarColor)
                            .frame(width: 22, height: 22)
                            .overlay {
                                if folder.colorToken == token {
                                    Circle()
                                        .strokeBorder(Color.primary, lineWidth: 2)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Color \(token.rawValue)")
                }
            }
            Button("None") {
                Task {
                    await model.setFolderColor(nil, of: folder.id)
                }
                dismiss()
            }
        }
        .padding()
    }

    private func select(_ token: FolderColorToken) {
        Task {
            await model.setFolderColor(token, of: folder.id)
        }
        dismiss()
    }
}

/// Popover listing the curated SF Symbol allowlist plus a reset entry.
private struct FolderIconPickerPopover: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let folder: Folder

    var body: some View {
        VStack(alignment: .leading, spacing: Steno.Space.s) {
            Text("Folder Icon")
                .font(.headline)
            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(32)), count: 4),
                spacing: Steno.Space.s
            ) {
                ForEach(FolderIcon.allCases, id: \.self) { icon in
                    Button {
                        select(icon)
                    } label: {
                        Image(systemName: icon.rawValue)
                            .frame(width: 28, height: 28)
                            .overlay {
                                if folder.icon == icon {
                                    RoundedRectangle(cornerRadius: 5)
                                        .strokeBorder(Color.primary, lineWidth: 2)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Icon \(icon.rawValue)")
                }
            }
            Button("Default") {
                Task {
                    await model.setFolderIcon(nil, of: folder.id)
                }
                dismiss()
            }
        }
        .padding()
    }

    private func select(_ icon: FolderIcon) {
        Task {
            await model.setFolderIcon(icon, of: folder.id)
        }
        dismiss()
    }
}
