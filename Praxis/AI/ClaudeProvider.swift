import Foundation

struct ClaudeProvider: AIProvider {
    let name: String
    let model: String
    private let apiURL = URL(string: "https://api.anthropic.com/v1/messages")!
    private let anthropicVersion = "2023-06-01"

    private struct RequestBody: Encodable {
        struct Message: Encodable { let role: String; let content: String }
        let model: String
        let max_tokens: Int
        let system: String
        let messages: [Message]
    }

    private struct ResponseBody: Decodable {
        struct ContentBlock: Decodable { let type: String; let text: String? }
        let content: [ContentBlock]
    }

    func summarize(previousSummary: String, newContext: String) async throws -> String {
        try await call(
            system: "Tu es un assistant de réunion expert. Tu produis des résumés Markdown clairs, synthétiques et bien structurés.",
            user: AIPrompts.summarize(previousSummary: previousSummary, newContext: newContext)
        )
    }

    func ask(transcript: String, question: String) async throws -> String {
        try await call(
            system: "Tu es un assistant de réunion qui répond à des questions à partir d'une transcription. Réponses concises, factuelles, en Markdown.",
            user: AIPrompts.ask(transcript: transcript, question: question)
        )
    }

    private func call(system: String, user: String) async throws -> String {
        guard let apiKey = KeychainStore.get("anthropic_api_key"), !apiKey.isEmpty else {
            throw ProviderError.missingAPIKey(name)
        }

        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONEncoder().encode(RequestBody(
            model: model,
            max_tokens: 2048,
            system: system,
            messages: [.init(role: "user", content: user)]
        ))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw ProviderError.httpError(code, String(data: data, encoding: .utf8) ?? "")
        }

        do {
            let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
            let text = decoded.content.filter { $0.type == "text" }.compactMap(\.text).joined()
            guard !text.isEmpty else { throw ProviderError.unexpectedResponse("contenu vide") }
            return text
        } catch let error as ProviderError {
            throw error
        } catch {
            throw ProviderError.unexpectedResponse(error.localizedDescription)
        }
    }
}
