import Foundation
import WhisperKit

@MainActor
final class ImportTranscriptionCoordinator: ObservableObject {
    @Published private(set) var isTranscribing = false
    @Published private(set) var isLoadingModel = false
    @Published private(set) var isReady = false
    @Published private(set) var progressText: String = ""
    @Published var lastError: String?
    @Published private(set) var lastOutputURL: URL?

    private var whisperKit: WhisperKit?

    func prepare(modelName: String = "large-v3-v20240930_626MB") async {
        guard whisperKit == nil, !isLoadingModel else { return }
        isLoadingModel = true
        defer { isLoadingModel = false }
        do {
            whisperKit = try await WhisperKit(WhisperKitConfig(model: modelName, load: true))
            isReady = true
        } catch {
            lastError = "Impossible de charger le modèle d'import : \(error.localizedDescription)"
        }
    }

    func transcribe(fileURL: URL) async {
        guard let whisperKit else {
            lastError = "Modèle d'import non chargé."
            return
        }
        isTranscribing = true
        progressText = "Transcription de \(fileURL.lastPathComponent)…"
        lastError = nil
        lastOutputURL = nil

        let decodingOptions = DecodingOptions(
            task: .transcribe,
            language: "fr",
            skipSpecialTokens: true,
            compressionRatioThreshold: 2.4,
            noSpeechThreshold: 0.6
        )

        do {
            let results = try await whisperKit.transcribe(
                audioPath: fileURL.path,
                decodeOptions: decodingOptions
            ) { progress in
                Task { @MainActor [weak self] in
                    self?.progressText = "Transcription de \(fileURL.lastPathComponent)… (fenêtre \(progress.windowId + 1))"
                }
                return true
            }

            let lines = results.flatMap(\.segments).map { segment in
                "[\(Self.formatTimestamp(segment.start))] : \(segment.text.trimmingCharacters(in: .whitespaces))"
            }

            let baseName = fileURL.deletingPathExtension().lastPathComponent
            let outputURL = OutputFileManager.txtURL(in: fileURL.deletingLastPathComponent(), baseName: baseName)
            try lines.joined(separator: "\n").write(to: outputURL, atomically: true, encoding: .utf8)

            lastOutputURL = outputURL
            progressText = "Terminé — \(lines.count) segments."
        } catch {
            lastError = "Erreur de transcription : \(error.localizedDescription)"
            progressText = ""
        }

        isTranscribing = false
    }

    private static func formatTimestamp(_ seconds: Float) -> String {
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return String(format: "%d:%02d:%02d", hours, minutes, secs)
    }
}
