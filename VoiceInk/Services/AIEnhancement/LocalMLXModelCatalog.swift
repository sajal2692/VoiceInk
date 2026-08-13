import Foundation

/// One file inside a pinned Hugging Face snapshot.
///
/// Every local model is pinned to an exact revision and each file is verified
/// by size and SHA-256 after download, so a partial or tampered snapshot never
/// reaches the inference engine. Regenerate these manifests with
/// `scripts/generate-mlx-model-manifest.py`.
struct LocalMLXModelFile: Sendable {
    let path: String
    let size: Int64
    let sha256: String?

    init(path: String, size: Int64, sha256: String? = nil) {
        self.path = path
        self.size = size
        self.sha256 = sha256
    }
}

/// An on-device model run through MLX in the refine XPC service.
struct LocalMLXModel: Identifiable, Sendable, Equatable {
    /// Stable key. Doubles as the on-disk directory name and the persisted
    /// model selection, so it must never change once shipped.
    let id: String
    /// User-visible name. This is what `AIService` stores as the selected model.
    let displayName: String
    let repositoryID: String
    let revision: String
    let files: [LocalMLXModelFile]
    let minimumMemoryBytes: UInt64
    /// Instruction-tuned general models follow VoiceInk prompts and Modes.
    /// The purpose-tuned cleanup model ignores them and takes a fixed prompt.
    let supportsCustomPrompts: Bool
    /// Prompt tokens processed per step. Smaller steps cap the peak memory of
    /// the prefill pass, which matters most on the larger models.
    let prefillStepSize: Int?
    let temperature: Float
    /// The original model shipped before the catalog existed and lives at the
    /// root of the model directory. Newer models are namespaced by `id`.
    let usesLegacyRootDirectory: Bool

    var totalBytes: Int64 {
        files.reduce(Int64(0)) { $0 + $1.size }
    }

    var downloadSizeDescription: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    var localizedSummary: String {
        switch id {
        case LocalMLXModelCatalog.refineV1.id:
            return String(localized: "Fastest. Tuned specifically for transcript cleanup.")
        case LocalMLXModelCatalog.gemma4E2B.id:
            return String(localized: "Fast. Follows your own prompts and Modes.")
        case LocalMLXModelCatalog.gemma4E4B.id:
            return String(localized: "Balanced quality and speed.")
        default:
            return String(localized: "Highest quality. Slowest to run.")
        }
    }

    static func == (lhs: LocalMLXModel, rhs: LocalMLXModel) -> Bool {
        lhs.id == rhs.id
    }
}

enum LocalMLXModelCatalog {
    static let refineV1 = LocalMLXModel(
        id: "voiceink-refine-v1",
        displayName: "VoiceInk Refine V1",
        repositoryID: "beingpax/VoiceInk-Refine-V1",
        revision: "ad665418d3850e379e29236e66be3ddc0ac0bf04",
        files: [
            LocalMLXModelFile(
                path: ".gitattributes",
                size: 1_570,
                sha256: "34448b82c17d60fec9b65b1f093c115ddbaadc04beb1b0140b6bfed2e012a930"
            ),
            LocalMLXModelFile(
                path: "LICENSE-QWEN-APACHE-2.0.txt",
                size: 11_544,
                sha256: "bbedc3fda3305820b977265f01b8619d87570a6739de3a5582c3464840f1e57a"
            ),
            LocalMLXModelFile(
                path: "LICENSE.md",
                size: 275,
                sha256: "ab9ec0078c932a50c5dc077d58fd1b77aa1f8ad395cc93c314cce84fa5263e11"
            ),
            LocalMLXModelFile(
                path: "README.md",
                size: 965,
                sha256: "c4fd4a4e32552136f44dbd9526ee6ba97e02078ba520e89ab0e68de518642a0b"
            ),
            LocalMLXModelFile(
                path: "THIRD_PARTY_NOTICES.md",
                size: 479,
                sha256: "bb910585f2eab7e4fdc42b434f50d3c27fd29737ce32644ee2c0c26981015c19"
            ),
            LocalMLXModelFile(
                path: "chat_template.jinja",
                size: 6_412,
                sha256: "83b19588ce0999213e4a36b855e104d3937c6271bb5711400dd399407233a3d4"
            ),
            LocalMLXModelFile(
                path: "config.json",
                size: 2_479,
                sha256: "257f7f080bde674382cb09df314bf4f2b5d4f5c6b6465d3a8d6c98d8443b5b12"
            ),
            LocalMLXModelFile(
                path: "model.safetensors",
                size: 1_059_404_951,
                sha256: "3cdfe2f506f71f2c5d5af23aa8fe3572989d2f364a7317322220621a86aaf5f6"
            ),
            LocalMLXModelFile(
                path: "model.safetensors.index.json",
                size: 60_786,
                sha256: "3b2dffa510d1d73decdbc12d5e1bc7d6a9f7b2deb631bfd84238a1f8fc4e0fd1"
            ),
            LocalMLXModelFile(
                path: "tokenizer.json",
                size: 19_989_325,
                sha256: "06b9509352d2af50381ab2247e083b80d32d5c0aba91c272ca9ff729b6a0e523"
            ),
            LocalMLXModelFile(
                path: "tokenizer_config.json",
                size: 582,
                sha256: "f7c2417da2c86b4fa75c6bbabc8be6cbc8de0ec971bd153f49fd1d0907ed2b1e"
            ),
        ],
        minimumMemoryBytes: 16 * 1_024 * 1_024 * 1_024,
        supportsCustomPrompts: false,
        prefillStepSize: nil,
        temperature: 0.3,
        usesLegacyRootDirectory: true
    )

    static let gemma4E2B = LocalMLXModel(
        id: "gemma-4-e2b-it-4bit",
        displayName: "Gemma 4 E2B (4-bit)",
        repositoryID: "mlx-community/gemma-4-e2b-it-4bit",
        revision: "238767527555cb75a05732a84dff5d6ba0dd6809",
        files: [
            LocalMLXModelFile(
                path: "chat_template.jinja",
                size: 17_336,
                sha256: "2f1b4d75d067bae3fe44e676721c7f077d243bc007156cb9c2f8b5836613d082"
            ),
            LocalMLXModelFile(
                path: "config.json",
                size: 6_395,
                sha256: "6397cb6eca41b911d1dcab74e17941351057bd759284052a2331918ff6f9246c"
            ),
            LocalMLXModelFile(
                path: "generation_config.json",
                size: 208,
                sha256: "d4226bbe3117d2d253ba4609720ba82c6c4ce4627a9a6ae05387c78983ac03de"
            ),
            LocalMLXModelFile(
                path: "model.safetensors",
                size: 3_550_670_554,
                sha256: "038e39a37a7667373d2c3991375446b10c96ae1d717a68674870343db376b76e"
            ),
            LocalMLXModelFile(
                path: "model.safetensors.index.json",
                size: 218_323,
                sha256: "edb157dbf495e23f37377af4a628a9ad13c4ee7937f93ccb36ec9e9a19940f16"
            ),
            LocalMLXModelFile(
                path: "processor_config.json",
                size: 1_316,
                sha256: "de3e580aebdc98272d4c4547daffe6525fcbae18a83a0e0bcf0d7444d4ee6f37"
            ),
            LocalMLXModelFile(
                path: "tokenizer.json",
                size: 32_169_626,
                sha256: "cc8d3a0ce36466ccc1278bf987df5f71db1719b9ca6b4118264f45cb627bfe0f"
            ),
            LocalMLXModelFile(
                path: "tokenizer_config.json",
                size: 2_740,
                sha256: "080d9e1aff284e2f6043889cd05367966f7c7b80e025fbc0b06745e218158656"
            ),
        ],
        minimumMemoryBytes: 16 * 1_024 * 1_024 * 1_024,
        supportsCustomPrompts: true,
        prefillStepSize: 256,
        temperature: 0.1,
        usesLegacyRootDirectory: false
    )

    static let gemma4E4B = LocalMLXModel(
        id: "gemma-4-e4b-it-4bit",
        displayName: "Gemma 4 E4B (4-bit)",
        repositoryID: "mlx-community/gemma-4-e4b-it-4bit",
        revision: "475b9088d29754a3379866cf5aeb6b41acd313c2",
        files: [
            LocalMLXModelFile(
                path: "chat_template.jinja",
                size: 17_336,
                sha256: "2f1b4d75d067bae3fe44e676721c7f077d243bc007156cb9c2f8b5836613d082"
            ),
            LocalMLXModelFile(
                path: "config.json",
                size: 6_628,
                sha256: "780ccb3a514a5f1ced161d383f948fc22eca9b84b752ca19494f625bd9bad7a6"
            ),
            LocalMLXModelFile(
                path: "generation_config.json",
                size: 208,
                sha256: "d4226bbe3117d2d253ba4609720ba82c6c4ce4627a9a6ae05387c78983ac03de"
            ),
            LocalMLXModelFile(
                path: "model.safetensors",
                size: 5_146_800_534,
                sha256: "932b8271fc3fe65adcc78b96c10c6268bbfb13e8f67d1358727c0d6ee97e1eff"
            ),
            LocalMLXModelFile(
                path: "model.safetensors.index.json",
                size: 240_961,
                sha256: "f8accac59ee7efe87e0c298c854610b262c3cadd477407503147c71209ff0093"
            ),
            LocalMLXModelFile(
                path: "processor_config.json",
                size: 1_316,
                sha256: "de3e580aebdc98272d4c4547daffe6525fcbae18a83a0e0bcf0d7444d4ee6f37"
            ),
            LocalMLXModelFile(
                path: "tokenizer.json",
                size: 32_169_626,
                sha256: "cc8d3a0ce36466ccc1278bf987df5f71db1719b9ca6b4118264f45cb627bfe0f"
            ),
            LocalMLXModelFile(
                path: "tokenizer_config.json",
                size: 2_740,
                sha256: "080d9e1aff284e2f6043889cd05367966f7c7b80e025fbc0b06745e218158656"
            ),
        ],
        minimumMemoryBytes: 16 * 1_024 * 1_024 * 1_024,
        supportsCustomPrompts: true,
        prefillStepSize: 128,
        temperature: 0.1,
        usesLegacyRootDirectory: false
    )

    static let gemma412B = LocalMLXModel(
        id: "gemma-4-12b-it-4bit",
        displayName: "Gemma 4 12B (4-bit)",
        repositoryID: "mlx-community/gemma-4-12B-it-4bit",
        revision: "73bcf09092aa277861d5a191b989b666f7f32e8f",
        files: [
            LocalMLXModelFile(
                path: "chat_template.jinja",
                size: 17_466,
                sha256: "36e3a42e5cf14cd0020e72d92e1fdd9970f59b82170e421f0cbe1bb42bead3f0"
            ),
            LocalMLXModelFile(
                path: "config.json",
                size: 5_415,
                sha256: "fbc1c1cb48ed86ec98482b2d41f5a03d3991aba74b7c29a93d430761e6518a38"
            ),
            LocalMLXModelFile(
                path: "generation_config.json",
                size: 260,
                sha256: "a8349d9bd64cc5841297fcb5002f0fdc4749c473c8f1b10ea337f9ce4ee7014e"
            ),
            LocalMLXModelFile(
                path: "model-00001-of-00002.safetensors",
                size: 5_351_756_584,
                sha256: "0d58feed0c98a69c07317b4481aeae5ab2785f12a496ea96ab24c4842808de78"
            ),
            LocalMLXModelFile(
                path: "model-00002-of-00002.safetensors",
                size: 1_389_282_927,
                sha256: "5b00a1bcb596ce6e827b4cdea6ecf2a0f35bb01306eb87c1ea4b3bcde36c7755"
            ),
            LocalMLXModelFile(
                path: "model.safetensors.index.json",
                size: 135_329,
                sha256: "9ac99e7a6cf3e4d40eb8df01644fe9c04036ace94f3389df35db9d9449758516"
            ),
            LocalMLXModelFile(
                path: "processor_config.json",
                size: 868,
                sha256: "016a1db9c4f41ea0c61919c46855ea5e7c45c6e4ae4bfbedfb5b6bed79a2fe92"
            ),
            LocalMLXModelFile(
                path: "tokenizer.json",
                size: 32_169_626,
                sha256: "cc8d3a0ce36466ccc1278bf987df5f71db1719b9ca6b4118264f45cb627bfe0f"
            ),
            LocalMLXModelFile(
                path: "tokenizer_config.json",
                size: 2_719,
                sha256: "fc1384a911d2c9860ac07bc3ceafff20bff26695991744b7dbe5e1e4522bfa57"
            ),
        ],
        minimumMemoryBytes: 24 * 1_024 * 1_024 * 1_024,
        supportsCustomPrompts: true,
        prefillStepSize: 128,
        temperature: 0.1,
        usesLegacyRootDirectory: false
    )

    static let all: [LocalMLXModel] = [refineV1, gemma4E2B, gemma4E4B, gemma412B]

    /// Existing installations already have this model on disk, so it stays the
    /// default and nothing re-downloads on upgrade.
    static let defaultModel = refineV1

    static func model(id: String) -> LocalMLXModel? {
        all.first { $0.id == id }
    }

    static func model(displayName: String) -> LocalMLXModel? {
        all.first { $0.displayName == displayName }
    }

    /// Models this Mac has enough memory to run.
    static func supportedModels(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> [LocalMLXModel] {
        all.filter { physicalMemory >= $0.minimumMemoryBytes }
    }
}
