import Foundation
import WhisperKit

@main
struct SmokeTest {
    static func main() async {
        guard CommandLine.arguments.count > 1 else {
            print("Usage: PraxisSmokeTest <chemin_wav>")
            exit(1)
        }
        let audioPath = CommandLine.arguments[1]

        do {
            print("Chargement de WhisperKit (modèle tiny)…")
            let pipe = try await WhisperKit(WhisperKitConfig(model: "tiny"))

            print("Transcription de \(audioPath)…")
            let results = try await pipe.transcribe(audioPath: audioPath)
            let text = results.map(\.text).joined(separator: " ")

            print("--- Résultat ---")
            print(text.isEmpty ? "(vide)" : text)
        } catch {
            print("Erreur: \(error)")
            exit(1)
        }
    }
}
