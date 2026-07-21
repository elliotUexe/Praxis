import Foundation
import MLXLMCommon
import MLXLLM
import MLXHuggingFace
import HuggingFace
import Tokenizers

/// Standalone latency/quality probe for the on-device Qwen2.5-7B model, mirroring exactly
/// the generation parameters used in `LocalLLMCoordinator` — run from Terminal to iterate
/// on prompts/parameters in seconds, without rebuilding or relaunching the full GUI app.
/// Usage: PraxisLLMBench [maxTokens] [prompt…]  (defaults to the subtask-proposal prompt)

let defaultPrompt = """
Tâche : "Dossier individuel"
Type : Rendu

Tu proposes un découpage en sous-tâches concrètes et chronométrées pour aider à réaliser une tâche. Chaque sous-tâche est une étape actionnable avec une durée réaliste en minutes — privilégie des blocs de 15 à 90 minutes, ni des micro-étapes de 5 minutes ni un seul bloc de plusieurs heures.

Réponds UNIQUEMENT en français, avec un JSON valide de cette forme exacte, sans texte autour, sans balises markdown :
{"subtasks": [{"title": "...", "estimatedMinutes": 30}]}
"""

var args = CommandLine.arguments.dropFirst()
let maxTokens = args.first.flatMap { Int($0) } ?? 600
if Int(args.first ?? "") != nil { args = args.dropFirst() }
let prompt = args.isEmpty ? defaultPrompt : args.joined(separator: " ")

print("Chargement du modèle Qwen2.5-7B-Instruct-4bit…")
let loadStart = Date()
do {
    let container = try await #huggingFaceLoadModelContainer(configuration: LLMRegistry.qwen2_5_7b)
    print(String(format: "Modèle chargé en %.1fs", Date().timeIntervalSince(loadStart)))

    let session = ChatSession(
        container,
        generateParameters: GenerateParameters(maxTokens: maxTokens, temperature: 0.3, repetitionPenalty: 1.15)
    )

    print("--- Prompt (maxTokens=\(maxTokens)) ---")
    print(prompt)
    print("---")

    let genStart = Date()
    let response = try await session.respond(to: prompt)
    let elapsed = Date().timeIntervalSince(genStart)

    print(String(format: "\nGénéré en %.1fs", elapsed))
    print("--- Réponse ---")
    print(response)
} catch {
    print("Erreur: \(error)")
    exit(1)
}
