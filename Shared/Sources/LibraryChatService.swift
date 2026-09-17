import Foundation
import Observation
import StenoIntelligence

/// Runs library chat turns against the selected text model.
///
/// Transport guarantees ported from `LiveQueryService`:
/// - exactly one turn in flight; a new message or an explicit cancel owns
///   and cancels the previous run,
/// - the prompt comes from `LibraryChatContextBuilder` (newest-first,
///   capped cross-meeting corpus),
/// - errors surface as fixed, sanitized messages; source texts, questions
///   and answers are never logged anywhere.
///
/// A monotonically increasing generation guards every phase write so a run
/// displaced by a newer message cannot clobber the newer run's state.
@MainActor
@Observable
final class LibraryChatService {
    enum Phase: Equatable {
        case idle
        case asking
        /// The answer accumulated so far; each chunk is appended verbatim.
        case answering(String)
        case failed(String)
    }

    private(set) var phase: Phase = .idle

    /// Called once per finished run with the complete answer, or `nil` when
    /// the run failed or was cancelled. Lets the owner commit the turn into
    /// the persisted session.
    var onFinish: (@MainActor (String?) -> Void)?

    private var task: Task<Void, Never>?
    private var generation = 0

    private let builder = LibraryChatContextBuilder()
    private let makeAnswerer: @MainActor () throws -> any LiveQueryAnswering

    init(makeAnswerer: @escaping @MainActor () throws -> any LiveQueryAnswering) {
        self.makeAnswerer = makeAnswerer
    }

    /// True while a message is being answered or streamed.
    var isActive: Bool { task != nil }

    var canSend: Bool { !isActive }

    /// Starts a new turn. Any running turn is cancelled first: single
    /// in-flight by construction.
    func ask(message: String, sources: [LibraryChatMeetingSource]) {
        cancel()

        let prompt: LiveQueryPrompt
        do {
            prompt = try builder.assemble(message: message, sources: sources)
        } catch let error as LibraryChatPromptError {
            switch error {
            case .messageRequired:
                phase = .failed(String(localized: "Type a question first."))
            case .messageTooLong(let limit):
                phase = .failed(String(localized: "The message exceeds the maximum length of \(limit) characters."))
            case .emptyCorpus:
                phase = .failed(String(localized: "There are no meeting reports or notes yet to ask about."))
            }
            onFinish?(nil)
            return
        } catch {
            phase = .failed(String(localized: "The message could not be prepared."))
            onFinish?(nil)
            return
        }
        let answerer: any LiveQueryAnswering
        do {
            answerer = try makeAnswerer()
        } catch {
            phase = .failed(fixedMessage(for: error))
            onFinish?(nil)
            return
        }

        generation += 1
        let currentGeneration = generation
        phase = .asking
        task = Task { [weak self] in
            await self?.run(
                answerer: answerer,
                prompt: prompt,
                generation: currentGeneration
            )
        }
    }

    /// Owner-bound cancellation: closing the window cancels the in-flight
    /// request without leaving an error behind.
    func cancel() {
        let wasActive = task != nil
        task?.cancel()
        task = nil
        if wasActive {
            generation += 1
            phase = .idle
            onFinish?(nil)
        }
    }

    private func setPhase(_ newValue: Phase, generation runGeneration: Int) {
        guard runGeneration == generation else { return }
        phase = newValue
    }

    private func finishRun(generation runGeneration: Int) {
        guard runGeneration == generation else { return }
        task = nil
    }

    private func run(
        answerer: any LiveQueryAnswering,
        prompt: LiveQueryPrompt,
        generation runGeneration: Int
    ) async {
        var answer = ""
        setPhase(.answering(answer), generation: runGeneration)
        let stream = answerer.stream(
            systemInstructions: prompt.systemInstructions,
            userPrompt: prompt.userPrompt
        )
        do {
            for try await chunk in stream {
                try Task.checkCancellation()
                answer += chunk
                // Documented cap (`LibraryChatLimits.maximumAnswerBytes`):
                // refuse instead of surfacing an unbounded answer.
                guard answer.utf8.count <= LibraryChatLimits.maximumAnswerBytes else {
                    throw LiveQueryTransportError.responseTooLarge
                }
                setPhase(.answering(answer), generation: runGeneration)
            }
            guard runGeneration == generation else { return }
            finishRun(generation: runGeneration)
            if answer.isEmpty {
                setPhase(
                    .failed(fixedMessage(for: LiveQueryTransportError.invalidResponse)),
                    generation: runGeneration
                )
                onFinish?(nil)
            } else {
                setPhase(.answering(answer), generation: runGeneration)
                onFinish?(answer)
            }
        } catch is CancellationError {
            guard runGeneration == generation else { return }
            finishRun(generation: runGeneration)
            setPhase(.idle, generation: runGeneration)
            onFinish?(nil)
        } catch {
            guard runGeneration == generation else { return }
            finishRun(generation: runGeneration)
            setPhase(.failed(fixedMessage(for: error)), generation: runGeneration)
            onFinish?(nil)
        }
    }

    /// Maps every failure to a fixed sentence. Deliberately loses error
    /// detail: provider messages can echo request content, and source,
    /// question or answer text must never reach the UI log.
    private func fixedMessage(for error: Error) -> String {
        switch error as? LiveQueryTransportError {
        case .some(.unsupportedDialect(let dialect)):
            String(localized: "Live queries do not support the \(dialect.rawValue) endpoint dialect.")
        case .some(.apiKeyRequired):
            String(localized: "This text-model endpoint requires an API key.")
        case .some(.redirectBlocked):
            String(localized: "The text-model endpoint tried to redirect the request. Steno blocks redirects to protect your data.")
        case .some(.requestFailed(let status)):
            String(localized: "The text-model endpoint responded with HTTP \(status).")
        case .some(.invalidResponse):
            String(localized: "The text-model endpoint did not return a usable answer.")
        case .some(.responseTooLarge):
            String(localized: "The answer exceeded the live-query size limit.")
        case .none:
            String(localized: "The model could not answer right now.")
        }
    }
}
