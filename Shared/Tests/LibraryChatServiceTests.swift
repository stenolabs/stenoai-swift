import Foundation
import StenoIntelligence
import Testing
#if os(iOS)
@testable import Steno
#else
@testable import steno_macos
#endif

@Suite("Library chat service lifecycle", .timeLimit(.minutes(1)))
@MainActor
struct LibraryChatServiceTests {
    private let sources = [LibraryChatMeetingSource(
        title: "Synthetic meeting", createdAt: Date(timeIntervalSince1970: 1),
        userNotes: "Synthetic project notes", reportMarkdown: nil
    )]

    @Test("a failed stream releases the active turn and allows a successful retry")
    func retriesAfterFailure() async throws {
        let failed = ControlledChatAnswerer()
        let successful = ControlledChatAnswerer()
        var answerers = [failed, successful]
        let service = LibraryChatService { answerers.removeFirst() }
        let finishes = AsyncStream<String?>.makeStream()
        var completion = finishes.stream.makeAsyncIterator()
        service.onFinish = { finishes.continuation.yield($0) }
        service.ask(message: "Synthetic question", sources: sources)
        var started = failed.started.makeAsyncIterator()
        _ = await started.next()
        failed.answer.finish(throwing: LiveQueryTransportError.invalidResponse)
        _ = await completion.next()
        #expect(!service.isActive)
        #expect(service.canSend)
        guard case .failed = service.phase else {
            Issue.record("The failed stream did not publish its failure")
            return
        }
        service.ask(message: "Synthetic retry", sources: sources)
        successful.answer.yield("Synthetic answer")
        successful.answer.finish()
        #expect(await completion.next() == .some("Synthetic answer"))
        #expect(!service.isActive)
        #expect(service.phase == .answering("Synthetic answer"))
    }

    @Test("a displaced stream cannot finish or clear the newer turn")
    func ignoresDisplacedCompletion() async throws {
        let old = ControlledChatAnswerer()
        let current = ControlledChatAnswerer()
        var answerers = [old, current]
        let service = LibraryChatService { answerers.removeFirst() }
        var finishedAnswers: [String?] = []
        let finishes = AsyncStream<Int>.makeStream()
        var completion = finishes.stream.makeAsyncIterator()
        service.onFinish = {
            finishedAnswers.append($0)
            finishes.continuation.yield(finishedAnswers.count)
        }
        service.ask(message: "Old synthetic question", sources: sources)
        var oldStarted = old.started.makeAsyncIterator()
        _ = await oldStarted.next()
        service.ask(message: "Current synthetic question", sources: sources)
        #expect(await completion.next() == 1)
        #expect(finishedAnswers == [nil])
        var currentStarted = current.started.makeAsyncIterator()
        _ = await currentStarted.next()
        old.answer.yield("Stale answer")
        old.answer.finish(throwing: LiveQueryTransportError.invalidResponse)
        #expect(service.isActive)
        current.answer.yield("Current answer")
        current.answer.finish()
        #expect(await completion.next() == 2)
        #expect(finishedAnswers == [nil, "Current answer"])
        #expect(service.phase == .answering("Current answer"))
        #expect(!service.isActive)
    }
}

private struct ControlledChatAnswerer: LiveQueryAnswering {
    let answer: AsyncThrowingStream<String, any Error>.Continuation
    let started: AsyncStream<Void>
    private let streamValue: AsyncThrowingStream<String, any Error>
    private let startedContinuation: AsyncStream<Void>.Continuation

    init() {
        let pair = AsyncThrowingStream<String, any Error>.makeStream()
        answer = pair.continuation
        streamValue = pair.stream
        let notification = AsyncStream<Void>.makeStream()
        started = notification.stream
        startedContinuation = notification.continuation
    }

    func stream(systemInstructions: String, userPrompt: String) -> AsyncThrowingStream<String, any Error> {
        startedContinuation.yield(())
        startedContinuation.finish()
        return streamValue
    }
}
