import StenoDomain
import StenoLibrary
import SwiftUI

struct RecentlyDeletedView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let onRestore: (MeetingID) -> Void
    @State private var entries: [LibraryTrashStore.Entry] = []
    @State private var failure: String?
    @State private var isLoading = true
    @State private var hasUnreadableEntries = false

    var body: some View {
        NavigationStack {
            List {
                if hasUnreadableEntries {
                    Label("Some deleted meetings could not be read. Their files remain stored.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                Section {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(entry.meeting.title).font(.headline)
                            Text(entry.deletedAt, style: .date).foregroundStyle(.secondary)
                            Button("Restore meeting", systemImage: "arrow.uturn.backward") {
                                Task {
                                    do {
                                        let id = try await app.restoreDeletedMeeting(entry)
                                        onRestore(id)
                                        dismiss()
                                    } catch {
                                        failure = String(localized: "The meeting could not be restored.")
                                        await reload()
                                    }
                                }
                            }
                            .disabled(app.libraryActionIsInFlight)
                        }
                        .padding(.vertical, 4)
                    }
                } footer: {
                    Text("Deleted meetings remain on this device until you restore them. Their original recordings are preserved.")
                }
            }
            .overlay {
                if isLoading { ProgressView() }
                else if entries.isEmpty && !hasUnreadableEntries {
                    ContentUnavailableView("No deleted meetings", systemImage: "trash")
                }
            }
            .navigationTitle("Recently deleted")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task(id: app.runtimeSnapshot()?.generation) { await reload() }
            .refreshable { await reload() }
            .alert("Recently deleted", isPresented: Binding(
                get: { failure != nil }, set: { if !$0 { failure = nil } }
            )) { Button("OK") { failure = nil } } message: { Text(failure ?? "") }
        }
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let listing = try await app.recentlyDeletedMeetings()
            entries = listing.entries.reversed()
            hasUnreadableEntries = listing.unreadableEntryCount > 0
        }
        catch { failure = String(localized: "Deleted meetings could not be loaded. Their files remain stored.") }
    }
}
