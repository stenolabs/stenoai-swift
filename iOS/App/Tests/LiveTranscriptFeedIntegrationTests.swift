import Foundation
import StenoTranscription
import StenoiOSAudio
import Testing
@testable import Steno

@Suite("iOS live transcript feed")
struct IOSLiveTranscriptFeedIntegrationTests {
    @Test @MainActor
    func laterSpeechStaysBelowEarlierSpeechAcrossFinalization() {
        let model = RecordingModel(session: AudioSessionController())
        let beforeLock = block("before locking", start: 0, end: 5)
        let afterUnlock = block("after unlocking", start: 40, end: 42)
        let current = block("continuing", start: 42, end: 43)

        model.applyLiveEvent(.volatile(output([beforeLock, afterUnlock, current])))

        #expect(model.liveTranscriptRows.map(\.block.text) == [
            "before locking", "after unlocking", "continuing",
        ])
        #expect(model.liveTranscriptRows.map(\.kind) == [.final, .final, .volatile])
        let stableIDs = model.liveTranscriptRows.filter { $0.kind == .final }.map(\.id)

        model.applyLiveEvent(.final(output([beforeLock, afterUnlock, current])))

        #expect(model.liveTranscriptRows.map(\.block.text) == [
            "before locking", "after unlocking", "continuing",
        ])
        #expect(Array(model.liveTranscriptRows.prefix(2).map(\.id)) == stableIDs)
        #expect(model.liveTranscriptRows.allSatisfy { $0.kind == .final })
    }

    @Test @MainActor
    func cumulativeFinalsArePublishedOnceInSpokenOrder() {
        let model = RecordingModel(session: AudioSessionController())
        let first = block("first", start: 0, end: 1)
        let second = block("second", start: 1, end: 2)

        model.applyLiveEvent(.final(output([first])))
        model.applyLiveEvent(.final(output([first, second])))

        #expect(model.liveTranscriptRows.map(\.block.text) == ["first", "second"])
    }

    @Test @MainActor
    func onlyTheCurrentVolatileBlockIsPublished() {
        let model = RecordingModel(session: AudioSessionController())
        let final = block("final", start: 0, end: 1)
        let current = block("current", start: 1, end: 2)

        model.applyLiveEvent(.volatile(output([final, current])))

        #expect(model.liveTranscriptRows.map(\.block.text) == ["final", "current"])
        #expect(model.liveTranscriptRows.map(\.kind) == [.final, .volatile])
    }

    @Test @MainActor
    func aFinalSnapshotRemovesTheVolatileRow() {
        let model = RecordingModel(session: AudioSessionController())
        let final = block("final", start: 0, end: 1)
        let current = block("current", start: 1, end: 2)

        model.applyLiveEvent(.volatile(output([final, current])))
        model.applyLiveEvent(.final(output([final, current])))

        #expect(model.liveTranscriptRows.map(\.block.text) == ["final", "current"])
        #expect(model.liveTranscriptRows.allSatisfy { $0.kind == .final })
    }

    private func block(
        _ text: String,
        start: TimeInterval,
        end: TimeInterval
    ) -> TranscriptionBlock {
        TranscriptionBlock(
            channel: .microphone,
            text: text,
            start: start,
            end: end,
            words: []
        )
    }

    private func output(_ blocks: [TranscriptionBlock]) -> TranscriptOutput {
        TranscriptOutput(localeIdentifier: "de-DE", blocks: blocks)
    }
}
