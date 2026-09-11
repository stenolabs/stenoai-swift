import Foundation
import Testing
@testable import StenoDomain

/// A meeting that is missing a track must say so itself. Deriving it from the
/// asset count would be a guess: on iOS a single track is normal.
@Suite("Meeting unrecorded tracks")
struct MeetingUnrecordedTracksTests {
    @Test("a meeting written before this field reads as complete")
    func olderMeetingsReadAsComplete() throws {
        let json = """
        {
          "schemaVersion": 1,
          "id": "01A03D4C-F03C-7FAC-8E18-C9C5D04FBFFF",
          "title": "Older",
          "createdAt": 809427647.5482,
          "status": "ready",
          "participantIDs": [],
          "additionalParticipantIDs": []
        }
        """

        let meeting = try JSONDecoder().decode(
            Meeting.self,
            from: Data(json.utf8)
        )

        #expect(meeting.unrecordedTracks.isEmpty)
        #expect(meeting.isRecordingComplete)
    }

    @Test("a missing track survives a round trip and marks the meeting")
    func missingTrackSurvivesRoundTrip() throws {
        var meeting = Meeting(
            id: MeetingID(),
            title: "Partial",
            createdAt: Date(timeIntervalSince1970: 1),
            status: .ready
        )
        meeting.unrecordedTracks = [.micTrack]

        let data = try JSONEncoder().encode(meeting)
        let decoded = try JSONDecoder().decode(Meeting.self, from: data)

        #expect(decoded.unrecordedTracks == [.micTrack])
        #expect(!decoded.isRecordingComplete)
    }
}
