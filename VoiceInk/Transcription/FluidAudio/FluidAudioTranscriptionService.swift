import FluidAudio
import Foundation
import os.log

class FluidAudioTranscriptionService: TranscriptionService {
    private struct CohereRuntime {
        let pipeline: CoherePipeline
        let models: CoherePipeline.LoadedModels
    }

    private var asrManager: AsrManager?
    private var unifiedAsrManager: UnifiedAsrManager?
    private var nemotronAsrManager: StreamingNemotronMultilingualAsrManager?
    private var cohereRuntime: CohereRuntime?
    private var cohereLoadingTask: Task<CohereRuntime, Error>?
    private var activeVersion: AsrModelVersion?
    private var activeNemotronModelName: String?
    private var cachedModels: AsrModels?
    private var loadingTask: (version: AsrModelVersion, task: Task<AsrModels, Error>)?
    private let audioConverter = AudioConverter()
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "FluidAudioTranscriptionService")

    private func version(for model: any TranscriptionModel) -> AsrModelVersion {
        FluidAudioModelManager.asrVersion(for: model.name)
    }

    static func languageHint(from selectedLanguage: String?, model: any TranscriptionModel) -> Language? {
        guard model.provider == .fluidAudio else {
            return nil
        }
        return FluidAudioModelManager.languageHint(from: selectedLanguage, for: model.name)
    }

    private func cleanupLoadedManagers(preservingCohereRuntime: Bool = false) async {
        await unifiedAsrManager?.cleanup()
        await nemotronAsrManager?.cleanup()
        await asrManager?.cleanup()

        if !preservingCohereRuntime {
            cohereLoadingTask?.cancel()
            cohereLoadingTask = nil
            cohereRuntime = nil
        }
        unifiedAsrManager = nil
        nemotronAsrManager = nil
        asrManager = nil
        activeVersion = nil
        activeNemotronModelName = nil
    }

    private func ensureModelsLoaded(for version: AsrModelVersion) async throws {
        if asrManager != nil, activeVersion == version {
            return
        }

        // Clean up existing manager but preserve cachedModels for reuse
        await cleanupLoadedManagers()

        let models = try await getOrLoadModels(for: version)

        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.asrManager = manager
        self.activeVersion = version
    }

    private func ensureUnifiedModelsLoaded() async throws {
        if unifiedAsrManager != nil {
            return
        }

        await cleanupLoadedManagers()

        let manager = UnifiedAsrManager(encoderPrecision: FluidAudioModelManager.parakeetUnifiedPrecision)
        try await manager.loadModels(from: FluidAudioModelManager.parakeetUnifiedCacheDirectory())
        self.unifiedAsrManager = manager
    }

    private func ensureNemotronModelsLoaded(named modelName: String) async throws {
        if nemotronAsrManager != nil, activeNemotronModelName == modelName {
            return
        }

        await cleanupLoadedManagers()

        let manager = StreamingNemotronMultilingualAsrManager()
        try await manager.loadModels(from: FluidAudioModelManager.nemotronCacheDirectory(for: modelName))
        self.nemotronAsrManager = manager
        self.activeNemotronModelName = modelName
    }

    private func ensureCohereRuntimeLoaded() async throws -> CohereRuntime {
        if let cohereRuntime {
            logger.debug("Reusing loaded Cohere runtime")
            return cohereRuntime
        }

        if let cohereLoadingTask {
            logger.debug("Awaiting existing Cohere model load")
            return try await cohereLoadingTask.value
        }

        await cleanupLoadedManagers()

        // Another caller may have completed loading while cleanup suspended.
        if let cohereRuntime {
            return cohereRuntime
        }
        if let cohereLoadingTask {
            return try await cohereLoadingTask.value
        }

        let directory = FluidAudioModelManager.cohereTranscribeCacheDirectory()
        let loadStart = ContinuousClock.now
        let task = Task {
            let models = try await CoherePipeline.loadModels(
                encoderDir: directory,
                decoderDir: directory,
                vocabDir: directory
            )
            return CohereRuntime(pipeline: CoherePipeline(), models: models)
        }
        cohereLoadingTask = task

        do {
            let runtime = try await task.value
            cohereRuntime = runtime
            cohereLoadingTask = nil
            logger.notice(
                "Cohere models loaded in \(loadStart.duration(to: .now).formatted(.units(allowed: [.seconds], width: .narrow)), privacy: .public)"
            )
            return runtime
        } catch {
            cohereLoadingTask = nil
            throw error
        }
    }

    // Returns cached models or loads from disk; deduplicates concurrent loads
    func getOrLoadModels(for version: AsrModelVersion) async throws -> AsrModels {
        if let cached = cachedModels, cached.version == version {
            return cached
        }

        // Deduplicate concurrent loads for the same version
        if let (existingVersion, existingTask) = loadingTask, existingVersion == version {
            return try await existingTask.value
        }

        let task = Task {
            let cacheDirectory = AsrModels.defaultCacheDirectory(for: version)
            guard AsrModels.modelsExist(at: cacheDirectory, version: version) else {
                throw AsrModelsError.loadingFailed(
                    "Parakeet model files are incomplete. Download the model from AI Models."
                )
            }
            return try await AsrModels.load(
                from: cacheDirectory,
                configuration: nil,
                version: version,
                encoderPrecision: .int8
            )
        }
        loadingTask = (version, task)

        do {
            let models = try await task.value
            self.cachedModels = models
            // Only clear if we're still the current loading task
            if loadingTask?.version == version {
                self.loadingTask = nil
            }
            return models
        } catch {
            // Only clear if we're still the current loading task
            if loadingTask?.version == version {
                self.loadingTask = nil
            }
            throw error
        }
    }

    func loadModel(for model: FluidAudioModel) async throws {
        if FluidAudioModelManager.isCohereTranscribeModel(named: model.name) {
            _ = try await ensureCohereRuntimeLoaded()
            return
        }

        if FluidAudioModelManager.isNemotronModel(named: model.name) {
            // Realtime Nemotron uses a dedicated streaming manager; batch loads lazily in transcribe().
            return
        }

        if FluidAudioModelManager.isParakeetUnifiedModel(named: model.name) {
            try await ensureUnifiedModelsLoaded()
            return
        }

        try await ensureModelsLoaded(for: version(for: model))
    }

    func transcribe(audioURL: URL, model: any TranscriptionModel, context: TranscriptionRequestContext) async throws
        -> String
    {
        if FluidAudioModelManager.isCohereTranscribeModel(named: model.name) {
            let requestStart = ContinuousClock.now
            let runtime = try await ensureCohereRuntimeLoaded()
            let modelReadyDuration = requestStart.duration(to: .now)

            let compatibleLanguage = TranscriptionLanguageSupport.validLanguageOrFallback(
                context.language,
                for: model
            )
            let language = FluidAudioModelManager.cohereTranscribeLanguage(from: compatibleLanguage)
            let speechAudio = try loadAudioSamples(from: audioURL)
            let result = try await runtime.pipeline.transcribeLong(
                audio: speechAudio,
                models: runtime.models,
                language: language
            )
            logger.notice(
                "Cohere transcription timings — model ready: \(modelReadyDuration.formatted(.units(allowed: [.seconds], width: .narrow)), privacy: .public), encoder: \(result.encoderSeconds, format: .fixed(precision: 3), privacy: .public)s, decoder: \(result.decoderSeconds, format: .fixed(precision: 3), privacy: .public)s, pipeline: \(result.totalSeconds, format: .fixed(precision: 3), privacy: .public)s"
            )
            return TextNormalizer.shared.normalizeSentence(result.text)
        }

        if FluidAudioModelManager.isParakeetUnifiedModel(named: model.name) {
            try await ensureUnifiedModelsLoaded()
            guard let unifiedAsrManager else {
                throw ASRError.notInitialized
            }

            let speechAudio = try loadAudioSamples(from: audioURL)
            let text = try await unifiedAsrManager.transcribe(speechAudio)
            return TextNormalizer.shared.normalizeSentence(text)
        }

        if FluidAudioModelManager.isNemotronModel(named: model.name) {
            try await ensureNemotronModelsLoaded(named: model.name)
            guard let nemotronAsrManager else {
                throw ASRError.notInitialized
            }

            let compatibleLanguage = TranscriptionLanguageSupport.validLanguageOrFallback(
                context.language,
                for: model
            )
            let languageHint = FluidAudioModelManager.nemotronLanguageHint(from: compatibleLanguage)
            await nemotronAsrManager.setLanguage(languageHint)
            await nemotronAsrManager.reset()

            var speechAudio = try loadAudioSamples(from: audioURL)
            let trailingSilenceSamples = 16_000
            let maxSingleChunkSamples = 240_000
            if speechAudio.count + trailingSilenceSamples <= maxSingleChunkSamples {
                speechAudio += [Float](repeating: 0, count: trailingSilenceSamples)
            }

            _ = try await nemotronAsrManager.process(samples: speechAudio)
            let text = try await nemotronAsrManager.finish()
            return TextNormalizer.shared.normalizeSentence(text)
        }

        let targetVersion = version(for: model)
        try await ensureModelsLoaded(for: targetVersion)

        guard let asrManager = asrManager else {
            throw ASRError.notInitialized
        }

        let languageHint = Self.languageHint(
            from: context.language,
            model: model
        )
        var decoderState = TdtDecoderState.make(decoderLayers: await asrManager.decoderLayerCount)
        let result = try await asrManager.transcribe(
            audioURL,
            decoderState: &decoderState,
            language: languageHint
        )

        return TextNormalizer.shared.normalizeSentence(result.text)
    }

    private func loadAudioSamples(from audioURL: URL) throws -> [Float] {
        try audioConverter.resampleAudioFile(audioURL)
    }

    // Release per-session managers, but retain Cohere's expensive Core ML runtime
    // so normal end-of-transcription cleanup does not prepare it again next time.
    func cleanup() async {
        await cleanupLoadedManagers(preservingCohereRuntime: true)
    }

}
