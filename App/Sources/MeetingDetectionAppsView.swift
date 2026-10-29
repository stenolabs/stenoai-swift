import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MeetingDetectionAppsView: View {
    private let selection = MeetingDetectionAppSelection()
    @State private var apps = MeetingDetectionAppSelection().apps
    @State private var selectedIDs = MeetingDetectionAppSelection().selectedIDs
    @State private var invalidApp = false

    var body: some View {
        DisclosureGroup("Meeting Apps") {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(apps) { app in
                        Toggle(isOn: Binding(
                            get: { selectedIDs.contains(app.id.lowercased()) },
                            set: { enabled in
                                selection.setSelected(app, enabled)
                                selectedIDs = selection.selectedIDs
                            }
                        )) { Text(verbatim: app.name) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
            Button("Add App...") { chooseApp() }
            if invalidApp {
                Text("The selected app cannot be identified.")
                    .foregroundStyle(.red)
            }
            Text("Only selected apps trigger meeting notifications. Selected browsers can trigger a notification for any website using the microphone. Recording still starts manually.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let id = Bundle(url: url)?.bundleIdentifier, !id.isEmpty else {
            invalidApp = true
            return
        }
        invalidApp = false
        selection.add(MeetingDetectionApp(
            id: id,
            name: FileManager.default.displayName(atPath: url.path)
        ))
        apps = selection.apps
        selectedIDs = selection.selectedIDs
    }
}
