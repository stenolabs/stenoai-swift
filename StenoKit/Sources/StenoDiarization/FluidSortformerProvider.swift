@preconcurrency import CoreML
import FluidAudio
import Foundation
import StenoDomain

public actor FluidSortformerProvider: DiarizationProvider {
    public nonisolated let computeUnits: DiarizationComputeUnits
    public nonisolated let descriptor: EngineDescriptor

    let modelCacheDirectory: URL?

    public init(
        // .all was observed to route Sortformer silently to the GPU. Forcing
        // CPU plus Neural Engine gives genuine ANE execution and is the
        // power-efficient default; bulk backfills may opt into GPU explicitly.
        computeUnits: DiarizationComputeUnits = .cpuAndNeuralEngine,
        modelCacheDirectory: URL? = nil
    ) {
        self.computeUnits = computeUnits
        self.modelCacheDirectory = modelCacheDirectory
        self.descriptor = EngineDescriptor(
            name: "FluidAudio Sortformer",
            version: "0.17.4",
            modelVersion: "duration-adaptive Sortformer + wespeaker_v2"
        )
    }

    public func diarize(
        _ url: URL,
        hints: DiarizationHints = DiarizationHints()
    ) async throws -> DiarizationOutput {
        try await diarize(url, hints: hints, progress: nil)
    }

    public func diarize(
        _ url: URL,
        hints: DiarizationHints = DiarizationHints(),
        progress: DiarizationProgressHandler? = nil
    ) async throws -> DiarizationOutput {
        // The selected Sortformer variants have four fixed output slots and no speaker-count
        // input, so the provider accepts the shared hint without pretending
        // that it can influence this model.
        _ = hints

        let emitter = DiarizationProgressEmitter(handler: progress)
        emitter.emit(.loadingAudio)

        let samples = try AVAudioSampleLoader.load(from: url)
        let choice = sortformerConfiguration(
            forDuration: Double(samples.count) / AVAudioSampleLoader.sampleRate
        )
        let config = choice.fluidConfig
        let models = try await loadModels(config: config)

        let diarizer = SortformerDiarizer(config: config)
        diarizer.initialize(models: models.sortformer)
        // processComplete is a single opaque CoreML call (the legacy 37-45 s
        // silent window): no internal fraction is available, so only time-based
        // heartbeats are emitted while it runs.
        var timeline: DiarizerTimeline?
        var inferenceFailure: (any Error)?
        await emitter.withSegmentingHeartbeats {
            do {
                timeline = try diarizer.processComplete(samples, sourceSampleRate: nil)
            } catch {
                inferenceFailure = error
            }
        }
        if let inferenceFailure {
            throw DiarizationError.inferenceFailed(inferenceFailure.localizedDescription)
        }
        guard let timeline else {
            throw DiarizationError.inferenceFailed("segmentation returned no timeline")
        }

        emitter.emit(.clustering)
        let segments = filterDiarizationSegments(
            timeline.speakers.values
                .flatMap(\.finalizedSegments)
                .map {
                    DiarizationSegment(
                        clusterID: "SPEAKER_\($0.speakerIndex)",
                        start: Double($0.startTime),
                        end: Double($0.endTime)
                    )
                }
        )
        let embeddings = models.embedding.map {
            extractSortformerEmbeddings(
                audio: samples,
                timeline: timeline,
                models: $0
            )
        } ?? [:]

        emitter.emit(.writing, fraction: 1.0)
        return DiarizationOutput(
            segments: segments,
            embeddings: embeddings,
            engine: descriptor(for: choice)
        )
    }

    private func loadModels(config: SortformerConfig) async throws -> LoadedModels {
        let baseDirectory = modelCacheDirectory
            ?? MLModelConfigurationUtils.defaultModelsDirectory()
        guard let sortformerName = ModelNames.Sortformer.bundle(for: config) else {
            throw DiarizationError.modelLoadingFailed(
                "FluidAudio has no model bundle for the selected Sortformer configuration"
            )
        }

        let sortformerURL = baseDirectory
            .appendingPathComponent(Repo.sortformer.folderName, isDirectory: true)
            .appendingPathComponent(sortformerName, isDirectory: true)
        let segmentationURL = baseDirectory
            .appendingPathComponent(Repo.diarizer.folderName, isDirectory: true)
            .appendingPathComponent(ModelNames.Diarizer.segmentationFile, isDirectory: true)
        let embeddingURL = baseDirectory
            .appendingPathComponent(Repo.diarizer.folderName, isDirectory: true)
            .appendingPathComponent(ModelNames.Diarizer.embeddingFile, isDirectory: true)
        let requiredURLs = [sortformerURL, segmentationURL, embeddingURL]
        let fileManager = FileManager.default
        // Der Provider laedt nichts mehr nach: das ist Sache des
        // DiarizationModelInstaller, vor dem Lauf und mit Zustimmung.
        let missing = requiredURLs
            .filter {
                !modelBundleIsComplete(
                    $0,
                    fileManager: fileManager,
                    installationRoot: baseDirectory
                )
            }
        guard missing.isEmpty else {
            throw DiarizationError.modelsNotInstalled(
                missing: missing.map(\.lastPathComponent)
            )
        }

        let modelConfiguration = MLModelConfigurationUtils.defaultConfiguration(
            computeUnits: computeUnits.coreMLValue
        )
        let sortformer: SortformerModels
        do {
            let start = Date()
            let model = try MLModel(
                contentsOf: sortformerURL,
                configuration: modelConfiguration
            )
            sortformer = try SortformerModels(
                config: config,
                main: model,
                compilationDuration: Date().timeIntervalSince(start)
            )
        } catch {
            // Do not delete a possibly recoverable cache and do not retry via
            // the network. Installation is an explicit caller-owned action.
            throw DiarizationError.modelLoadingFailed(error.localizedDescription)
        }

        // Embeddings are an enhancement. A corrupt or incompatible WeSpeaker
        // cache must not discard valid Sortformer segments from this run.
        let embedding = try? DiarizerModels.load(
            localSegmentationModel: segmentationURL,
            localEmbeddingModel: embeddingURL,
            configuration: modelConfiguration
        )
        return LoadedModels(sortformer: sortformer, embedding: embedding)
    }

    private func descriptor(
        for choice: SortformerConfigurationChoice
    ) -> EngineDescriptor {
        let sortformerModel = switch choice {
        case .default: "Sortformer_v2.1"
        case .highContextV2: "SortformerNvidiaHigh_v2"
        }
        return EngineDescriptor(
            name: "FluidAudio Sortformer",
            version: "0.17.4",
            modelVersion: "\(sortformerModel) + wespeaker_v2"
        )
    }
}

private struct LoadedModels {
    let sortformer: SortformerModels
    let embedding: DiarizerModels?
}

func modelBundleIsComplete(
    _ url: URL,
    fileManager: FileManager,
    installationRoot: URL? = nil
) -> Bool {
    if let installationRoot,
       diarizationModelInstallationIsIncomplete(in: installationRoot)
    {
        return false
    }
    var isDirectory: ObjCBool = false
    return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        && isDirectory.boolValue
        && fileManager.fileExists(
            atPath: url.appendingPathComponent("coremldata.bin").path
        )
}

private extension SortformerConfigurationChoice {
    var fluidConfig: SortformerConfig {
        switch self {
        case .default: .default
        case .highContextV2: .highContextV2
        }
    }
}

private extension DiarizationComputeUnits {
    var coreMLValue: MLComputeUnits {
        switch self {
        case .all: .all
        case .cpuAndGPU: .cpuAndGPU
        case .cpuOnly: .cpuOnly
        case .cpuAndNeuralEngine: .cpuAndNeuralEngine
        }
    }
}
