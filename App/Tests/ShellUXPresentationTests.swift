import Foundation
import StenoDomain
import StenoIdentity
import Testing
@testable import steno_macos

@Suite("Legacy home presentation")
struct LegacyHomePresentationTests {
    @Test("recent meetings are newest first and bounded")
    func recentMeetingsAreNewestFirstAndBounded() {
        let meetings = (0..<12).map { offset in
            Meeting(
                title: "Meeting \(offset)",
                createdAt: Date(timeIntervalSinceReferenceDate: Double(offset)),
                status: .ready
            )
        }

        let recent = LegacyHomePresentation.recentMeetings(meetings)

        #expect(recent.count == LegacyHomePresentation.recentLimit)
        #expect(recent.map(\.title) == (4..<12).reversed().map { "Meeting \($0)" })
    }

    @Test("greeting hour follows the supplied calendar")
    func greetingHourUsesCalendar() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(
            from: DateComponents(year: 2026, month: 9, day: 1, hour: 14)
        )!

        #expect(LegacyHomePresentation.greetingHour(date, calendar: calendar) == 14)
    }
}

@Suite("Command palette filtering")
struct CommandPaletteFilterTests {
    private func item(
        _ id: String,
        _ title: String,
        keywords: String = "",
        section: CommandPaletteSection = .commands
    ) -> CommandPaletteItem {
        CommandPaletteItem(
            id: id,
            title: title,
            keywords: keywords,
            section: section
        ) {}
    }

    @Test("an empty query keeps the catalog order")
    func emptyQueryKeepsOrder() {
        let items = [
            item("a", "Start Recording"),
            item("b", "New Meeting"),
            item("c", "Weekly sync", section: .meetings),
        ]
        #expect(
            CommandPaletteFilter.ranked(items: items, query: "").map(\.id)
                == items.map(\.id)
        )
        #expect(
            CommandPaletteFilter.ranked(items: items, query: "   ").map(\.id)
                == items.map(\.id)
        )
    }

    @Test("prefix beats word boundary beats scattered subsequence")
    func scoresSortMatches() {
        let ranked = CommandPaletteFilter.ranked(
            items: [
                item("scattered", "Warm Area"), // scattered subsequence only
                item("boundary", "Team Management"), // second word prefix
                item("prefix", "Mark This Moment"), // exact prefix
            ],
            query: "ma"
        )
        #expect(ranked.map(\.id) == ["prefix", "boundary", "scattered"])
    }
    @Test("non-matching items are filtered out entirely")
    func filtersNonMatches() {
        let items = [
            item("first", "Stop Recording"),
            item("second", "Start Recording"),
        ]
        // "stop recording" has no letter a, so it cannot match at all.
        let ranked = CommandPaletteFilter.ranked(items: items, query: "start")
        #expect(ranked.map(\.id) == ["second"])
    }

    @Test("equal scores keep catalog order")
    func tiesKeepCatalogOrder() {
        let items = [
            item("first", "Stop Audio"),
            item("second", "Start Audio"),
        ]
        let ranked = CommandPaletteFilter.ranked(items: items, query: "sa")
        #expect(ranked.map(\.id) == ["first", "second"])
    }

    @Test("keyword hits rank behind title hits")
    func filtersAndKeywordFallback() {
        let ranked = CommandPaletteFilter.ranked(
            items: [
                item("unrelated", "Undo Delete"),
                item("keywordOnly", "General", keywords: "open settings"),
                item("titleHit", "Open Settings"),
            ],
            query: "settings"
        )
        #expect(ranked.map(\.id) == ["titleHit", "keywordOnly"])
    }

    @Test("matching is case-insensitive and subsequence-ordered")
    func caseInsensitiveSubsequence() {
        #expect(CommandPaletteFilter.score(query: "MRK", target: "Mark This Moment") != nil)
        // The letters must appear in order, not just anywhere.
        #expect(CommandPaletteFilter.score(query: "mk", target: "km") == nil)
    }
}

@Suite("Undo-delete toast window")
struct UndoDeleteToastPolicyTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000)

    @Test("the window stays active for twelve seconds, then expires")
    func expiryWindow() {
        let window = UndoDeleteToastPolicy.begin(
            previous: nil,
            meetingID: MeetingID(rawValue: UUID()),
            title: "Weekly sync",
            trashedURL: URL(fileURLWithPath: "/tmp/meeting"),
            now: now
        )
        #expect(window.isActive(now: now.addingTimeInterval(11.9)))
        #expect(!window.isActive(now: now.addingTimeInterval(12)))
        #expect(UndoDeleteToastPolicy.resolved(window, now: now) == window)
        #expect(
            UndoDeleteToastPolicy.resolved(
                window,
                now: now.addingTimeInterval(12)
            ) == nil
        )
    }

    @Test("a second delete replaces the pending toast and restarts the timer")
    func replacementRestartsTimer() {
        let first = UndoDeleteToastPolicy.begin(
            previous: nil,
            meetingID: MeetingID(rawValue: UUID()),
            title: "First",
            trashedURL: nil,
            now: now
        )
        let secondNow = now.addingTimeInterval(5)
        let second = UndoDeleteToastPolicy.begin(
            previous: first,
            meetingID: MeetingID(rawValue: UUID()),
            title: "Second",
            trashedURL: nil,
            now: secondNow
        )
        // A fresh twelve second window started at secondNow: active just
        // before it ends, gone just after.
        #expect(second.isActive(now: secondNow.addingTimeInterval(6)))
        #expect(!second.isActive(now: secondNow.addingTimeInterval(13)))
        #expect(second.title == "Second")
    }

    @Test("one batch window keeps every meeting available for undo")
    func batchWindow() throws {
        let first = UndoDeleteToastItem(
            meetingID: MeetingID(rawValue: UUID()),
            title: "First",
            trashedURL: URL(fileURLWithPath: "/tmp/first")
        )
        let second = UndoDeleteToastItem(
            meetingID: MeetingID(rawValue: UUID()),
            title: "Second",
            trashedURL: URL(fileURLWithPath: "/tmp/second")
        )

        let window = try #require(UndoDeleteToastPolicy.begin(
            previous: nil,
            items: [first, second],
            now: now
        ))

        #expect(window.items == [first, second])
        #expect(window.title == String(
            localized: "\(window.items.count) meetings"
        ))
        #expect(window.isActive(now: now.addingTimeInterval(11.9)))
    }
}

@Suite("Home status header projection")
struct HomeStatusHeaderStateTests {
    private let now = Date(timeIntervalSinceReferenceDate: 900_000)

    @Test("recording outruns processing outruns ready")
    func modePrecedence() {
        let recording = HomeStatusHeaderState.make(
            isRecording: true,
            recordingStartedAt: now.addingTimeInterval(-65),
            activeJobCount: 3,
            meetingsNeedingSpeakerReview: 2,
            now: now
        )
        #expect(recording.mode == .recording(elapsedSeconds: 65))

        let processing = HomeStatusHeaderState.make(
            isRecording: false,
            recordingStartedAt: nil,
            activeJobCount: 2,
            meetingsNeedingSpeakerReview: 1,
            now: now
        )
        #expect(processing.mode == .processing(jobCount: 2))

        let ready = HomeStatusHeaderState.make(
            isRecording: false,
            recordingStartedAt: nil,
            activeJobCount: 0,
            meetingsNeedingSpeakerReview: 0,
            now: now
        )
        #expect(ready.mode == .readyToRecord)
    }

    @Test("elapsed time clamps a stale start date to zero")
    func elapsedClamping() {
        let state = HomeStatusHeaderState.make(
            isRecording: true,
            recordingStartedAt: now.addingTimeInterval(30),
            activeJobCount: 0,
            meetingsNeedingSpeakerReview: 0,
            now: now
        )
        #expect(state.mode == .recording(elapsedSeconds: 0))
    }

    @Test("the clock renders as mm:ss")
    func clockText() {
        #expect(HomeStatusHeaderState.clockText(seconds: 0) == "00:00")
        #expect(HomeStatusHeaderState.clockText(seconds: 65) == "01:05")
        #expect(HomeStatusHeaderState.clockText(seconds: 600) == "10:00")
    }

    @Test("only meetings with an unconfirmed nameable speaker need review")
    func reviewPolicyIgnoresSelfAndMultipleClusters() {
        var cluster = IdentityCluster(
            meetingID: MeetingID(rawValue: UUID()),
            runID: RunID(rawValue: UUID()),
            channel: "microphone",
            clusterID: "1",
            recordingType: .inPerson,
            embedding: [],
            speechDurationSeconds: 0,
            segmentCount: 0
        )
        #expect(HomeStatusReviewPolicy.needsSpeakerReview([cluster]))

        cluster.reviewState = .confirmed(PersonID(rawValue: UUID()))
        #expect(!HomeStatusReviewPolicy.needsSpeakerReview([cluster]))

        cluster.reviewState = .unreviewed
        cluster.containsMultipleSpeakers = true
        #expect(!HomeStatusReviewPolicy.needsSpeakerReview([cluster]))

        cluster.containsMultipleSpeakers = false
        cluster.reviewState = .generic
        #expect(!HomeStatusReviewPolicy.needsSpeakerReview([cluster]))
    }
}
