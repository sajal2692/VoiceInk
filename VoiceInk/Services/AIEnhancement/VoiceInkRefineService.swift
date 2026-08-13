import Combine
import Foundation
import OSLog

enum VoiceInkRefineAvailability: Equatable {
    case available
    case unsupportedIntel
    case insufficientMemory
}

enum VoiceInkRefineError: LocalizedError {
    case unavailable
    case modelNotDownloaded
    case unknownModel(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return String(localized: "Local AI requires an Apple silicon Mac with at least 16 GB of memory.")
        case .modelNotDownloaded:
            return String(localized: "The selected local model is not downloaded.")
        case let .unknownModel(name):
            return String(localized: "\(name) is not a known local model.")
        }
    }
}

/// Owns the on-device MLX models: download state, disk layout, and the XPC
/// inference client. Models are described by `LocalMLXModelCatalog`.
final class VoiceInkRefineService: ObservableObject {
    static let shared = VoiceInkRefineService()

    static let providerName = AIProvider.voiceInkRefine.rawValue

    /// Used by models that are tuned for cleanup and ignore user prompts.
    /// Instruction-tuned models in the catalog receive the Mode's prompt instead.
    static let systemPrompt = """
        Transform raw ASR input into polished text. Preserve the original meaning and tone. Handle punctuation, capitalization, and spoken formatting cues properly. Remove fillers, repetitions, false starts, and discarded self-corrections. Output only the final text.
        """

    /// The name shown when no specific model has been chosen yet.
    static var modelName: String {
        shared.defaultModelName
    }

    static let minimumMemoryBytes: UInt64 = 16 * 1_024 * 1_024 * 1_024

    @Published private(set) var downloadedModelIDs: Set<String> = []
    @Published private(set) var downloadingModelID: String?
    @Published private(set) var downloadProgress = 0.0
    @Published private(set) var downloadError: String?
    /// The model `downloadError` belongs to, so one failure does not mark every
    /// card in the list as failed.
    @Published private(set) var failedModelID: String?
    private(set) var downloadedBytes: Int64 = 0
    private(set) var totalDownloadBytes: Int64 = 0
    private(set) var isFinalizingDownload = false

    let availability: VoiceInkRefineAvailability
    private let physicalMemory: UInt64

    /// Catalog models this Mac has enough memory to run.
    var runnableModels: [LocalMLXModel] {
        guard availability != .unsupportedIntel else { return [] }
        return LocalMLXModelCatalog.supportedModels(physicalMemory: physicalMemory)
    }

    var downloadedModels: [LocalMLXModel] {
        runnableModels.filter { downloadedModelIDs.contains($0.id) }
    }

    /// Model names offered to Modes. Only downloaded models can be selected.
    var downloadedModelNames: [String] {
        downloadedModels.map(\.displayName)
    }

    var isAvailableInModes: Bool {
        availability == .available && !downloadedModels.isEmpty
    }

    private var defaultModelName: String {
        downloadedModels.first?.displayName
            ?? LocalMLXModelCatalog.defaultModel.displayName
    }

    private let logger = Logger(
        subsystem: "com.prakashjoshipax.voiceink",
        category: "VoiceInkRefineService"
    )
    private let modelRootDirectory: URL
    private let inferenceClient = VoiceInkRefineXPCClient()
    private var downloadTask: Task<Void, Never>?

    private init(
        architectureIsAppleSilicon: Bool = SystemArchitecture.isAppleSilicon,
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) {
        self.physicalMemory = physicalMemory

        if !architectureIsAppleSilicon {
            availability = .unsupportedIntel
        } else if physicalMemory < Self.minimumMemoryBytes {
            availability = .insufficientMemory
        } else {
            availability = .available
        }

        let appSupportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        modelRootDirectory = appSupportDirectory
            .appendingPathComponent("com.prakashjoshipax.VoiceInk")
            .appendingPathComponent("VoiceInkRefine")

        refreshDownloadedState()
    }

    // MARK: - Model lookup

    /// Falls back to matching on `id` so a stored selection still resolves if a
    /// model's display name is revised in a later release.
    func model(named displayName: String?) -> LocalMLXModel? {
        guard let displayName else { return nil }
        return LocalMLXModelCatalog.model(displayName: displayName)
            ?? LocalMLXModelCatalog.model(id: displayName)
    }

    /// Resolves the model a Mode should run, falling back to any downloaded
    /// model when the stored selection is missing or no longer installed.
    func resolvedModel(named displayName: String?) -> LocalMLXModel? {
        if let model = model(named: displayName), downloadedModelIDs.contains(model.id) {
            return model
        }
        return downloadedModels.first
    }

    /// Whether the model a Mode would run follows the Mode's own prompt.
    /// Cleanup-tuned models ignore it and always use `Self.systemPrompt`.
    func supportsCustomPrompts(modelName: String?) -> Bool {
        resolvedModel(named: modelName)?.supportsCustomPrompts ?? false
    }

    func isDownloaded(_ model: LocalMLXModel) -> Bool {
        downloadedModelIDs.contains(model.id)
    }

    func isDownloading(_ model: LocalMLXModel) -> Bool {
        downloadingModelID == model.id
    }

    func canRun(_ model: LocalMLXModel) -> Bool {
        availability != .unsupportedIntel && physicalMemory >= model.minimumMemoryBytes
    }

    func unavailableDescription(for model: LocalMLXModel) -> String? {
        if availability == .unsupportedIntel {
            return String(localized: "Available on Apple silicon Macs.")
        }
        guard !canRun(model) else { return nil }

        let requirement = ByteCountFormatter.string(
            fromByteCount: Int64(model.minimumMemoryBytes),
            countStyle: .memory
        )
        return String(format: String(localized: "Requires at least %@ of memory."), requirement)
    }

    func snapshotURL(for model: LocalMLXModel) -> URL? {
        #if arch(arm64)
            return VoiceInkRefineModelDownloader.snapshotDirectory(
                in: modelRootDirectory,
                model: model
            )
        #else
            return nil
        #endif
    }

    func downloadedModelURL(for model: LocalMLXModel) -> URL? {
        isDownloaded(model) ? snapshotURL(for: model) : nil
    }

    // MARK: - Downloading

    @MainActor
    func startDownload(_ model: LocalMLXModel) {
        guard canRun(model), !isDownloaded(model), downloadTask == nil else {
            return
        }

        downloadTask = Task { [weak self] in
            await self?.downloadModel(model)
        }
    }

    @MainActor
    func cancelDownload() {
        downloadTask?.cancel()
    }

    @MainActor
    func deleteModel(_ model: LocalMLXModel) async {
        if isDownloading(model) {
            cancelDownload()
        }
        await inferenceClient.shutdown()

        guard let snapshotURL = snapshotURL(for: model) else { return }

        do {
            if model.usesLegacyRootDirectory {
                // The legacy model shares the root directory with the
                // subdirectories of every other model, so remove its files
                // individually instead of the whole tree.
                for file in model.files {
                    let fileURL = snapshotURL.appendingPathComponent(file.path)
                    if FileManager.default.fileExists(atPath: fileURL.path) {
                        try FileManager.default.removeItem(at: fileURL)
                    }
                }
                let integrityURL = snapshotURL.appendingPathComponent(".voiceink-integrity.json")
                try? FileManager.default.removeItem(at: integrityURL)
            } else if FileManager.default.fileExists(atPath: snapshotURL.path) {
                try FileManager.default.removeItem(at: snapshotURL)
            }

            if downloadingModelID == model.id {
                downloadProgress = 0
                downloadedBytes = 0
                isFinalizingDownload = false
            }
            if failedModelID == model.id {
                downloadError = nil
                failedModelID = nil
            }
            refreshDownloadedState()
            NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
        } catch {
            downloadError = error.localizedDescription
            failedModelID = model.id
            logger.error(
                "Failed to delete \(model.displayName, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    @MainActor
    private func downloadModel(_ model: LocalMLXModel) async {
        downloadProgress = 0
        downloadedBytes = 0
        totalDownloadBytes = model.totalBytes
        isFinalizingDownload = false
        downloadError = nil
        failedModelID = nil
        downloadingModelID = model.id

        defer {
            downloadingModelID = nil
            isFinalizingDownload = false
            downloadTask = nil
        }

        #if arch(arm64)
            let downloader = VoiceInkRefineModelDownloader(
                model: model,
                modelRootDirectory: modelRootDirectory
            )
            let progressTask = Task { @MainActor [weak self, downloader] in
                while !Task.isCancelled {
                    self?.applyDownloadProgress(downloader.progress)
                    try? await Task.sleep(for: .seconds(2))
                }
            }
            defer {
                progressTask.cancel()
            }

            do {
                let downloadOperation = Task.detached(priority: .utility) {
                    try await downloader.download()
                }
                defer {
                    downloadOperation.cancel()
                }

                try await withTaskCancellationHandler {
                    try await downloadOperation.value
                } onCancel: {
                    downloadOperation.cancel()
                }
                try Task.checkCancellation()
                applyDownloadProgress(downloader.progress)
                refreshDownloadedState()
                downloadProgress = isDownloaded(model) ? 1 : 0
                NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
            } catch is CancellationError {
                downloadError = nil
                failedModelID = nil
            } catch {
                downloadError = error.localizedDescription
                failedModelID = model.id
                logger.error(
                    "Failed to download \(model.displayName, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        #else
            downloadError = VoiceInkRefineError.unavailable.localizedDescription
            failedModelID = model.id
        #endif
    }

    // MARK: - Inference

    /// - Parameters:
    ///   - modelName: the Mode's selected model; falls back to any downloaded model.
    ///   - systemPrompt: the Mode's prompt for instruction-tuned models. Models
    ///     that do not support custom prompts always use the cleanup prompt.
    func enhance(
        transcript: String,
        modelName: String? = nil,
        systemPrompt: String? = nil
    ) async throws -> String {
        guard availability == .available else {
            throw VoiceInkRefineError.unavailable
        }
        guard let model = resolvedModel(named: modelName) else {
            throw VoiceInkRefineError.modelNotDownloaded
        }
        guard let snapshotURL = snapshotURL(for: model) else {
            throw VoiceInkRefineError.modelNotDownloaded
        }

        return try await inferenceClient.enhance(
            transcript: transcript,
            modelDirectory: snapshotURL,
            systemPrompt: resolvedSystemPrompt(for: model, requested: systemPrompt),
            temperature: model.temperature,
            prefillStepSize: model.prefillStepSize
        )
    }

    func unloadPreparedModelIfNeeded() async {
        await inferenceClient.shutdownPreparedModelIfNeeded()
    }

    func keepPreparedModelWarmForRecording() async {
        await inferenceClient.keepPreparedModelWarmForRecording()
    }

    func prepareForRecording(modelName: String? = nil) async {
        guard availability == .available,
            let model = resolvedModel(named: modelName),
            let snapshotURL = snapshotURL(for: model)
        else {
            return
        }

        do {
            try await inferenceClient.prepare(
                modelDirectory: snapshotURL,
                systemPrompt: resolvedSystemPrompt(for: model, requested: nil),
                temperature: model.temperature,
                prefillStepSize: model.prefillStepSize
            )
        } catch is CancellationError {
        } catch {
            logger.error(
                "Background model preparation failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func resolvedSystemPrompt(
        for model: LocalMLXModel,
        requested: String?
    ) -> String {
        guard model.supportsCustomPrompts, let requested, !requested.isEmpty else {
            return Self.systemPrompt
        }
        return requested
    }

    // MARK: - State

    private func refreshDownloadedState() {
        var installed: Set<String> = []

        for model in LocalMLXModelCatalog.all {
            guard let snapshotURL = snapshotURL(for: model) else { continue }
            if VoiceInkRefineModelDownloader.isSnapshotComplete(
                at: snapshotURL,
                model: model
            ) {
                installed.insert(model.id)
            }
        }

        downloadedModelIDs = installed
    }

    @MainActor
    private func applyDownloadProgress(
        _ progress: VoiceInkRefineDownloadProgress
    ) {
        downloadedBytes = progress.downloadedBytes
        totalDownloadBytes = progress.totalBytes
        isFinalizingDownload = progress.isFinalizing
        downloadProgress = progress.totalBytes > 0
            ? min(1, Double(progress.downloadedBytes) / Double(progress.totalBytes))
            : 0
    }
}
