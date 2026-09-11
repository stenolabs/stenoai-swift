import AppKit
import SwiftUI

/// Einstellungsfenster: Allgemein (Transkriptionssprache), Personen,
/// Sprachmodelle und Modelle (Zustimmung und Installation).
/// Erreichbar über das Zahnrad in der Toolbar und über Cmd-Komma.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            TranscriptionModelSettingsView()
                .tabItem { Label("Transcription", systemImage: "waveform.and.mic") }
            PeopleSettingsView()
                .tabItem { Label("People", systemImage: "person.2") }
            TextModelSettingsView()
                .tabItem { Label("Language Models", systemImage: "brain") }
            ModelStatusView()
                .tabItem { Label("Models", systemImage: "arrow.down.circle") }
            DemoDataSettingsView()
                .tabItem { Label(DemoDataPresentation.tabTitle, systemImage: "sparkles") }
        }
        .frame(width: 560)
    }
}

struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(OperatorProfile.self) private var profile

    // Wave-1 platform settings. `@AppStorage` writes plain UserDefaults and
    // treats an absent key as the initializer value, which matches the
    // "absent = default" reading on the integration side exactly.
    @AppStorage(PlatformPreferences.globalRecordHotkeyEnabledKey)
    private var globalRecordHotkeyEnabled = true
    @AppStorage("steno.notifications.enabled")
    private var notificationsEnabled = true
    @AppStorage(MeetingDetectionController.isEnabledDefaultsKey)
    private var meetingDetectionEnabled = true
    @State private var dockIconHidden = DockAppearance.isDockIconHidden
    @AppStorage(PlatformPreferences.silenceAutoStopEnabledKey)
    private var silenceAutoStopEnabled = false
    @AppStorage(PlatformPreferences.silenceAutoStopThresholdDBKey)
    private var silenceAutoStopThresholdDB =
        PlatformPreferences.silenceAutoStopDefaultThresholdDB
    @AppStorage(PlatformPreferences.silenceAutoStopIntervalSecondsKey)
    private var silenceAutoStopIntervalSeconds =
        PlatformPreferences.silenceAutoStopDefaultIntervalSeconds
    @AppStorage(ObsidianSyncPreferences.enabledKey)
    private var obsidianSyncEnabled = false
    @AppStorage(ObsidianSyncPreferences.vaultPathKey)
    private var obsidianVaultPath = ""
    @AppStorage(ObsidianSyncPreferences.lastSyncSummaryKey)
    private var obsidianLastSyncSummary = ""
    // Wave-4 local calendar reminders. Shown regardless of the EventKit
    // grant state; the first enable triggers the calendar prompt.
    @AppStorage(CalendarPreMeetingPreferences.isEnabledDefaultsKey)
    private var calendarRemindersEnabled = false
    @AppStorage(CalendarPreMeetingPreferences.lookAheadMinutesDefaultsKey)
    private var calendarLookAheadMinutes =
        CalendarPreMeetingPreferences.defaultLookAheadMinutes


    var body: some View {
        @Bindable var profile = profile
        Form {
            TranscriptionLanguagePicker()
            Text("Applies to new recordings and imports.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Section("Recording microphone") {
                MicrophoneSelectionControls()
            }
            TextField("Your name", text: $profile.name)
            TextField("Organisation (optional)", text: $profile.organization)
            Text(OperatorProfile.fieldNote)
                .font(.caption)
                .foregroundStyle(.secondary)
            Section("Recording controls") {
                Toggle(
                    "Global Record Hotkey (Cmd+Shift+R)",
                    isOn: $globalRecordHotkeyEnabled
                )
                .onChange(of: globalRecordHotkeyEnabled) { _, enabled in
                    model.setGlobalRecordHotkeyEnabled(enabled)
                }
                Toggle("Launch at Login", isOn: launchAtLoginBinding)
                Toggle("Hide Dock Icon", isOn: $dockIconHidden)
                    .onChange(of: dockIconHidden) { _, hidden in
                        DockAppearance.setDockIconHidden(hidden)
                    }
                Toggle("Notifications", isOn: $notificationsEnabled)
                Toggle(
                    "Detect Meetings Automatically",
                    isOn: $meetingDetectionEnabled
                )
            }
            Section("Calendar Reminders") {
                Toggle(
                    "Remind Me About Upcoming Calendar Events",
                    isOn: $calendarRemindersEnabled
                )
                .onChange(of: calendarRemindersEnabled) { _, enabled in
                    // First enable triggers the EventKit prompt right here
                    // instead of waiting for the next scheduler pass.
                    if enabled { CalendarPreMeetingScheduler.shared.prepare() }
                }
                Stepper(
                    "Remind me before: \(calendarLookAheadMinutes) min",
                    value: $calendarLookAheadMinutes,
                    in: CalendarPreMeetingPreferences.lookAheadRange,
                    step: 5
                )
                Text("Steno reads this Mac's local calendar to remind you shortly before a meeting starts. Event details stay on this device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Automatic Stop") {
                Toggle("Stop Recording After Silence", isOn: $silenceAutoStopEnabled)
                if silenceAutoStopEnabled {
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent("Silence threshold") {
                            Text("\(Int(silenceAutoStopThresholdDB)) dBFS")
                                .monospacedDigit()
                        }
                        Slider(
                            value: $silenceAutoStopThresholdDB,
                            in: -80.0...0.0,
                            step: 1
                        )
                        Text("Audio below this level counts as silence; a higher threshold stops the recording sooner.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Stepper(
                        "Silence interval: \(Int(silenceAutoStopIntervalSeconds)) s",
                        value: $silenceAutoStopIntervalSeconds,
                        in: 10.0...3600.0,
                        step: 10.0
                    )
                    Text("The recording stops automatically after this much continuous silence.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            LibraryLocationSection()
            Section("Obsidian Export") {
                Toggle("Mirror Meetings to Obsidian Vault", isOn: $obsidianSyncEnabled)
                LabeledContent("Vault Folder") {
                    Text(obsidianVaultPath.isEmpty ? "Not set" : obsidianVaultPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(obsidianVaultPath.isEmpty ? .secondary : .primary)
                }
                Button("Choose Vault Folder…") { chooseObsidianVaultFolder() }
                Button("Export All Meetings Now") {
                    Task { await model.syncObsidianVault() }
                }
                .disabled(!obsidianSyncEnabled || obsidianVaultPath.isEmpty)
                if !obsidianLastSyncSummary.isEmpty {
                    Text(obsidianLastSyncSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(
                        "Steno writes one Markdown file per meeting into the vault. "
                            + "It never reads or deletes anything there."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            if let layout = model.runtime?.library.layout {
                EncryptionSettingsSection(layout: layout)
            }
            BulkExportSection()

        }
        .formStyle(.grouped)
        .frame(minHeight: 240)
    }
}

/// General-tab storage-location rows: shows the effective library location,
/// offers directory selection via NSOpenPanel, and clears the override.
/// All decisions live in `LibraryLocationForm` so the flow is testable
/// without driving a modal panel.
struct LibraryLocationSection: View {
    @State private var form: LibraryLocationForm

    init(defaults: UserDefaults = .standard) {
        _form = State(initialValue: LibraryLocationForm(defaults: defaults))
    }

    var body: some View {
        Section("Library Location") {
            LabeledContent("Storage location") {
                Text(verbatim: form.displayPath)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(form.displayPath)
            }
            HStack {
                Button("Choose...") { chooseDirectory() }
                if form.hasCustomPath {
                    Button("Clear", role: .destructive) { form.clear() }
                }
            }
            if let failure = form.validationFailure {
                Text(failure.message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Text(
                "A custom location applies the next time the app starts. Move an existing library manually while Steno is closed."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        form.choose(url: url)
    }
}

@MainActor
@Observable
final class LibraryLocationForm {
    private let defaults: UserDefaults

    var validationFailure: StorageLocation.ValidationFailure?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// True while a custom path overrides the standard location.
    var hasCustomPath: Bool {
        StorageLocation.customPath(defaults: defaults) != nil
    }

    /// The effective location as startup would resolve it today; shown so
    /// users can see where their data lives even when an environment
    /// override is in play.
    var displayPath: String {
        StorageLocation.effectiveLibraryDirectory(defaults: defaults).path
    }

    /// Validates the picked directory before persisting it; an invalid pick
    /// leaves the stored setting untouched and surfaces the reason inline.
    func choose(url: URL) {
        if let failure = StorageLocation.validate(path: url.path) {
            validationFailure = failure
            return
        }
        StorageLocation.setCustomPath(url.path, defaults: defaults)
        validationFailure = nil
    }

    func clear() {
        StorageLocation.setCustomPath(nil, defaults: defaults)
        validationFailure = nil
    }
}

/// Der eine Auswahlkasten fuer die Transkriptionssprache. Einstellungen und
/// Wizard zeigen denselben, weil zwei Kopien auseinanderdriften: der Wechsel
/// startet die Pipeline neu, und das darf nicht an zwei Stellen verschieden
/// verdrahtet sein.
struct TranscriptionLanguagePicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Transcription language", selection: Binding(
                get: {
                    model.transcriptionLanguageSelection.selectsAutomatic
                        ? TranscriptionLanguageSelection.automaticIdentifier
                        : model.effectiveTranscriptionLanguageID
                },
                set: { newValue in
                    Task { await model.setLanguage(newValue) }
                }
            )) {
                Text("Automatic (detect language)")
                    .tag(TranscriptionLanguageSelection.automaticIdentifier)
                ForEach(model.availableLocales, id: \.identifier) { locale in
                    Text(model.localizedLanguageName(locale))
                        .tag(locale.identifier)
                }
            }
            .disabled(
                model.availableLocales.isEmpty
                    || model.isRecording
                    || model.isStartingRecording
                    || model.isBootstrappingPipeline
                    || model.isSwitchingTranscriptionLanguage
                    || model.isManagingDemoData
            )

            if let message = TranscriptionLanguagePickerPresentation.lockMessage(
                isRecording: model.isRecording,
                isStartingRecording: model.isStartingRecording,
                isPreparingPipeline: model.isBootstrappingPipeline
                    || model.isSwitchingTranscriptionLanguage,
                isManagingDemoData: model.isManagingDemoData
            ) {
                Label(message, systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if model.transcriptionLanguageSelection.selectsAutomatic {
                Label {
                    Text(TranscriptionLanguagePickerPresentation.automaticDescription(
                        startLanguageName: model.selectedTranscriptionLanguageName
                    ))
                } icon: {
                    Image(systemName: "sparkles")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

enum TranscriptionLanguagePickerPresentation {
    static func lockMessage(
        isRecording: Bool,
        isStartingRecording: Bool,
        isPreparingPipeline: Bool,
        isManagingDemoData: Bool = false
    ) -> String? {
        if isRecording {
            return String(localized: "The transcription language cannot change while a recording is running.")
        }
        if isStartingRecording {
            return String(localized: "The transcription language cannot change while a recording is starting.")
        }
        if isPreparingPipeline {
            return String(localized: "The transcription language cannot change while transcription is being prepared.")
        }
        if isManagingDemoData {
            return String(localized: DemoDataPresentation.languageChangeLocked)
        }
        return nil
    }
}

extension TranscriptionLanguagePickerPresentation {
    /// Caption shown while the Automatic option is selected: what detection
    /// does, which language the recording starts with, and that a detected
    /// different language switches the live lane once mid-recording.
    static func automaticDescription(startLanguageName: String) -> String {
        String(
            localized: "Steno starts in \(startLanguageName) and switches once it has enough speech to detect the language. The final transcript uses the detected language."
        )
    }
}

extension GeneralSettingsView {
    /// Bound to the live SMAppService status instead of a stored flag, so
    /// approval granted (or revoked) in System Settings is reflected here.
    /// Failures - typically `LoginItemError.requiresApproval`, which means
    /// the item sits unapproved in System Settings > General > Login Items -
    /// surface through the app's regular notice presentation.
    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: {
                switch LoginItem.registrationStatus() {
                case .enabled, .requiresApproval: return true
                default: return false
                }
            },
            set: { enabled in
                do {
                    try LoginItem.setEnabled(enabled)
                } catch {
                    model.report(verbatim: error.localizedDescription)
                }
            }
        )
    }
}

extension GeneralSettingsView {
    /// Directory picker for the Obsidian vault. Only the chosen path is
    /// stored; the folder itself is created by the first export if missing.
    private func chooseObsidianVaultFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the Obsidian vault folder Steno should mirror meetings into."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        obsidianVaultPath = url.path
    }
}

// MARK: - Bulk export
//
// Parity with the legacy Advanced-tab "export all" actions: one Markdown
// file per meeting into a chosen directory, or a single CSV file. Both run
// through AppModel so they use exactly the same documents as the individual
// meeting exports.

struct BulkExportSection: View {
    @Environment(AppModel.self) private var model

    @State private var isRunning = false
    @State private var statusLine = ""

    var body: some View {
        Section("Export") {
            Button("Export All Meetings as Markdown…") { runMarkdownExport() }
                .disabled(isRunning)
            Button("Export All Meetings as CSV…") { runCSVExport() }
                .disabled(isRunning)
            if isRunning {
                Text("Exporting…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !statusLine.isEmpty {
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func runMarkdownExport() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message =
            "Choose an empty folder. Steno writes one Markdown file per meeting."
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        start { await model.exportAllMeetingsAsMarkdown(to: directory) }
    }

    private func runCSVExport() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Steno-Notes.csv"
        panel.allowedContentTypes = [.init(filenameExtension: "csv")].compactMap { $0 }
        panel.canCreateDirectories = true
        panel.message = "Save all meetings as one CSV file."
        guard panel.runModal() == .OK, let fileURL = panel.url else { return }
        start { await model.exportAllMeetingsAsCSV(to: fileURL) }
    }

    /// Shared runner: disables both buttons for the duration and shows the
    /// completion or error line afterwards.
    private func start(_ work: @escaping () async -> BulkExportOutcome) {
        isRunning = true
        statusLine = ""
        Task { @MainActor in
            let outcome = await work()
            isRunning = false
            switch outcome {
            case .success(let count):
                statusLine = "Successfully exported \(count) meetings."
            case .failure(let message):
                statusLine = message
            }
        }
    }
}
