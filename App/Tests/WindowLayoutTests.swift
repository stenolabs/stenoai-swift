import AppKit
import SwiftUI
import Testing
@testable import steno_macos

@Suite("Window layout")
@MainActor
struct WindowLayoutTests {
    @Test("library and empty detail use the descriptive meetings title")
    func usesMeetingsTitle() {
        let english = Locale(identifier: "en_US_POSIX")

        #expect(String(
            localized: MacWindowPresentation.meetingsTitle.defaultValue,
            locale: english
        ) == "Meetings")
    }

    @Test("startup views use the meetings title instead of the app name")
    func startupViewsUseMeetingsTitle() throws {
        let appDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: appDirectory.appending(path: "Sources/MacStartupPresentation.swift"),
            encoding: .utf8
        )

        #expect(!source.contains(".navigationTitle(\"Steno\")"))
        #expect(source.components(
            separatedBy: ".navigationTitle(MacWindowPresentation.meetingsTitle)"
        ).count - 1 == 2)
    }

    @Test("long scrollable meeting content does not demand a taller window")
    func longMeetingContentKeepsWindowSizeStable() {
        let view = WindowStableDetail {
            ScrollView {
                LazyVStack {
                    Text(
                        String(
                            repeating: "A long transcript line that must stay inside the scroll view. ",
                            count: 1_000
                        )
                    )
                }
            }
        }
        let host = NSHostingView(rootView: view)
        let proposed = NSSize(width: 640, height: 700)
        host.setFrameSize(proposed)
        host.layoutSubtreeIfNeeded()

        #expect(
            host.fittingSize.height <= proposed.height,
            "Scrollable meeting content requested \(host.fittingSize.height) points for a \(proposed.height)-point window."
        )
    }

    @Test("multi-selection summary stays inside the current window")
    func multiSelectionKeepsWindowSizeStable() {
        let view = WindowStableDetail {
            MultiMeetingSelectionView(count: 123_456_789)
        }
        let host = NSHostingView(rootView: view)
        let proposed = NSSize(width: 640, height: 700)
        host.setFrameSize(proposed)
        host.layoutSubtreeIfNeeded()

        #expect(
            host.fittingSize.height <= proposed.height,
            "Multi-selection requested \(host.fittingSize.height) points for a \(proposed.height)-point window."
        )
    }

    @Test("dynamic sidebar headers stay inside the current split-view height")
    func dynamicSidebarHeaderKeepsWindowSizeStable() {
        let proposed = NSSize(width: 900, height: 420)
        let host = NSHostingView(rootView: SidebarLayoutFixture(headerHeight: 120))
        host.setFrameSize(proposed)
        host.layoutSubtreeIfNeeded()

        for headerHeight in [340.0, 120.0, 280.0, 160.0, 320.0, 120.0] {
            host.rootView = SidebarLayoutFixture(headerHeight: headerHeight)
            host.setFrameSize(proposed)
            host.layoutSubtreeIfNeeded()

            #expect(
                host.fittingSize.height <= proposed.height,
                "A \(headerHeight)-point sidebar header requested \(host.fittingSize.height) points for a \(proposed.height)-point window."
            )
        }
    }

    @Test("inspector visibility does not change the window minimum size")
    func inspectorKeepsWindowMinimumSizeStable() {
        let proposed = NSSize(width: 1_240, height: 780)
        let host = NSHostingView(
            rootView: WindowRootSizingFixture(showsInspector: false)
        )
        host.setFrameSize(proposed)
        host.layoutSubtreeIfNeeded()
        let closedMinimum = host.fittingSize

        host.rootView = WindowRootSizingFixture(showsInspector: true)
        host.setFrameSize(proposed)
        host.layoutSubtreeIfNeeded()
        let openMinimum = host.fittingSize

        #expect(closedMinimum == MacWindowPresentation.minimumContentSize)
        #expect(openMinimum == closedMinimum)
    }

    @Test("selecting and deleting meetings completes the window transitions")
    func meetingSelectionTransitionsComplete() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Steno-DeleteWindowTransitionTests-\(UUID().uuidString)",
                isDirectory: true
            )
        let libraryURL = root.appendingPathComponent("Library", isDirectory: true)
        let modelURL = root.appendingPathComponent("Models", isDirectory: true)
        let trashURL = root.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(
            at: trashURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let model = AppModel(
            meetingTrasher: { library, meetingID in
                let source = library.layout.meetingDirectory(meetingID)
                let destination = trashURL.appendingPathComponent(
                    meetingID.description,
                    isDirectory: true
                )
                try FileManager.default.moveItem(at: source, to: destination)
                return destination
            },
            libraryURL: libraryURL,
            modelCacheDirectoryOverride: modelURL
        )
        await model.bootstrap()
        let runtime = try #require(model.runtime)

        let controller = NSHostingController(
            rootView: ContentView()
                .environment(model)
                .environment(TextModelSettings())
                .environment(OperatorProfile.shared)
                .environment(OnboardingModel())
        )
        controller.sizingOptions = [.minSize]
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 1_240, height: 780)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.toolbar = NSToolbar(identifier: "SyntheticMeetingSelectionToolbar")
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1_240, height: 780))
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        let firstDraft = try await runtime.library.createMeeting(
            title: "Synthetic draft A",
            status: .draft
        )
        let secondDraft = try await runtime.library.createMeeting(
            title: "Synthetic draft B",
            status: .draft
        )
        await model.refreshMeetings()

        // Exercise the reported path directly: replace one detail while its
        // automatically opened inspector is present, then let the next detail
        // load and open its own inspector.
        for iteration in 0..<12 {
            let selected = iteration.isMultiple(of: 2) ? firstDraft.id : secondDraft.id
            model.selectedMeetingIDs = [selected]
            for _ in 0..<15 {
                try await Task.sleep(for: .milliseconds(20))
                window.layoutIfNeeded()
            }
            #expect(model.selectedMeetingID == selected)
        }

        model.selectedMeetingIDs = []

        for iteration in 0..<20 {
            let meeting = try await runtime.library.createMeeting(
                title: "Synthetic meeting \(iteration)",
                status: iteration.isMultiple(of: 2) ? .draft : .ready
            )
            await model.refreshMeetings()
            model.selectedMeetingIDs = [meeting.id]

            for _ in 0..<12 {
                try await Task.sleep(for: .milliseconds(20))
                window.layoutIfNeeded()
            }

            await model.deleteMeeting(meeting.id)

            for _ in 0..<12 {
                try await Task.sleep(for: .milliseconds(20))
                window.layoutIfNeeded()
            }

            #expect(model.selectedMeetingIDs.isEmpty)
            #expect(!model.meetings.contains(where: { $0.id == meeting.id }))
            #expect(model.pendingTrashUndo != nil)
        }

        await model.stopBackgroundLibraryTasksForTesting()
        await model.runtime?.coordinator.stop()
    }
}

private struct WindowRootSizingFixture: View {
    let showsInspector: Bool

    var body: some View {
        WindowStableRoot {
            NavigationSplitView {
                WindowStableSidebar {
                    Color.clear.frame(height: 80)
                } content: {
                    List(0..<5, id: \.self) { index in
                        Text("Meeting \(index)")
                    }
                }
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 320)
            } detail: {
                WindowStableDetail {
                    Text("Meeting detail")
                        .inspector(isPresented: .constant(showsInspector)) {
                            Text("Meeting inspector")
                                .inspectorColumnWidth(min: 300, ideal: 360, max: 460)
                        }
                }
            }
            .safeAreaInset(edge: .top) { Color.clear.frame(height: 24) }
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 24) }
        }
        .frame(
            minWidth: MacWindowPresentation.minimumContentSize.width,
            minHeight: MacWindowPresentation.minimumContentSize.height
        )
    }
}

private struct SidebarLayoutFixture: View {
    let headerHeight: CGFloat

    var body: some View {
        NavigationSplitView {
            WindowStableSidebar {
                Color.clear
                    .frame(height: headerHeight)
            } content: {
                List(0..<100, id: \.self) { index in
                    Text("Meeting \(index)")
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 280)
        } detail: {
            Text("Meeting detail")
        }
    }
}
