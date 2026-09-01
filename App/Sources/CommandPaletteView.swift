import StenoDomain
import SwiftUI

/// Focused-window command contexts, snapshotted at the moment the Cmd-K
/// menu command fires. The palette's own search field holds keyboard focus
/// while it is open, so `@FocusedValue` would resolve to nil inside the
/// palette; the sidebar and detail contexts must be captured before the
/// overlay appears.
@MainActor
struct CommandPaletteContexts {
    let meeting: MacMeetingCommandContext?
    let folder: MacFolderCommandContext?
    let detail: MacMeetingDetailCommandContext?

    static let empty = CommandPaletteContexts(
        meeting: nil,
        folder: nil,
        detail: nil
    )
}

enum CommandPaletteSection: Int {
    case commands
    case meetings
    case settings

    var systemImage: String {
        switch self {
        case .commands: "command"
        case .meetings: "waveform"
        case .settings: "gearshape"
        }
    }
}

struct CommandPaletteItem: Identifiable {
    let id: String
    let title: String
    /// Extra match text that never renders (for example a menu path).
    let keywords: String
    let section: CommandPaletteSection
    let perform: () -> Void
}

/// Deterministic fuzzy filter for the palette. Scoring is deliberately
/// simple and stable: exact prefix beats non-initial word prefix beats
/// scattered subsequence; ties keep catalog order.
enum CommandPaletteFilter {
    /// Lower is better; nil means no match.
    static func score(query: String, target: String) -> Int? {
        let foldedQuery = query.lowercased()
        guard !foldedQuery.isEmpty else { return 0 }
        let foldedTarget = target.lowercased()
        if foldedTarget.hasPrefix(foldedQuery) { return 0 }

        // A word after the first one starting with the whole query is the
        // classic "New Meeting" -> "m" hit. The first word is already
        // covered by the prefix check above.
        let words = foldedTarget.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if words.dropFirst().contains(where: { $0.hasPrefix(foldedQuery) }) {
            return 1
        }

        var searchIndex = foldedTarget.startIndex
        for character in foldedQuery {
            guard let match = foldedTarget[searchIndex...].firstIndex(of: character)
            else { return nil }
            searchIndex = foldedTarget.index(after: match)
        }
        return 2
    }

    static func ranked(
        items: [CommandPaletteItem],
        query: String
    ) -> [CommandPaletteItem] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return items
        }
        let scored = items.enumerated().compactMap {
            index, item -> (score: Int, index: Int, item: CommandPaletteItem)? in
            let titleScore = score(query: query, target: item.title)
            let keywordScore = score(query: query, target: item.keywords).map { $0 + 2 }
            guard let best = [titleScore, keywordScore].compactMap({ $0 }).min()
            else { return nil }
            return (best, index, item)
        }
        return scored
            .sorted {
                $0.score != $1.score ? $0.score < $1.score : $0.index < $1.index
            }
            .map(\.item)
    }
}

/// Builds the palette catalog: every StenoCommandID action (gated by the
/// same availability rules as the menu bar), the twenty most recent
/// meetings, and one entry per settings tab.
enum CommandPaletteCatalog {
    /// Written before opening the Settings window. SettingsView reads this
    /// key once it wires its TabView selection to it; until then the value
    /// is harmless and the palette simply opens the window on General.
    static let settingsTabDefaultsKey = "steno.settings.tab"

    enum SettingsTab: String, CaseIterable, Identifiable {
        case general
        case transcription
        case people
        case languageModels
        case models
        case demoData

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: "General"
            case .transcription: "Transcription"
            case .people: "People"
            case .languageModels: "Language Models"
            case .models: "Models"
            case .demoData: "Demo Data"
            }
        }
    }

    @MainActor
    static func makeItems(
        model: AppModel,
        contexts: CommandPaletteContexts,
        openSettings: @escaping () -> Void
    ) -> [CommandPaletteItem] {
        var items: [CommandPaletteItem] = []
        let state = StenoCommandState(model: model)

        func append(
            _ id: StenoCommandID,
            _ title: String,
            keywords: String = "",
            when allowed: Bool = true,
            perform: @escaping () -> Void
        ) {
            items.append(
                CommandPaletteItem(
                    id: "command.\(id)",
                    title: title,
                    keywords: keywords,
                    section: .commands,
                    perform: perform
                )
            )
        }

        append(.startRecording, "Start Recording", when: state.canStartRecording) {
            Task { await model.startRecording() }
        }
        append(.stopRecording, "Stop Recording", when: state.canStopRecording) {
            Task { await model.stopRecording() }
        }
        append(.markMoment, "Mark This Moment", when: state.canMarkMoment) {
            Task { await model.markMoment() }
        }
        append(.newMeeting, "New Meeting", when: state.canCreateMeeting) {
            Task { await model.createDraftMeeting() }
        }
        append(
            .importAudio,
            "Import Audio File…",
            when: state.canImport
        ) {
            model.requestAudioImport()
        }
        append(
            .importMeetingPackage,
            "Import Meeting Package…",
            when: state.canImport
        ) {
            model.requestMeetingTransferImport()
        }
        if let detail = contexts.detail, detail.availability.canFindTranscript {
            append(.findTranscript, "Find in Transcript") {
                detail.findTranscript()
            }
        }
        if let detail = contexts.detail,
           detail.availability.canToggleInspector {
            append(.toggleInspector, "Show or Hide Inspector") {
                detail.toggleInspector()
            }
        }
        // Always reachable: flipping the persisted visibility works from
        // anywhere, exactly like its Cmd-Shift-A menu command.
        append(.toggleAskBar, "Show or Hide Ask Bar") {
            StenoCommands.toggleAskBarVisibility()
        }
        if let meeting = contexts.meeting,
           meeting.availability.canMoveToTrash {
            append(
                .moveToTrash,
                String(localized: MeetingTrashRequest.commandTitle(
                    meetingCount: meeting.meetingIDs.count
                ))
            ) {
                meeting.moveToTrash()
            }
        }

        for meeting in model.meetings
            .sorted(by: { $0.createdAt > $1.createdAt })
            .prefix(20) {
            let meetingID = meeting.id
            items.append(
                CommandPaletteItem(
                    id: "meeting.\(meetingID)",
                    title: meeting.title,
                    keywords: "meeting",
                    section: .meetings
                ) {
                    model.selectedMeetingID = meetingID
                }
            )
        }

        for tab in SettingsTab.allCases {
            items.append(
                CommandPaletteItem(
                    id: "settings.\(tab.rawValue)",
                    title: tab.title,
                    keywords: "open settings",
                    section: .settings
                ) {
                    UserDefaults.standard.set(
                        tab.rawValue,
                        forKey: settingsTabDefaultsKey
                    )
                    openSettings()
                }
            )
        }

        return items
    }
}

/// Modal Spotlight-style overlay. Pure presentation plus keyboard wiring;
/// all filtering lives in `CommandPaletteFilter`, all actions in
/// `CommandPaletteCatalog`.
struct CommandPaletteView: View {
    let model: AppModel
    let onClose: () -> Void

    @Environment(\.openSettings) private var openSettings
    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var searchFieldFocused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)
            panel
                .padding(.horizontal, 80)
                .padding(.top, 90)
        }
        .onAppear { searchFieldFocused = true }
    }

    private var results: [CommandPaletteItem] {
        CommandPaletteFilter.ranked(items: catalog, query: query)
    }

    private var catalog: [CommandPaletteItem] {
        CommandPaletteCatalog.makeItems(
            model: model,
            contexts: model.commandPaletteContexts ?? .empty,
            openSettings: { openSettings() }
        )
    }

    private var panel: some View {
        VStack(spacing: 0) {
            TextField("Type a command or meeting name", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(12)
                .focused($searchFieldFocused)
                .onSubmit(commitSelection)
                .onExitCommand { onClose() }
                .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                    handleKeyPress(press)
                }
                .onChange(of: query) { _, _ in selectedIndex = 0 }
            Divider()
            resultlist
        }
        .frame(width: 520)
        .frame(maxHeight: 440)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 24)
    }

    @ViewBuilder
    private var resultlist: some View {
        let results = self.results
        if results.isEmpty {
            Text("No matching commands")
                .foregroundStyle(.secondary)
                .padding(20)
                .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: []) {
                    ForEach(Array(results.enumerated()), id: \.offset) {
                        index, item in
                        row(item, isSelected: index == selectedIndex)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func row(
        _ item: CommandPaletteItem,
        isSelected: Bool
    ) -> some View {
        Button {
            commit(item)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.section.systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(item.title)
                    .lineLimit(1)
                Spacer()
                if isSelected {
                    Image(systemName: "return")
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                isSelected
                    ? Color.accentColor.opacity(0.15)
                    : Color.clear
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .upArrow:
            moveSelection(-1)
            return .handled
        case .downArrow:
            moveSelection(1)
            return .handled
        default:
            return .ignored
        }
    }

    private func moveSelection(_ delta: Int) {
        let count = results.count
        guard count > 0 else { return }
        selectedIndex = min(max(selectedIndex + delta, 0), count - 1)
    }

    private func commitSelection() {
        let results = self.results
        guard results.indices.contains(selectedIndex) else { return }
        commit(results[selectedIndex])
    }

    /// Closes first so a follow-on sheet or recording UI appears over the
    /// regular window instead of under the palette overlay.
    private func commit(_ item: CommandPaletteItem) {
        onClose()
        item.perform()
    }
}
