import Foundation
import Testing
@testable import steno_macos

@Suite("Meeting app selection")
struct MeetingDetectionAppSelectionTests {
    private func withSelection(_ body: (MeetingDetectionAppSelection) throws -> Void) rethrows {
        let name = "MeetingDetectionAppSelectionTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(MeetingDetectionAppSelection(defaults: defaults))
    }

    @Test("defaults recognize meeting apps and their helpers but reject unrelated identities")
    func defaultPolicy() throws {
        try withSelection { selection in
            #expect(selection.allows("us.zoom.xos"))
            #expect(selection.allows("com.google.Chrome.helper"))
            #expect(selection.allows("company.thebrowser.browser.helper"))
            #expect(selection.allows("com.microsoft.teams2"))
            #expect(!selection.allows("com.google.ChromeUnrelated"))
            #expect(!selection.allows("com.apple.VoiceMemos"))
            #expect(!selection.allows("com.example.editor"))
            #expect(!selection.allows(nil))
            #expect(!selection.allows(""))
        }
    }

    @Test("selection persists and an explicitly empty selection stays empty")
    func persistence() throws {
        try withSelection { selection in
            for app in selection.apps { selection.setSelected(app, false) }
            let reloaded = MeetingDetectionAppSelection(defaults: selection.defaults)
            #expect(reloaded.selectedIDs.isEmpty)
            #expect(!reloaded.allows("us.zoom.xos"))
            reloaded.setSelected(.init(id: "us.zoom.xos", name: "Zoom"), true)
            #expect(selection.allows("us.zoom.xos.helper"))
            #expect(!selection.allows("com.google.Chrome"))
        }
    }

    @Test("custom apps persist, deduplicate and can be deselected")
    func customApps() throws {
        try withSelection { selection in
            let app = MeetingDetectionApp(id: "com.example.Meet", name: "Synthetic meeting app")
            selection.add(app)
            selection.add(.init(id: "COM.EXAMPLE.MEET", name: "Duplicate"))
            let reloaded = MeetingDetectionAppSelection(defaults: selection.defaults)
            #expect(reloaded.apps.filter { $0.id.lowercased() == app.id.lowercased() }.count == 1)
            #expect(reloaded.allows("com.example.meet.helper"))
            reloaded.setSelected(app, false)
            #expect(!selection.allows(app.id))
        }
    }

    @Test("invalid stored selections fail closed")
    func invalidPreferences() throws {
        try withSelection { selection in
            selection.defaults.set("invalid", forKey: MeetingDetectionAppSelection.selectionKey)
            #expect(!selection.allows("us.zoom.xos"))
        }
    }

    @Test("a deselected sibling and its helpers override the selected parent app")
    func moreSpecificSelectionWins() throws {
        try withSelection { selection in
            let parent = MeetingDetectionApp(id: "com.example.meet", name: "Meeting app")
            let beta = MeetingDetectionApp(id: "com.example.meet.beta", name: "Meeting app beta")
            selection.add(parent)
            selection.add(beta)
            selection.setSelected(beta, false)
            #expect(selection.allows(parent.id))
            #expect(!selection.allows(beta.id))
            #expect(!selection.allows(beta.id + ".helper"))
        }
    }

    @Test("shared browser and calling helpers obey the disclosed group selection")
    func sharedHelpers() throws {
        try withSelection { selection in
            let safari = MeetingDetectionApp(id: "com.apple.Safari", name: "Safari")
            let faceTime = MeetingDetectionApp(id: "com.apple.FaceTime", name: "FaceTime")
            #expect(selection.allows("com.apple.WebKit.GPU"))
            #expect(selection.allows("com.apple.avconferenced"))
            selection.setSelected(safari, false)
            selection.setSelected(faceTime, false)
            #expect(!selection.allows("com.apple.WebKit.GPU"))
            #expect(!selection.allows("com.apple.avconferenced"))
            // An explicitly listed shared helper overrides the broader group.
            let helper = MeetingDetectionApp(id: "com.apple.WebKit", name: "Browser helpers")
            selection.add(helper)
            selection.setSelected(helper, false)
            selection.setSelected(safari, true)
            #expect(!selection.allows("com.apple.WebKit.GPU"))
        }
    }
}
