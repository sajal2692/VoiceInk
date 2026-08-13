import Foundation

let voiceInkRefineXPCServiceName = "com.prakashjoshipax.VoiceInk.RefineXPC"
let voiceInkRefineXPCErrorDomain = "com.prakashjoshipax.VoiceInk.RefineXPC"

/// Per-model generation settings. Optional so a request encoded by an older
/// build still decodes, in which case the engine falls back to its defaults.
struct VoiceInkRefineGenerationOptions: Codable, Sendable {
    let temperature: Float?
    let prefillStepSize: Int?

    init(temperature: Float? = nil, prefillStepSize: Int? = nil) {
        self.temperature = temperature
        self.prefillStepSize = prefillStepSize
    }
}

struct VoiceInkRefinePrepareRequest: Codable, Sendable {
    let requestID: UUID
    let modelDirectoryPath: String
    let systemPrompt: String
    let options: VoiceInkRefineGenerationOptions?
}

struct VoiceInkRefineEnhanceRequest: Codable, Sendable {
    let requestID: UUID
    let modelDirectoryPath: String
    let systemPrompt: String
    let transcript: String
    let options: VoiceInkRefineGenerationOptions?
}

struct VoiceInkRefineEnhanceResponse: Codable, Sendable {
    let requestID: UUID
    let output: String
}

enum VoiceInkRefineXPCErrorCode: Int {
    case invalidRequest = 1
    case inferenceFailed = 2
    case invalidResponse = 3
    case connectionFailed = 4
}

@objc protocol VoiceInkRefineXPCProtocol {
    func prepare(
        _ requestData: NSData,
        withReply reply: @escaping (NSError?) -> Void
    )

    func enhance(
        _ requestData: NSData,
        withReply reply: @escaping (NSData?, NSError?) -> Void
    )

    func shutdown(withReply reply: @escaping () -> Void)
}

func makeVoiceInkRefineXPCError(
    _ code: VoiceInkRefineXPCErrorCode,
    description: String
) -> NSError {
    NSError(
        domain: voiceInkRefineXPCErrorDomain,
        code: code.rawValue,
        userInfo: [NSLocalizedDescriptionKey: description]
    )
}
