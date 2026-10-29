import Foundation

struct MeetingDetectionApp: Codable, Equatable, Identifiable {
    let id: String
    let name: String
}

/// Local notification policy. It never starts recording or reads audio.
struct MeetingDetectionAppSelection {
    static let selectionKey = "steno.meetingDetection.selectedApps"
    static let customAppsKey = "steno.meetingDetection.customApps"
    static let defaultApps: [MeetingDetectionApp] = [
        .init(id: "us.zoom.xos", name: "Zoom"),
        .init(id: "com.microsoft.teams", name: "Microsoft Teams"),
        .init(id: "com.microsoft.teams2", name: "Microsoft Teams (new)"),
        .init(id: "com.cisco.webexmeetingsapp", name: "Cisco Webex"),
        .init(id: "com.webex.meetingmanager", name: "Cisco Webex (Meeting Manager)"),
        .init(id: "com.apple.FaceTime", name: String(localized: "FaceTime and Continuity calls")),
        .init(id: "com.hnc.Discord", name: "Discord"),
        .init(id: "com.tinyspeck.slackmacgap", name: "Slack"),
        .init(id: "com.logmein.GoToMeeting", name: "GoToMeeting"),
        .init(id: "com.bluejeansnet.BlueJeans", name: "BlueJeans"),
        .init(id: "co.pop.desktop", name: "Pop"),
        .init(id: "com.google.meetings", name: "Google Meet"),
        .init(id: "com.apple.Safari", name: String(localized: "Safari and embedded browsers")),
        .init(id: "com.google.Chrome", name: "Google Chrome"),
        .init(id: "org.chromium.Chromium", name: "Chromium"),
        .init(id: "com.microsoft.edgemac", name: "Microsoft Edge"),
        .init(id: "company.thebrowser.Browser", name: "Arc"),
        .init(id: "com.brave.Browser", name: "Brave"),
        .init(id: "org.mozilla.firefox", name: "Firefox"),
    ]
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var apps: [MeetingDetectionApp] {
        let custom = defaults.data(forKey: Self.customAppsKey)
            .flatMap { try? JSONDecoder().decode([MeetingDetectionApp].self, from: $0) } ?? []
        return Self.defaultApps + custom.filter { app in
            !Self.defaultApps.contains { $0.id.lowercased() == app.id.lowercased() }
        }
    }

    var selectedIDs: Set<String> {
        guard defaults.object(forKey: Self.selectionKey) != nil else {
            return Set(Self.defaultApps.map { $0.id.lowercased() })
        }
        return Set((defaults.stringArray(forKey: Self.selectionKey) ?? []).map { $0.lowercased() })
    }

    func isSelected(_ app: MeetingDetectionApp) -> Bool {
        selectedIDs.contains(app.id.lowercased())
    }

    func setSelected(_ app: MeetingDetectionApp, _ selected: Bool) {
        var ids = selectedIDs
        if selected { ids.insert(app.id.lowercased()) }
        else { ids.remove(app.id.lowercased()) }
        defaults.set(ids.sorted(), forKey: Self.selectionKey)
    }

    func add(_ app: MeetingDetectionApp) {
        guard !app.id.isEmpty else { return }
        if !apps.contains(where: { $0.id.lowercased() == app.id.lowercased() }) {
            let custom = apps.filter { !Self.defaultApps.contains($0) } + [app]
            guard let data = try? JSONEncoder().encode(custom) else { return }
            defaults.set(data, forKey: Self.customAppsKey)
        }
        setSelected(app, true)
    }

    func allows(_ bundleIdentifier: String?) -> Bool {
        guard let identifier = bundleIdentifier?.lowercased(), !identifier.isEmpty else { return false }
        // Shared system helpers are disclosed as groups in the app selection.
        // An explicitly configured child app takes precedence over its family,
        // including when that child has been deselected.
        let matches = apps.flatMap { app -> [(appID: String, prefix: String)] in
            let id = app.id.lowercased()
            let prefixes: [String]
            switch id {
            case "com.apple.safari": prefixes = [id, "com.apple.webkit"]
            case "com.apple.facetime": prefixes = [id, "com.apple.avconferenced"]
            default: prefixes = [id]
            }
            return prefixes.filter { identifier == $0 || identifier.hasPrefix($0 + ".") }
                .map { (appID: id, prefix: $0) }
        }
        let mostSpecific = matches.max { lhs, rhs in
            if lhs.prefix.count != rhs.prefix.count { return lhs.prefix.count < rhs.prefix.count }
            return lhs.prefix != lhs.appID && rhs.prefix == rhs.appID
        }
        guard let match = mostSpecific else { return false }
        return selectedIDs.contains(match.appID)
    }
}
