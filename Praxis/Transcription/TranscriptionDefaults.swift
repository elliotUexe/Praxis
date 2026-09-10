import Foundation
import WhisperKit

/// What Praxis tells Whisper about the language of a lecture.
///
/// Auto is the default and the right answer nearly always: detection costs one extra
/// decoder pass per 30-second window and is reliable on continuous speech. The two explicit
/// choices exist for the case detection gets wrong — a French lecture dense with English
/// technical vocabulary, say — where pinning the language is more predictable than letting
/// each window decide for itself.
enum TranscriptionLanguage: String, CaseIterable, Identifiable {
    case auto
    case french = "fr"
    case english = "en"

    static let storageKey = "transcriptionLanguage"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Automatique"
        case .french: return "Français"
        case .english: return "Anglais"
        }
    }

    /// What `DecodingOptions.language` should be: nil means "detect it".
    var whisperCode: String? {
        self == .auto ? nil : rawValue
    }

    static var current: TranscriptionLanguage {
        UserDefaults.standard.string(forKey: storageKey)
            .flatMap(TranscriptionLanguage.init(rawValue:)) ?? .auto
    }
}

/// The decoding options every transcription path shares.
///
/// Live, refinement and import each carried their own identical copy, which is how
/// `language: "fr"` came to be hardcoded in three places at once. Forcing the French token
/// on English speech does not fail loudly — measured on a sample, the large-v3 model
/// quietly *translates* it, so an English lecture came back as degraded French prose rather
/// than as an obvious error.
enum TranscriptionDefaults {
    /// Read once per call from the stored setting, so changing the language in Réglages
    /// applies to the next transcription without restarting anything.
    ///
    /// - Note: on `.auto`, `language` is left nil — "whatever the audio is".
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
    static func decodingOptions(language: TranscriptionLanguage = .current) -> DecodingOptions {
        DecodingOptions(
            task: .transcribe,
            language: language.whisperCode,
            // Only meaningful when no language is pinned, but harmless otherwise, and
            // passing it unconditionally keeps the two settings from having to agree.
            detectLanguage: language == .auto,
            skipSpecialTokens: true,
            compressionRatioThreshold: 2.4,
            noSpeechThreshold: 0.6
        )
    }
}
