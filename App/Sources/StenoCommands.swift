import SwiftUI

enum StenoCommandID: Hashable {
    case startRecording
    case stopRecording
    case markMoment
    case newMeeting
    case importAudio
    case importMeetingPackage
    case findTranscript
    case toggleInspector
    case moveToTrash
    case toggleAskBar
    case commandPalette
}

struct StenoCommandShortcut: Hashable {
    enum Key: Hashable {
        case character(Character)
        case delete
    }

    struct Modifiers: OptionSet, Hashable {
        let rawValue: UInt8

        static let command = Modifiers(rawValue: 1 << 0)
        static let shift = Modifiers(rawValue: 1 << 1)
        static let option = Modifiers(rawValue: 1 << 2)
        static let control = Modifiers(rawValue: 1 << 3)
    }

    let key: Key
    let modifiers: Modifiers

    init(_ character: Character, modifiers: Modifiers) {
        self.init(.character(character), modifiers: modifiers)
    }

    init(_ key: Key, modifiers: Modifiers) {
        self.key = key
        self.modifiers = modifiers
    }

    var keyEquivalent: KeyEquivalent {
        switch key {
        case .character(let character):
            KeyEquivalent(character)
        case .delete:
            .delete
        }
    }

    var eventModifiers: EventModifiers {
        var result: EventModifiers = []
        if modifiers.contains(.command) { result.insert(.command) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        if modifiers.contains(.option) { result.insert(.option) }
        if modifiers.contains(.control) { result.insert(.control) }
        return result
    }
}

enum StenoCommandShortcuts {
    // Cmd-M and Cmd-I retain their standard macOS meanings. Recording actions
    // therefore use shifted variants, and Cmd-. remains the safe Stop command.
    static let all: [StenoCommandID: StenoCommandShortcut] = [
        .startRecording: StenoCommandShortcut("r", modifiers: [.command]),
        .stopRecording: StenoCommandShortcut(".", modifiers: [.command]),
        .markMoment: StenoCommandShortcut("m", modifiers: [.command, .shift]),
        .newMeeting: StenoCommandShortcut("n", modifiers: [.command]),
        .importAudio: StenoCommandShortcut("i", modifiers: [.command, .shift]),
        .importMeetingPackage: StenoCommandShortcut("i", modifiers: [.command, .option]),
        .findTranscript: StenoCommandShortcut("f", modifiers: [.command]),
        .toggleInspector: StenoCommandShortcut("i", modifiers: [.command, .control]),
        .moveToTrash: StenoCommandShortcut(.delete, modifiers: [.command]),
        .toggleAskBar: StenoCommandShortcut("a", modifiers: [.command, .shift]),
        .commandPalette: StenoCommandShortcut("k", modifiers: [.command]),

    ]
    static func shortcut(for command: StenoCommandID) -> StenoCommandShortcut {
        guard let shortcut = all[command] else {
            preconditionFailure("Missing shortcut for \(command)")
        }
        return shortcut
    }
}

struct StenoCommandState: Equatable {
    let hasRuntime: Bool
    let isRecording: Bool
    let isStartingRecording: Bool
    let isMovingMeetingsToTrash: Bool
    let isResolvingRecordingPermissions: Bool

    var canStartRecording: Bool {
        hasRuntime
            && !isRecording
            && !isStartingRecording
            && !isMovingMeetingsToTrash
            && !isResolvingRecordingPermissions
    }

    var canStopRecording: Bool {
        isRecording
    }

    var canMarkMoment: Bool {
        isRecording
    }

    var canCreateMeeting: Bool {
        hasRuntime
            && !isRecording
            && !isStartingRecording
            && !isMovingMeetingsToTrash
    }

    var canImport: Bool {
        hasRuntime
            && !isRecording
            && !isStartingRecording
            && !isMovingMeetingsToTrash
    }

    @MainActor
    init(model: AppModel) {
        self.init(
            hasRuntime: model.runtime != nil,
            isRecording: model.isRecording,
            isStartingRecording: model.isStartingRecording,
            isMovingMeetingsToTrash: model.isMovingMeetingsToTrash,
            isResolvingRecordingPermissions:
                model.isResolvingRecordingPermissions
        )
    }

    init(
        hasRuntime: Bool,
        isRecording: Bool,
        isStartingRecording: Bool,
        isMovingMeetingsToTrash: Bool = false,
        isResolvingRecordingPermissions: Bool = false
    ) {
        self.hasRuntime = hasRuntime
        self.isRecording = isRecording
        self.isStartingRecording = isStartingRecording
        self.isMovingMeetingsToTrash = isMovingMeetingsToTrash
        self.isResolvingRecordingPermissions =
            isResolvingRecordingPermissions
    }
}

struct StenoCommands: Commands {
    let model: AppModel
    let openLegacyImport: () -> Void
    let openSetupAssistant: () -> Void

    @FocusedValue(\.stenoMeetingCommandContext)
    private var focusedMeetingContext
    @FocusedValue(\.stenoFolderCommandContext)
    private var focusedFolderContext
    @FocusedValue(\.stenoMeetingDetailCommandContext)
    private var focusedMeetingDetailContext

    var body: some Commands {
        let state = StenoCommandState(model: model)
        let focusedTarget = MacFocusedCommandResolver.target(
            meetingIDs: focusedMeetingContext?.meetingIDs ?? [],
            folderID: focusedFolderContext?.folderID
        )
        let meetingContext: MacMeetingCommandContext? = switch focusedTarget {
        case .meetings: focusedMeetingContext
        case .folder, .none: nil
        }
        let folderContext: MacFolderCommandContext? = switch focusedTarget {
        case .folder: focusedFolderContext
        case .meetings, .none: nil
        }
        let detailContext = folderContext == nil
            ? focusedMeetingDetailContext
            : nil

        CommandMenu("Recording") {
            Button("Start Recording") {
                Task { await model.startRecording() }
            }
            .stenoKeyboardShortcut(.startRecording)
            .disabled(!state.canStartRecording)

            Button("Stop Recording") {
                Task { await model.stopRecording() }
            }
            .stenoKeyboardShortcut(.stopRecording)
            .disabled(!state.canStopRecording)

            Divider()

            Button("Mark This Moment") {
                Task { await model.markMoment() }
            }
            .stenoKeyboardShortcut(.markMoment)
            .disabled(!state.canMarkMoment)

            Divider()

            // F14/F11 companion: flips the persisted visibility of the
            // recording ask bar. AskBarView/RecordingView read the same key
            // through @AppStorage, so the bar reacts immediately and the
            // choice survives restarts.
            Button("Show or Hide Ask Bar") {
                Self.toggleAskBarVisibility()
            }
            .stenoKeyboardShortcut(.toggleAskBar)
        }

        CommandGroup(replacing: .newItem) {
            Button("New note") {
                Task { await model.createDraftMeeting() }
            }
            .stenoKeyboardShortcut(.newMeeting)
            .disabled(!state.canCreateMeeting)
        }

        CommandGroup(after: .importExport) {
            Button("Import Audio File…") {
                model.requestAudioImport()
            }
            .stenoKeyboardShortcut(.importAudio)
            .disabled(!state.canImport)

            Button("Import Meeting Package…") {
                model.requestMeetingTransferImport()
            }
            .stenoKeyboardShortcut(.importMeetingPackage)
            .disabled(!state.canImport)

            Button("Import from Legacy Steno App…") {
                openLegacyImport()
            }
            .disabled(!state.canImport)

            Divider()

            Button("Export Meeting as Markdown…") {
                meetingContext?.exportMarkdown()
            }
            .disabled(
                meetingContext?.availability.canExportMarkdown != true
            )

            Button("Export Meeting Audio…") {
                meetingContext?.exportAudio()
            }
            .disabled(
                meetingContext?.availability.canExportAudio != true
            )

            Button("Share Meeting…") {
                detailContext?.share()
            }
            .disabled(detailContext?.availability.canShare != true)
        }

        CommandMenu("Meeting") {
            Button("Find in Transcript") {
                detailContext?.findTranscript()
            }
            .stenoKeyboardShortcut(.findTranscript)
            .disabled(
                detailContext?.availability.canFindTranscript != true
            )

            Button("Show or Hide Inspector") {
                detailContext?.toggleInspector()
            }
            .stenoKeyboardShortcut(.toggleInspector)
            .disabled(
                detailContext?.availability.canToggleInspector != true
            )

            Divider()

            Button("Rename Meeting…") {
                meetingContext?.rename()
            }
            .disabled(meetingContext?.availability.canRename != true)

            Menu("Move to Folder") {
                ForEach(meetingContext?.folderDestinations ?? []) {
                    destination in
                    Button(destination.name) {
                        meetingContext?.moveToFolder(destination.id)
                    }
                }
                if meetingContext?.folderDestinations.isEmpty == false {
                    Divider()
                }
                Button("None") {
                    meetingContext?.moveToFolder(nil)
                }
            }
            .disabled(meetingContext?.availability.canMove != true)

            Button("Transcribe Again…") {
                meetingContext?.retranscribe()
            }
            .disabled(
                meetingContext?.availability.canRetranscribe != true
            )

            Divider()

            Button(role: .destructive) {
                meetingContext?.moveToTrash()
            } label: {
                Text(MeetingTrashRequest.commandTitle(
                    meetingCount: meetingContext?.meetingIDs.count ?? 1
                ))
            }
            .stenoKeyboardShortcut(.moveToTrash)
            .disabled(
                meetingContext?.availability.canMoveToTrash != true
            )
        }

        CommandMenu("Folder") {
            Button("New Subfolder…") {
                folderContext?.createSubfolder()
            }
            .disabled(
                folderContext?.availability.canCreateSubfolder
                    != true
            )

            Button("Rename Folder…") {
                folderContext?.rename()
            }
            .disabled(
                folderContext?.availability.canRename != true
            )

            Divider()

            Button("Move Folder Up") {
                folderContext?.moveUp()
            }
            .disabled(
                folderContext?.availability.canMoveUp != true
            )

            Button("Move Folder Down") {
                folderContext?.moveDown()
            }
            .disabled(
                folderContext?.availability.canMoveDown != true
            )

            Menu("Move Folder into Folder") {
                ForEach(
                    folderContext?.nestingDestinations ?? []
                ) { destination in
                    Button(destination.name) {
                        folderContext?.moveIntoFolder(destination.id)
                    }
                }
            }
            .disabled(
                folderContext?.nestingDestinations.isEmpty != false
            )

            Button("Move Folder to Top Level") {
                folderContext?.moveToTopLevel()
            }
            .disabled(
                folderContext?.availability.canMoveToTopLevel
                    != true
            )

            Divider()

            Button("Delete Folder…", role: .destructive) {
                folderContext?.delete()
            }
            .disabled(
                folderContext?.availability.canDelete != true
            )
        }

        CommandGroup(after: .toolbar) {
            Button("Command Palette…") {
                openCommandPalette()
            }
            .stenoKeyboardShortcut(.commandPalette)
        }

        CommandGroup(replacing: .help) {
            Button("Show Setup Assistant") {
                openSetupAssistant()
            }
        }
    }

    /// Opens the Cmd-K command palette. The focused-window contexts are
    /// snapshotted here because the palette's own search field takes
    /// keyboard focus as soon as it appears, which would nil out every
    /// @FocusedValue inside it.
    private func openCommandPalette() {
        let focusedTarget = MacFocusedCommandResolver.target(
            meetingIDs: focusedMeetingContext?.meetingIDs ?? [],
            folderID: focusedFolderContext?.folderID
        )
        let meeting: MacMeetingCommandContext? = switch focusedTarget {
        case .meetings: focusedMeetingContext
        case .folder, .none: nil
        }
        let folder: MacFolderCommandContext? = switch focusedTarget {
        case .folder: focusedFolderContext
        case .meetings, .none: nil
        }
        let detail = folder == nil ? focusedMeetingDetailContext : nil
        model.commandPaletteContexts = CommandPaletteContexts(
            meeting: meeting,
            folder: folder,
            detail: detail
        )
        model.isCommandPalettePresented = true
    }

    /// Cmd-Shift-A flips the persisted ask-bar visibility
    /// (`AskBarView.visibilityDefaultsKey`). The recording UI observes the
    /// same key via @AppStorage, so an in-flight recording reacts live.
    static func toggleAskBarVisibility() {
        let key = AskBarView.visibilityDefaultsKey
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: key), forKey: key)
    }
}

private extension View {
    func stenoKeyboardShortcut(_ command: StenoCommandID) -> some View {
        let shortcut = StenoCommandShortcuts.shortcut(for: command)
        return keyboardShortcut(
            shortcut.keyEquivalent,
            modifiers: shortcut.eventModifiers
        )
    }
}
