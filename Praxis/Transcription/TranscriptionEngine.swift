import Foundation
import AVFoundation
import CoreMedia
import Speech

/// Which recogniser Praxis runs, for live recording and for import alike.
///
/// Measured on four 3-minute extracts of real lectures (bench in `scripts/stt-bench/`,
/// 2026-10-03): Whisper large-v3 over 30-second windows and Apple's SpeechTranscriber come
/// out close in quality, with opposite failure modes — Whisper drops whole passages, Apple
/// keeps everything and mishears the odd word. Apple did it in a seventh of the time,
/// about a fifth of the energy, and with almost nothing held in Praxis's own memory. Both
/// are offered rather than one imposed: the trade is Pierre's to make, course by course.
enum TranscriptionEngine: String, CaseIterable, Identifiable {
    /// Whisper turbo live, every closed segment re-transcribed by large-v3, large-v3 for import.
    case whisper
    /// Apple's on-device SpeechTranscriber everywhere: no model inside Praxis, no second pass.
    case apple

    static let storageKey = "transcriptionEngine"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .whisper: return "Whisper (turbo + large)"
        case .apple: return "Apple"
        }
    }

    /// SpeechAnalyzer arrived with macOS 26; the app itself still runs on 14.
    static var isAppleAvailable: Bool {
        if #available(macOS 26, *) { return SpeechTranscriber.isAvailable }
        return false
    }

    /// The stored choice, falling back to Whisper wherever Apple's recogniser does not
    /// exist — a setting synced from a newer Mac must not leave an older one with nothing.
    static var current: TranscriptionEngine {
        let stored = UserDefaults.standard.string(forKey: storageKey).flatMap(TranscriptionEngine.init(rawValue:)) ?? .whisper
        return stored == .apple && !isAppleAvailable ? .whisper : stored
    }
}

/// A finished stretch of text with its position in the recording, whatever produced it.
struct TimedText: Sendable {
    let start: Float
    let end: Float
    let text: String
}

/// What both coordinators share about Apple's recogniser.
@available(macOS 26, *)
enum AppleSpeech {
    /// Apple's recogniser works in one locale per session and has no detection pass, so
    /// `.auto` cannot mean what it means for Whisper. It falls back to the Mac's own
    /// language when Apple supports it, and to French otherwise — the language of most
    /// of Pierre's courses.
    static func locale(for language: TranscriptionLanguage = .current) async -> Locale {
        let wanted: Locale
        switch language {
        case .french: wanted = Locale(identifier: "fr_FR")
        case .english: wanted = Locale(identifier: "en_US")
        case .auto: wanted = Locale.current
        }
        if let supported = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) {
            return supported
        }
        return await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "fr_FR"))
            ?? Locale(identifier: "fr_FR")
    }

    /// `volatileResults` only for live use: the provisional text is what fills the dimmed
    /// tail of the transcript while the lecturer is mid-sentence, exactly as Whisper's
    /// unconfirmed segments did. An import only wants the final text.
    static func makeTranscriber(locale: Locale, live: Bool) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: live ? [.volatileResults] : [],
            attributeOptions: [.audioTimeRange]
        )
    }

    /// The language model is a system asset, shared with every app, downloaded once by
    /// macOS. Nothing to do when it is already installed, which is the usual case.
    static func ensureAssets(locale: Locale) async throws {
        let probe = makeTranscriber(locale: locale, live: false)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
            try await request.downloadAndInstall()
        }
    }

    static func timed(_ result: SpeechTranscriber.Result) -> TimedText {
        TimedText(
            start: Float(CMTimeGetSeconds(result.range.start)),
            end: Float(CMTimeGetSeconds(result.range.end)),
            text: String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// One pass over a whole file. The analyser reads and converts the file itself, so a
    /// compressed `.m4a` from a past recording goes in as is.
    static func transcribe(fileURL: URL, locale: Locale) async throws -> [TimedText] {
        let transcriber = makeTranscriber(locale: locale, live: false)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task { () -> [TimedText] in
            var parts: [TimedText] = []
            for try await result in transcriber.results where result.isFinal {
                let part = timed(result)
                if !part.text.isEmpty { parts.append(part) }
            }
            return parts
        }
        let file = try AVAudioFile(forReading: fileURL)
        try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
        return try await collector.value
    }
}
