import Foundation
import MLXLMCommon
import MLXLLM
import MLXHuggingFace
import HuggingFace
import Tokenizers

/// Standalone latency/quality probe for the on-device models — mirrors exactly the
/// generation parameters and model choices used in `LocalLLMCoordinator` — run from
/// Terminal to iterate on prompts/parameters/models in seconds, without rebuilding or
/// relaunching the full GUI app.
/// Usage: PraxisLLMBench [--model rapide|qualite] [maxTokens] [prompt…]
/// (defaults to qualite/Qwen2.5-7B and the subtask-proposal prompt, matching prior usage)

enum BenchModel: String {
    case rapide, qualite

    var displayName: String {
        self == .rapide ? "Qwen3-4B (rapide)" : "Qwen2.5-7B-Instruct-4bit (qualité)"
    }

    var configuration: ModelConfiguration {
        self == .rapide ? LLMRegistry.qwen3_4b_4bit : LLMRegistry.qwen2_5_7b
    }
}

let defaultPrompt = """
Tâche : "Dossier individuel"
Type : Rendu

Tu proposes un découpage en sous-tâches concrètes et chronométrées pour aider à réaliser une tâche. Chaque sous-tâche est une étape actionnable avec une durée réaliste en minutes — privilégie des blocs de 15 à 90 minutes, ni des micro-étapes de 5 minutes ni un seul bloc de plusieurs heures.

Réponds UNIQUEMENT en français, avec un JSON valide de cette forme exacte, sans texte autour, sans balises markdown :
{"subtasks": [{"title": "...", "estimatedMinutes": 30}]}
"""

var args = Array(CommandLine.arguments.dropFirst())
var model = BenchModel.qualite
if let modelFlagIndex = args.firstIndex(of: "--model"), args.indices.contains(modelFlagIndex + 1) {
    model = BenchModel(rawValue: args[modelFlagIndex + 1]) ?? .qualite
    args.removeSubrange(modelFlagIndex...(modelFlagIndex + 1))
}
let maxTokens = args.first.flatMap { Int($0) } ?? 600
if Int(args.first ?? "") != nil { args = Array(args.dropFirst()) }
let prompt = args.isEmpty ? defaultPrompt : args.joined(separator: " ")

print("Chargement du modèle \(model.displayName)…")
let loadStart = Date()
do {
    let container = try await #huggingFaceLoadModelContainer(configuration: model.configuration)
    print(String(format: "Modèle chargé en %.1fs", Date().timeIntervalSince(loadStart)))

    let session = ChatSession(
        container,
        generateParameters: GenerateParameters(maxTokens: maxTokens, temperature: 0.3, repetitionPenalty: 1.15)
    )

    // Qwen3 (rapide) reasons in a <think> block by default — measured 6.9s vs 1.6s for the
    // same JSON answer with/without this. Qwen2.5 (qualité) has no notion of the token.
    let finalPrompt = model == .rapide ? prompt + "\n/no_think" : prompt

    print("--- Prompt (maxTokens=\(maxTokens)) ---")
    print(finalPrompt)
    print("---")

    let genStart = Date()
    let response = try await session.respond(to: finalPrompt)
    let elapsed = Date().timeIntervalSince(genStart)

    print(String(format: "\nGénéré en %.1fs", elapsed))
    print("--- Réponse ---")
    print(response)
} catch {
    print("Erreur: \(error)")
    exit(1)
}
