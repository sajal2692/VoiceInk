import AppKit
import FluidAudio
import Foundation
import os

struct FluidAudioDownloadStatus {
    let fractionCompleted: Double
    let message: String
    let isIndeterminate: Bool

    init(fractionCompleted: Double, message: String, isIndeterminate: Bool = false) {
        self.fractionCompleted = fractionCompleted
        self.message = message
        self.isIndeterminate = isIndeterminate
    }
}

@MainActor
class FluidAudioModelManager: ObservableObject {
    @Published private var downloadStatuses: [String: FluidAudioDownloadStatus] = [:]
    @Published private var modelStateRevision = 0
    private var activeDownloadIDs: [String: UUID] = [:]
    private var activeNetworkProgressIDs: [String: UUID] = [:]
    @Published private var cohereOptimizationState: CohereOptimizationState = .idle

    var onModelDeleted: ((String) -> Void)?
    var onModelsChanged: (() -> Void)?

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "FluidAudioModelManager")

    // Add new Fluid Audio models here when support is added.
    private static let modelVersionMap: [String: AsrModelVersion] = [
        "parakeet-tdt-0.6b-v2": .v2,
        "parakeet-tdt-0.6b-v3": .v3,
    ]

    private enum FluidAudioModelKind {
        case parakeet(AsrModelVersion)
        case parakeetUnified
        case nemotron(NemotronVariant)
        case cohereTranscribe
    }

    private enum CohereOptimizationState: Equatable {
        case idle
        case optimizing
        case failed
    }

    nonisolated static func asrVersion(for modelName: String) -> AsrModelVersion {
        modelVersionMap[modelName] ?? .v3
    }

    nonisolated static func isParakeetUnifiedModel(named modelName: String) -> Bool {
        modelName == "parakeet-unified-0.6b"
    }

    nonisolated static func isCohereTranscribeModel(named modelName: String) -> Bool {
        modelName == "cohere-transcribe"
    }

    nonisolated static let parakeetUnifiedPrecision: UnifiedEncoderPrecision = .int8
    nonisolated static let parakeetUnifiedStreamingConfig = UnifiedConfig(
        leftFrames: 70,
        chunkFrames: 7,
        rightFrames: 7
    )
    nonisolated private static var parakeetUnifiedStreamingVariant: String? {
        parakeetUnifiedPrecision == .fp16 ? "fp16" : nil
    }
    nonisolated private static var parakeetUnifiedOfflineVariant: String {
        parakeetUnifiedPrecision == .fp16 ? "offline-fp16" : "offline"
    }
    nonisolated private static let nemotronChunkMs = 1120

    nonisolated private static var parakeetUnifiedStreamingEncoderFile: String {
        ModelNames.ParakeetUnified.streamingEncoderFile(
            precision: parakeetUnifiedPrecision,
            contextSuffix: parakeetUnifiedStreamingConfig.contextSuffix
        )
    }

    private enum NemotronVariant {
        case latin
        case multilingual

        init?(modelName: String) {
            switch modelName {
            case "nemotron-latin-0.6b":
                self = .latin
            case "nemotron-multilingual-0.6b":
                self = .multilingual
            default:
                return nil
            }
        }

        var downloadLanguageCode: String {
            switch self {
            case .latin:
                return "en"
            case .multilingual:
                return "auto"
            }
        }
    }

    nonisolated static func isNemotronModel(named modelName: String) -> Bool {
        NemotronVariant(modelName: modelName) != nil
    }

    nonisolated static func requiresRealtime(named modelName: String) -> Bool {
        isNemotronModel(named: modelName)
    }

    nonisolated private static func modelKind(for modelName: String) -> FluidAudioModelKind {
        if isCohereTranscribeModel(named: modelName) {
            return .cohereTranscribe
        }

        if let nemotronVariant = NemotronVariant(modelName: modelName) {
            return .nemotron(nemotronVariant)
        }

        if isParakeetUnifiedModel(named: modelName) {
            return .parakeetUnified
        }

        return .parakeet(asrVersion(for: modelName))
    }

    nonisolated static func cohereTranscribeLanguage(from languageCode: String?) -> CohereAsrConfig.Language {
        let normalized = (languageCode ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .first
            .map { String($0).lowercased() }

        return normalized.flatMap(CohereAsrConfig.Language.init(rawValue:)) ?? .english
    }

    nonisolated static func nemotronLanguageHint(from languageCode: String?) -> String {
        let trimmed = languageCode?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return "auto" }

        let dashed = trimmed.replacingOccurrences(of: "_", with: "-")
        return dashed.lowercased() == "auto" ? "auto" : dashed
    }

    nonisolated static func nemotronCacheDirectory(for modelName: String) -> URL {
        nemotronCacheDirectory(for: NemotronVariant(modelName: modelName) ?? .multilingual)
    }

    nonisolated private static func nemotronCacheDirectory(for variant: NemotronVariant) -> URL {
        let languageDirectory = StreamingNemotronMultilingualAsrManager.languageDirectory(
            for: variant.downloadLanguageCode
        )
        return fluidAudioModelsRootDirectory()
            .appendingPathComponent(Repo.nemotronMultilingual.folderName, isDirectory: true)
            .appendingPathComponent(languageDirectory, isDirectory: true)
            .appendingPathComponent("\(nemotronChunkMs)ms", isDirectory: true)
    }

    nonisolated static func languageHint(from languageCode: String?, for modelName: String) -> Language? {
        guard !isCohereTranscribeModel(named: modelName),
            !isParakeetUnifiedModel(named: modelName),
            !isNemotronModel(named: modelName),
            asrVersion(for: modelName) == .v3,
            let languageCode,
            languageCode != "auto"
        else { return nil }

        return Language(rawValue: languageCode)
    }

    init() {}

    // MARK: - Query helpers

    func isFluidAudioModelDownloaded(named modelName: String) -> Bool {
        switch Self.modelKind(for: modelName) {
        case .cohereTranscribe:
            return cohereOptimizationState == .idle && Self.cohereTranscribeRequiredFilesExist()
        case .nemotron(let variant):
            return Self.nemotronRequiredFilesExist(in: Self.nemotronCacheDirectory(for: variant))
        case .parakeetUnified:
            let directory = cacheDirectory(for: modelName)
            return Self.parakeetUnifiedRequiredFiles.allSatisfy {
                FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
            }
        case .parakeet(let version):
            return AsrModels.modelsExist(at: cacheDirectory(for: version), version: version)
        }
    }

    func isFluidAudioModelDownloaded(_ model: FluidAudioModel) -> Bool {
        isFluidAudioModelDownloaded(named: model.name)
    }

    func isFluidAudioModelDownloading(_ model: FluidAudioModel) -> Bool {
        downloadStatuses[model.name] != nil
    }

    func isFluidAudioModelOptimizing(_ model: FluidAudioModel) -> Bool {
        Self.isCohereTranscribeModel(named: model.name) && cohereOptimizationState == .optimizing
    }

    func downloadStatus(for model: FluidAudioModel) -> FluidAudioDownloadStatus? {
        downloadStatuses[model.name]
    }

    // MARK: - Download

    func downloadFluidAudioModel(_ model: FluidAudioModel) async {
        if isFluidAudioModelDownloaded(model) || isFluidAudioModelDownloading(model)
            || isFluidAudioModelOptimizing(model)
        {
            return
        }

        let modelName = model.name
        let downloadID = UUID()
        if Self.isCohereTranscribeModel(named: modelName) {
            cohereOptimizationState = .idle
        }
        activeDownloadIDs[modelName] = downloadID
        activeNetworkProgressIDs[modelName] = downloadID
        downloadStatuses[modelName] = FluidAudioDownloadStatus(
            fractionCompleted: 0.0,
            message: "Preparing FluidAudio download..."
        )
        defer {
            clearDownloadStatus(for: modelName, downloadID: downloadID)
            onModelsChanged?()
        }

        let progressHandler: ProgressHandler = { [weak self] progress in
            Task { @MainActor [weak self] in
                self?.updateDownloadProgress(progress, for: modelName, downloadID: downloadID)
            }
        }

        do {
            switch Self.modelKind(for: modelName) {
            case .cohereTranscribe:
                try await installCohereTranscribe(
                    modelName: modelName,
                    downloadID: downloadID,
                    progressHandler: progressHandler
                )
            case .parakeetUnified:
                try await ModelHub.download(
                    .parakeetUnified,
                    to: Self.fluidAudioModelsRootDirectory(),
                    variant: Self.parakeetUnifiedOfflineVariant,
                    additionalModelNames: [Self.parakeetUnifiedStreamingEncoderFile],
                    progressHandler: Self.downloadOnlyProgressHandler(forwarding: progressHandler)
                )
                beginModelPreparation(for: modelName, downloadID: downloadID)
                try await Self.optimizeParakeetUnifiedRealtimeModel()
                try await Self.optimizeParakeetUnifiedBatchModel()
            case .nemotron(let variant):
                let modelDirectory = try await StreamingNemotronMultilingualAsrManager.downloadVariant(
                    languageCode: variant.downloadLanguageCode,
                    chunkMs: Self.nemotronChunkMs,
                    progressHandler: progressHandler
                )
                beginModelPreparation(for: modelName, downloadID: downloadID)
                let manager = StreamingNemotronMultilingualAsrManager()
                do {
                    try await manager.loadModels(from: modelDirectory)
                } catch {
                    await manager.cleanup()
                    throw error
                }
                await manager.cleanup()
            case .parakeet(let version):
                guard let repo = Self.parakeetRepo(for: version) else {
                    throw AsrModelsError.loadingFailed("Unsupported Parakeet model version.")
                }
                let cacheDirectory = AsrModels.defaultCacheDirectory(for: version)
                try await ModelHub.download(
                    repo,
                    to: cacheDirectory.deletingLastPathComponent(),
                    variant: version == .v3 ? ParakeetEncoderPrecision.int8.rawValue : nil,
                    additionalModelNames: [ModelNames.ASR.vocabularyFile],
                    progressHandler: Self.downloadOnlyProgressHandler(forwarding: progressHandler)
                )
                beginModelPreparation(for: modelName, downloadID: downloadID)
                _ = try await AsrModels.load(
                    from: cacheDirectory,
                    version: version,
                    encoderPrecision: .int8
                )
            }
            modelStateRevision += 1
        } catch {
            logger.error("❌ FluidAudio download failed for \(modelName, privacy: .public): \(error, privacy: .public)")
        }
    }

    private func installCohereTranscribe(
        modelName: String,
        downloadID: UUID,
        progressHandler: @escaping ProgressHandler
    ) async throws {
        try await ModelHub.download(
            .cohereTranscribeCoreml,
            to: Self.fluidAudioModelsRootDirectory(),
            progressHandler: Self.downloadOnlyProgressHandler(forwarding: progressHandler)
        )
        beginCohereOptimization(for: modelName, downloadID: downloadID)

        do {
            try await Self.warmUpCohereTranscribeModel()
            finishCohereOptimization(succeeded: true)
        } catch {
            finishCohereOptimization(succeeded: false)
            throw error
        }
    }

    nonisolated private static func warmUpCohereTranscribeModel() async throws {
        let directory = cohereTranscribeCacheDirectory()
        let models = try await CoherePipeline.loadModels(
            encoderDir: directory,
            decoderDir: directory,
            vocabDir: directory
        )
        let pipeline = CoherePipeline()
        _ = try await pipeline.transcribe(
            audio: [Float](repeating: 0, count: CohereAsrConfig.sampleRate),
            models: models,
            language: .english,
            maxNewTokens: 1
        )
    }

    nonisolated private static func optimizeParakeetUnifiedRealtimeModel() async throws {
        let streamingManager = StreamingUnifiedAsrManager(
            config: parakeetUnifiedStreamingConfig,
            encoderPrecision: parakeetUnifiedPrecision
        )
        do {
            try await streamingManager.loadModels(from: parakeetUnifiedCacheDirectory())
        } catch {
            await streamingManager.cleanup()
            throw error
        }
        await streamingManager.cleanup()
    }

    nonisolated private static func optimizeParakeetUnifiedBatchModel() async throws {
        let batchManager = UnifiedAsrManager(encoderPrecision: parakeetUnifiedPrecision)
        do {
            try await batchManager.loadModels(from: parakeetUnifiedCacheDirectory())
        } catch {
            await batchManager.cleanup()
            throw error
        }
        await batchManager.cleanup()
    }

    nonisolated private static func parakeetRepo(for version: AsrModelVersion) -> Repo? {
        switch version {
        case .v2:
            return .parakeetV2
        case .v3:
            return .parakeetV3
        default:
            return nil
        }
    }

    // MARK: - Delete

    func deleteFluidAudioModel(_ model: FluidAudioModel) {
        let cacheDirectory = cacheDirectory(for: model)

        do {
            if FileManager.default.fileExists(atPath: cacheDirectory.path) {
                try FileManager.default.removeItem(at: cacheDirectory)
            }
        } catch {
            // Silently ignore removal errors
        }

        // Notify TranscriptionModelManager to clear currentTranscriptionModel if it matches
        modelStateRevision += 1
        onModelDeleted?(model.name)
    }

    // MARK: - Finder

    func showFluidAudioModelInFinder(_ model: FluidAudioModel) {
        let cacheDirectory = cacheDirectory(for: model)

        if FileManager.default.fileExists(atPath: cacheDirectory.path) {
            NSWorkspace.shared.selectFile(cacheDirectory.path, inFileViewerRootedAtPath: "")
        }
    }

    // MARK: - Private helpers

    private func cacheDirectory(for model: FluidAudioModel) -> URL {
        cacheDirectory(for: model.name)
    }

    private func cacheDirectory(for modelName: String) -> URL {
        switch Self.modelKind(for: modelName) {
        case .cohereTranscribe:
            return Self.cohereTranscribeCacheDirectory()
        case .nemotron(let variant):
            return Self.nemotronCacheDirectory(for: variant)
        case .parakeetUnified:
            return Self.parakeetUnifiedCacheDirectory()
        case .parakeet(let version):
            return cacheDirectory(for: version)
        }
    }

    private func cacheDirectory(for version: AsrModelVersion) -> URL {
        AsrModels.defaultCacheDirectory(for: version)
    }

    nonisolated private static var parakeetUnifiedRequiredFiles: Set<String> {
        ModelNames.ParakeetUnified.requiredModels(variant: parakeetUnifiedStreamingVariant)
            .union(ModelNames.ParakeetUnified.requiredModels(variant: parakeetUnifiedOfflineVariant))
            .union([parakeetUnifiedStreamingEncoderFile])
    }

    nonisolated private static var cohereTranscribeRequiredFiles: Set<String> {
        ModelNames.CohereTranscribe.requiredModels
    }

    nonisolated private static func cohereTranscribeRequiredFilesExist() -> Bool {
        let fileManager = FileManager.default
        let directory = cohereTranscribeCacheDirectory()

        for file in cohereTranscribeRequiredFiles {
            let fileURL = directory.appendingPathComponent(file)
            guard fileManager.fileExists(atPath: fileURL.path) else { return false }

            guard file.hasSuffix(".mlmodelc") else { continue }
            guard fileManager.fileExists(atPath: fileURL.appendingPathComponent("coremldata.bin").path) else {
                return false
            }

            if let enumerator = fileManager.enumerator(at: fileURL, includingPropertiesForKeys: nil) {
                for case let item as URL in enumerator where item.pathExtension == "partial" {
                    return false
                }
            }
        }

        return true
    }

    nonisolated private static func nemotronRequiredFilesExist(in directory: URL) -> Bool {
        let requiredFiles = [
            ModelNames.NemotronMultilingualStreaming.metadata,
            ModelNames.NemotronMultilingualStreaming.tokenizer,
            ModelNames.NemotronMultilingualStreaming.encoderFile,
        ]

        let requiredFilesExist = requiredFiles.allSatisfy {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
        guard requiredFilesExist else { return false }

        let hasFusedDecoder = [
            "decoder_joint_argmax.mlmodelc",
            "decoder_joint_noencproj.mlmodelc",
            "decoder_joint.mlmodelc",
        ].contains { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
        let hasBareDecoderAndJoint =
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(ModelNames.NemotronMultilingualStreaming.decoderFile).path
            )
            && FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(ModelNames.NemotronMultilingualStreaming.jointFile).path
            )

        return hasFusedDecoder || hasBareDecoderAndJoint
    }

    nonisolated static func parakeetUnifiedCacheDirectory() -> URL {
        fluidAudioModelsRootDirectory()
            .appendingPathComponent(Repo.parakeetUnified.folderName, isDirectory: true)
    }

    nonisolated static func cohereTranscribeCacheDirectory() -> URL {
        fluidAudioModelsRootDirectory()
            .appendingPathComponent(Repo.cohereTranscribeCoreml.folderName, isDirectory: true)
    }

    // Matches the cache root used by FluidAudio's Unified managers.
    nonisolated private static func fluidAudioModelsRootDirectory() -> URL {
        let fileManager = FileManager.default
        if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return
                appSupport
                .appendingPathComponent("FluidAudio", isDirectory: true)
                .appendingPathComponent("Models", isDirectory: true)
        }

        return fileManager.temporaryDirectory
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    nonisolated private static func downloadOnlyProgressHandler(
        forwarding progressHandler: ProgressHandler?
    ) -> ProgressHandler {
        { progress in
            // ModelHub reports downloads in 0...0.5, so expose the network phase as 0...1.
            let downloadFraction = min(max(progress.fractionCompleted * 2.0, 0.0), 1.0)
            progressHandler?(
                DownloadProgress(
                    fractionCompleted: downloadFraction,
                    phase: progress.phase
                ))
        }
    }

    private func beginModelPreparation(for modelName: String, downloadID: UUID) {
        guard activeDownloadIDs[modelName] == downloadID else { return }
        activeNetworkProgressIDs[modelName] = nil
        downloadStatuses[modelName] = FluidAudioDownloadStatus(
            fractionCompleted: 1.0,
            message: String(localized: "Optimizing model for your device"),
            isIndeterminate: true
        )
    }

    private func beginCohereOptimization(for modelName: String, downloadID: UUID) {
        guard activeDownloadIDs[modelName] == downloadID else { return }
        activeNetworkProgressIDs[modelName] = nil
        downloadStatuses[modelName] = nil
        cohereOptimizationState = .optimizing
    }

    private func finishCohereOptimization(succeeded: Bool) {
        cohereOptimizationState = succeeded ? .idle : .failed
    }

    private func clearDownloadStatus(for modelName: String, downloadID: UUID) {
        guard activeDownloadIDs[modelName] == downloadID else { return }
        activeDownloadIDs[modelName] = nil
        activeNetworkProgressIDs[modelName] = nil
        downloadStatuses[modelName] = nil
    }

    private func updateDownloadProgress(_ progress: DownloadProgress, for modelName: String, downloadID: UUID) {
        guard activeDownloadIDs[modelName] == downloadID,
            activeNetworkProgressIDs[modelName] == downloadID
        else { return }

        let reportedFraction = min(max(progress.fractionCompleted, 0.0), 1.0)
        let currentFraction = downloadStatuses[modelName]?.fractionCompleted ?? 0.0
        guard reportedFraction >= currentFraction else { return }

        downloadStatuses[modelName] = FluidAudioDownloadStatus(
            fractionCompleted: reportedFraction,
            message: FluidAudioModelManager.statusMessage(for: progress),
            isIndeterminate: Self.isIndeterminatePhase(progress.phase)
        )
    }

    private static func isIndeterminatePhase(_ phase: DownloadPhase) -> Bool {
        if case .compiling(let modelName) = phase {
            return modelName.isEmpty
        }

        return false
    }

    private static func statusMessage(for progress: DownloadProgress) -> String {
        switch progress.phase {
        case .listing:
            return String(localized: "Listing files from repository...")
        case .downloading(let completedFiles, let totalFiles):
            guard totalFiles > 0 else {
                return String(localized: "Checking cached models...")
            }
            return String(
                format: String(localized: "Downloading model files: %lld/%lld"), Int64(completedFiles),
                Int64(totalFiles))
        case .compiling(let modelName):
            guard !modelName.isEmpty else {
                return String(localized: "Finalizing models...")
            }
            return String(format: String(localized: "Compiling %@"), displayName(forModelComponent: modelName))
        }
    }

    private static func displayName(forModelComponent modelName: String) -> String {
        modelName.replacingOccurrences(of: ".mlmodelc", with: "")
    }
}
