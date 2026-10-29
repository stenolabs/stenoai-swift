@preconcurrency import AVFAudio
import FluidAudio
import Foundation
import StenoDomain

struct ParakeetRecognitionResult: Sendable {
    let text: String
    let duration: TimeInterval
    let tokenTimings: [TokenTiming]?
}

protocol ParakeetTranscriptionEngine: Sendable {
    func transcribe(_ url: URL, locale: Locale) async throws -> ParakeetRecognitionResult
}

struct FluidAudioParakeetEngine: ParakeetTranscriptionEngine {
    let modelDirectory: URL

    func transcribe(_ url: URL, locale: Locale) async throws -> ParakeetRecognitionResult {
        let models = try await LocalParakeetModelLoader.load(from: modelDirectory)
        let manager = AsrManager(config: ASRConfig(
            melChunkContext: false,
            dualDecodeArbitration: false
        ))
        try await manager.loadModels(models)
        var state = try TdtDecoderState(decoderLayers: await manager.decoderLayerCount)
        let code = locale.language.languageCode?.identifier.lowercased()
        let language = code.flatMap(Language.init(rawValue:))
        let result = try await manager.transcribe(
            url,
            decoderState: &state,
            language: language
        )
        return ParakeetRecognitionResult(
            text: result.text,
            duration: result.duration,
            tokenTimings: result.tokenTimings
        )
    }
}

public struct ParakeetTranscriptionProvider: TranscriptionProvider {
    public let channel: TranscriptionChannel
    private let engine: any ParakeetTranscriptionEngine
    private let modelDirectory: URL?
    private let experimentalFeatures: TranscriptionExperimentalFeatures

    public init(
        channel: TranscriptionChannel,
        modelDirectory: URL,
        experimentalFeatures: TranscriptionExperimentalFeatures = .production
    ) {
        self.channel = channel
        engine = FluidAudioParakeetEngine(modelDirectory: modelDirectory)
        self.modelDirectory = modelDirectory
        self.experimentalFeatures = experimentalFeatures
    }

    init(channel: TranscriptionChannel, engine: any ParakeetTranscriptionEngine) {
        self.channel = channel
        self.engine = engine
        modelDirectory = nil
        experimentalFeatures = .production
    }

    /// Directory the launch-time warmup verifies and loads from; `nil` for
    /// the engine-injected test double, which keeps no files on disk.
    var warmupModelDirectory: URL? { modelDirectory }

    public var descriptor: EngineDescriptor {
        EngineDescriptor(
            name: "FluidAudio Parakeet TDT",
            version: "0.17.4",
            modelVersion: "parakeet-tdt-0.6b-v3-coreml"
        )
    }

    public func liveSession(
        format: AudioFormat,
        locale: Locale
    ) async throws -> any LiveTranscriptionSession {
        guard experimentalFeatures.parakeetLiveEnabled, let modelDirectory else {
            throw TranscriptionError.liveModeNotEnabled
        }
        let engine = try await FluidAudioSlidingEngine(
            modelDirectory: modelDirectory,
            channel: channel
        )
        return await ParakeetLiveTranscriptionSession(
            engine: engine,
            channel: channel,
            locale: locale
        )
    }

    public func transcribeFile(
        _ url: URL,
        locale: Locale
    ) async throws -> TranscriptOutput {
        let result = try await engine.transcribe(url, locale: locale)
        let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return TranscriptOutput(localeIdentifier: locale.identifier, blocks: [])
        }
        guard let tokenTimings = result.tokenTimings, !tokenTimings.isEmpty else {
            throw TranscriptionError.missingWordTimings
        }
        let rawWords = buildWordTimings(from: tokenTimings)
        guard !rawWords.isEmpty else { throw TranscriptionError.missingWordTimings }

        let reportedDuration = result.duration.isFinite ? max(0, result.duration) : 0
        let duration = reportedDuration > 0
            ? reportedDuration
            : max(0, rawWords.map(\.endTime).max() ?? 0)
        var previousEnd: TimeInterval = 0
        let words = rawWords.map { timing -> TranscriptionWord in
            let start = min(duration, max(previousEnd, timing.startTime))
            let end = min(duration, max(start, timing.endTime))
            previousEnd = end
            return TranscriptionWord(text: timing.word, start: start, end: end)
        }
        let start = words.first?.start ?? 0
        let end = words.last?.end ?? start
        return TranscriptOutput(
            localeIdentifier: locale.identifier,
            blocks: [TranscriptionBlock(
                channel: channel,
                text: trimmed,
                start: start,
                end: end,
                words: words
            )]
        )
    }
}
