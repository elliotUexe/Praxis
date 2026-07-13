import Foundation

enum ProviderError: LocalizedError {
    case missingAPIKey(String)
    case httpError(Int, String)
    case unexpectedResponse(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            return "Clé API manquante pour \(provider). Renseignez-la dans les réglages."
        case .httpError(let code, let body):
            return "Erreur HTTP \(code) : \(body.prefix(200))"
        case .unexpectedResponse(let detail):
            return "Réponse inattendue : \(detail)"
        }
    }
}

protocol AIProvider {
    var name: String { get }
    func summarize(previousSummary: String, newContext: String) async throws -> String
    func ask(transcript: String, question: String) async throws -> String
}

enum AIProviderKind: String, CaseIterable, Identifiable {
    case gemini = "Gemini"
    case claudeSonnet = "Claude Sonnet"
    case claudeHaiku = "Claude Haiku"

    var id: String { rawValue }

    func makeProvider() -> AIProvider {
        switch self {
        case .gemini:
            return GeminiProvider()
        case .claudeSonnet:
            return ClaudeProvider(name: rawValue, model: "claude-sonnet-4-6")
        case .claudeHaiku:
            return ClaudeProvider(name: rawValue, model: "claude-haiku-4-5-20251001")
        }
    }

    /// Which Keychain entry backs this provider — `.claudeSonnet`/`.claudeHaiku` share the
    /// one Anthropic key.
    private var keychainKeyName: String {
        switch self {
        case .gemini: return "gemini_api_key"
        case .claudeSonnet, .claudeHaiku: return "anthropic_api_key"
        }
    }

    /// True only if a non-blank key is actually stored — used to decide whether the paid
    /// path is usable at all, so the app can fall back to the local LLM instead of just
    /// surfacing a "missing key" error.
    var hasStoredKey: Bool {
        guard let key = KeychainStore.get(keychainKeyName) else { return false }
        return !key.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// Same rolling-summary prompt contract as the Python app's SYSTEM_PROMPT_AI.
enum AIPrompts {
    static func summarize(previousSummary: String, newContext: String) -> String {
        """
        Tu es un assistant de réunion expert. Voici le contexte actuel :

        1. RÉSUMÉ PRÉCÉDENT (Ce qu'on sait déjà) :
        \(previousSummary.isEmpty ? "Aucun résumé." : previousSummary)

        2. NOUVEAUX ÉCHANGES (Ce qui vient d'être dit) :
        \(newContext)

        CONSIGNE : Mets à jour le résumé global en intégrant les nouvelles informations. \
        Structure ta réponse en Markdown propre. Sois synthétique.
        """
    }

    static func ask(transcript: String, question: String) -> String {
        let clipped = String(transcript.suffix(8000))
        return """
        Tu es un assistant de réunion. Voici la transcription en cours :

        \(clipped)

        Question : \(question)

        Réponds en Markdown, de façon concise et factuelle.
        """
    }
}
