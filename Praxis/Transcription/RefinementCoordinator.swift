import Foundation
import WhisperKit

/// Owns the high-quality (large-v3) model used to re-transcribe VAD-closed
/// segments in the background. Being an actor serializes refine jobs to one
/// at a time by construction — no separate queue needed.
actor RefinementCoordinator {
    private var whisperKit: WhisperKit?

    func prepare(modelName: String = "large-v3-v20240930_626MB") async throws {
        guard whisperKit == nil else { return }
        let computeOptions = ModelComputeOptions(
            melCompute: .cpuAndGPU,
            audioEncoderCompute: .cpuAndGPU,
            textDecoderCompute: .cpuAndGPU
        )
        whisperKit = try await WhisperKit(WhisperKitConfig(
            model: modelName,
            computeOptions: computeOptions,
            load: true
        ))
    }

    func refine(samples: [Float]) async throws -> String {
        guard let whisperKit else { return "" }
        let options = DecodingOptions(
            task: .transcribe,
            language: "fr",
            skipSpecialTokens: true,
            compressionRatioThreshold: 2.4,
            noSpeechThreshold: 0.6
        )
        let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options)
        return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }
}
