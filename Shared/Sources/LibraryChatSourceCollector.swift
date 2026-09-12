import Foundation
import StenoDomain
import StenoIntelligence
import StenoLibrary
import StenoPipeline

/// Collects exactly the notes and report content used by library chat on
/// either platform. Audio and structured participant identities stay out.
enum LibraryChatSourceCollector {
    static func collect(library: Library, meetings: [Meeting], scope: LibraryChatScope, requiresCompleteSources: Bool = true) async throws -> [LibraryChatMeetingSource] {
        let notes = MeetingNotesStore(layout: library.layout)
        let reports = TemplateResultStore(layout: library.layout)
        var sources: [LibraryChatMeetingSource] = []
        for meeting in meetings {
            try Task.checkCancellation()
            guard meeting.status != .recording else { continue }
            switch scope {
            case .all: break
            case .folder(let id): guard meeting.folderID == id else { continue }
            case .meetings(let ids): guard ids.contains(meeting.id) else { continue }
            }
            let userNotes: String?
            let storedReports: [StoredTemplateResult]
            if requiresCompleteSources {
                userNotes = try await notes.notes(meeting.id)
                storedReports = try reports.listWithRepairOutcome(meetingID: meeting.id).results
            } else {
                // Preserve the macOS partial-source policy during extraction.
                userNotes = try? await notes.notes(meeting.id)
                storedReports = (try? reports.listWithRepairOutcome(meetingID: meeting.id))?.results ?? []
            }
            let latest = storedReports.max { $0.result.createdAt < $1.result.createdAt }?.result.markdown
            sources.append(LibraryChatMeetingSource(
                title: meeting.title, createdAt: meeting.createdAt,
                userNotes: userNotes, reportMarkdown: latest
            ))
        }
        return sources
    }

    static func notice(endpoint: TextModelEndpoint, sources: [LibraryChatMeetingSource], device: String) throws -> LocalizedExternalModelNotice {
        let hasReports = sources.contains { $0.reportMarkdown != nil }
        let revision = TranscriptRevision(
            meetingID: MeetingID(), origin: .liveProvisional,
            turns: hasReports ? [TranscriptTurn(
                speaker: .channel("report"), start: 0, end: 0,
                segments: [TranscriptSegment(text: "report", start: 0, end: 0, words: [])]
            )] : []
        )
        return try LocalizedExternalModelNotice.make(
            endpoint: endpoint,
            disclosure: OutboundDisclosure(transcript: revision, context: RenderContext(
                userNotes: sources.contains { $0.userNotes != nil } ? "notes" : nil,
                participants: []
            )), localDeviceDescription: device
        )
    }
}
