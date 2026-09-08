import Foundation
import WhisperKit

/// Owns the high-quality (large-v3) model used to re-transcribe VAD-closed
/// segments in the background. Being an actor serializes refine jobs to one
/// at a time by construction — no separate queue needed.
actor RefinementCoordinator {
    private var whisperKit: WhisperKit?

    /// No `ModelComputeOptions` override on purpose: forcing `.cpuAndGPU` on all three
    /// stages kept this model off the Neural Engine, which does the same work for a
    /// fraction of the power, and put it in direct GPU contention with everything else
    /// during a recording. WhisperKit's own defaults are tuned per device and are what the
    /// live model in `LiveTranscriptionCoordinator` has always used without trouble, so
    /// refinement now behaves the same way. Expect a slower first load while CoreML
    /// compiles the model for the ANE; that cost is one-off and cached.
    func prepare(modelName: String = "large-v3-v20240930_626MB") async throws {
        guard whisperKit == nil else { return }
        whisperKit = try await WhisperKit(WhisperKitConfig(
            model: modelName,
            load: true
        ))
    }

    /// Frees the large-v3 weights. `prepare()` reloads from the on-disk cache on demand.
    func unload() {
        whisperKit = nil
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
