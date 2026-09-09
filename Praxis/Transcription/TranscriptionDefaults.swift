import Foundation
import WhisperKit

/// The decoding options every transcription path shares.
///
/// Live, refinement and import each carried their own identical copy, which is how
/// `language: "fr"` came to be hardcoded in three places at once. Forcing the French token
/// on English speech does not fail loudly — measured on a sample, the large-v3 model
/// quietly *translates* it, so an English lecture came back as degraded French prose rather
/// than as an obvious error.
enum TranscriptionDefaults {
    /// - Note: `language` is deliberately left unset — nil means "whatever the audio is".
    ///   `detectLanguage` has to be passed explicitly all the same: its own default is
    ///   `!usePrefillPrompt`, and `usePrefillPrompt` defaults to true, so leaving it alone
    ///   would give a decoder with no language *and* no detection, which is worse than the
    ///   wrong language. Detection reuses the encoder output already computed for the
    ///   window, so it costs one extra decoder pass per 30 seconds of audio.
    ///
    ///   It runs per window rather than once per session, so a long quotation in another
    ///   language can flip the windows that contain it. If that shows up on real lectures,
    ///   the answer is a per-course Auto/Français/English setting, not a return to a
    ///   hardcoded language.
    static func decodingOptions() -> DecodingOptions {
        DecodingOptions(
            task: .transcribe,
            detectLanguage: true,
            skipSpecialTokens: true,
            compressionRatioThreshold: 2.4,
            noSpeechThreshold: 0.6
        )
    }
}
