import Foundation
import StenoDomain
import StenoLibrary

@MainActor
extension AppModel {
    /// Updates the rebuildable index before querying. Fingerprints avoid
    /// rewriting unchanged content; snapshots prevent cross-library results.
    func searchMeetingContents(_ query: String) async throws -> [MeetingContentGroup] {
        guard let snapshot = runtimeSnapshot(), isCurrent(snapshot) else { return [] }
        let index = try MeetingSearchIndex(layout: snapshot.runtime.library.layout)
        let candidates = meetings
        for meeting in candidates {
            try Task.checkCancellation()
            guard isCurrent(snapshot) else { throw CancellationError() }
            try await index.update(meetingID: meeting.id, library: snapshot.runtime.library)
        }
        let hits = try await index.search(query, limit: 100)
        try Task.checkCancellation()
        guard isCurrent(snapshot) else { throw CancellationError() }
        let existing = Set(meetings.map(\.id))
        return hits.filter { existing.contains($0.meetingID) }
    }
}
