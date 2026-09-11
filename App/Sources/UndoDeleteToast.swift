import StenoDomain
import SwiftUI

/// One recoverable item captured while its meeting folder moves to Trash.
struct UndoDeleteToastItem: Equatable {
    let meetingID: MeetingID
    let title: String
    let trashedURL: URL?
}

/// One pending undo affordance for the latest trash operation. A window may
/// contain one meeting or a whole confirmed batch. Finder trash URLs are the
/// restore handles, so every successful move is captured at delete time.
struct UndoDeleteToastWindow: Equatable {
    let id = UUID()
    let items: [UndoDeleteToastItem]
    let expiresAt: Date

    var title: String {
        items.count == 1
            ? items[0].title
            : String(localized: "\(items.count) meetings")
    }

    func isActive(now: Date) -> Bool {
        now < expiresAt
    }
}

/// Pure timing policy of the undo toast. A new operation replaces any pending
/// window and restarts its timer. Every item in one confirmed batch remains
/// part of the same undo operation.
enum UndoDeleteToastPolicy {
    static let window: TimeInterval = 12

    static func begin(
        previous: UndoDeleteToastWindow?,
        meetingID: MeetingID,
        title: String,
        trashedURL: URL?,
        now: Date
    ) -> UndoDeleteToastWindow {
        UndoDeleteToastWindow(
            items: [UndoDeleteToastItem(
                meetingID: meetingID,
                title: title,
                trashedURL: trashedURL
            )],
            expiresAt: now.addingTimeInterval(window)
        )
    }

    static func begin(
        previous: UndoDeleteToastWindow?,
        items: [UndoDeleteToastItem],
        now: Date
    ) -> UndoDeleteToastWindow? {
        guard !items.isEmpty else { return nil }
        return UndoDeleteToastWindow(
            items: items,
            expiresAt: now.addingTimeInterval(window)
        )
    }

    /// An elapsed window resolves to nil; an active one passes through
    /// unchanged so re-checking never shortens a running window.
    static func resolved(
        _ window: UndoDeleteToastWindow?,
        now: Date
    ) -> UndoDeleteToastWindow? {
        guard let window else { return nil }
        return window.isActive(now: now) ? window : nil
    }
}

/// Bottom-leading transient toast: "Moved to Trash - Undo". Expiry runs as
/// a task keyed on the window, so replacing the window cancels the old
/// timer and schedules exactly one new one.
struct UndoDeleteToast: View {
    let window: UndoDeleteToastWindow
    let onUndo: () -> Void
    let onExpire: () -> Void

    var body: some View {
        HStack(spacing: Steno.Space.s) {
            Image(systemName: "trash")
                .foregroundStyle(.secondary)
            Text("Moved to Trash")
                .font(.callout)
                .lineLimit(1)
            if !window.title.isEmpty {
                Text(window.title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Button("Undo") { onUndo() }
                .controlSize(.small)
                .padding(.leading, Steno.Space.s)
        }
        .padding(Steno.Space.m)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.regularMaterial)
                .shadow(radius: 8)
        )
        .task(id: window.expiresAt) {
            AccessibilityNotification.Announcement(
                String(localized: "Moved to Trash. Undo is available in the Edit menu.")
            ).post()

            let remaining = window.expiresAt.timeIntervalSinceNow
            guard remaining > 0 else {
                onExpire()
                return
            }
            try? await Task.sleep(for: .seconds(remaining + 0.05))
            guard !Task.isCancelled else { return }
            onExpire()
        }
    }
}
