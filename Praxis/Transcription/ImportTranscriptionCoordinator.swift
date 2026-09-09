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

    /// Frees the import model. Refuses mid-transcription rather than pulling the model out
    /// from under a running job; `prepare()` reloads from the on-disk cache on demand.
    func unloadModel() {
        guard !isTranscribing else {
            lastError = "Impossible de décharger pendant une transcription."
            return
        }
        whisperKit = nil
        isReady = false
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

        let decodingOptions = TranscriptionDefaults.decodingOptions()

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

            let lines = results.flatMap(\.segments).map {
                OutputFileManager.transcriptLine(start: $0.start, text: $0.text)
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

}
