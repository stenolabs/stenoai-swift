import AppKit
import SwiftUI

@main
struct StenoApp: App {
    @State private var model = AppModel()
    @State private var textModelSettings = TextModelSettings()
    #if STENO_NATIVE_GEMMA_MODEL_STORE && canImport(StenoGemmaClient)
    @State private var nativeGemmaModelSettings = NativeGemmaModelSettings()
    #endif
    @State private var operatorProfile = OperatorProfile.shared
    @State private var onboarding = OnboardingModel()
    @Environment(\.openWindow) private var openWindow
    @NSApplicationDelegateAdaptor(StenoAppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Meetings", id: "main") {
            ContentView()
                .environment(model)
                .environment(textModelSettings)
                #if STENO_NATIVE_GEMMA_MODEL_STORE && canImport(StenoGemmaClient)
                .environment(nativeGemmaModelSettings)
                #endif
                .environment(operatorProfile)
                .environment(onboarding)
            .task {
                #if STENO_NATIVE_GEMMA_MODEL_STORE && canImport(StenoGemmaClient)
                Task { await nativeGemmaModelSettings.refreshInstalled() }
                #endif
                // Vor `bootstrap`, damit der erste Start nicht erst die
                // Bibliothek oeffnet und dann den Wizard nachschiebt.
                if !onboarding.isFinished { openWindow(id: "onboarding") }
                // Beim Start nur vorhandene TCC-Entscheidungen lesen.
                // Anfordern darf erst der erklaerende Wizard oder der
                // ausdrueckliche erste Aufnahmeversuch.
                model.refreshRecordingPermissionStatus()
                // Menu bar item, global record hotkey and meeting
                // detection are process-wide and install exactly once.
                model.installPlatformIntegrations(
                    openMainWindow: { openMainWindow() }
                )
                // Process-wide job-completion watcher; reads runtime fresh
                // per pass, so installing before bootstrap finishes is fine.
                model.installNotificationHooks()
                CalendarPreMeetingScheduler.shared.start()
                await model.bootstrap()
                model.syncMenuBar()
            }
            .onOpenURL { model.handleDeepLink($0) }
            .onChange(of: model.isRecording) { _, _ in model.syncMenuBar() }
            .onChange(of: model.isStartingRecording) { _, _ in
                model.syncMenuBar()
            }
            .onChange(of: model.isResolvingRecordingPermissions) { _, _ in
                model.syncMenuBar()
            }
            .onChange(of: model.isBootstrappingPipeline) { _, _ in
                model.syncMenuBar()
            }
            .onChange(of: model.startupState) { _, _ in model.syncMenuBar() }
        }
        // Drei Spalten: Seitenleiste, Transkript, Inspector. Bei 980 pt
        // blieben dem Transkript keine 500 pt.
        .defaultSize(width: 1240, height: 780)
        .windowResizability(.contentMinSize)
        .commands {
            StenoCommands(
                model: model,
                openLegacyImport: {
                    openWindow(id: "legacy-import")
                },
                openSetupAssistant: {
                    onboarding.reopen()
                    openWindow(id: "onboarding")
                }
            )
            ToolbarCommands()
        }

        Window("Import from Legacy Steno App", id: "legacy-import") {
            LegacyImportView()
                .environment(model)
        }
        .defaultSize(width: 600, height: 480)

        Window("Import from Granola", id: "granola-import") {
            GranolaImportView()
                .environment(model)
        }
        .defaultSize(width: 600, height: 480)

        Window("Welcome to Steno", id: "onboarding") {
            OnboardingView()
                .environment(model)
                .environment(onboarding)
                .environment(operatorProfile)
        }
        .defaultSize(width: 620, height: 480)

        Window("My Notes", id: "my-notes") {
            NotesOverviewWindow()
                .environment(model)
        }
        .defaultSize(width: 520, height: 720)

        Window("People Directory", id: "people-directory") {
            PeopleDirectoryWindow()
                .environment(model)
        }
        .defaultSize(width: 780, height: 560)

        Window("Library Chat", id: "library-chat") {
            LibraryChatWindow()
                .environment(model)
                .environment(textModelSettings)
                #if STENO_NATIVE_GEMMA_MODEL_STORE && canImport(StenoGemmaClient)
                .environment(nativeGemmaModelSettings)
                #endif
        }
        .defaultSize(width: 820, height: 640)

        Settings {
            SettingsView()
                .environment(model)
                .environment(textModelSettings)
                #if STENO_NATIVE_GEMMA_MODEL_STORE && canImport(StenoGemmaClient)
                .environment(nativeGemmaModelSettings)
                #endif
                .environment(operatorProfile)
        }
    }
}

extension StenoApp {
    /// Menu bar "Open Steno" target. Activating the app is required in
    /// `.accessory` mode (hidden Dock icon); SwiftUI's `openWindow` alone
    /// does not order the window front there.
    func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "main")
        if let mainWindow = NSApp.windows.first(where: { $0.title == "Meetings" }) {
            mainWindow.makeKeyAndOrderFront(nil)
        }
    }
}

/// Applies the persisted Dock icon policy during `applicationWillFinishLaunching`,
/// i.e. BEFORE the first activation event - otherwise a menu-bar-only setup
/// would briefly flash the Dock icon at launch.
private final class StenoAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        DockAppearance.applyPersistedPolicy()
    }
}
