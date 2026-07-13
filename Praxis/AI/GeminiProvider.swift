import Foundation

struct GeminiProvider: AIProvider {
    let name = "Gemini"
    private let apiURL = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent")!

    private struct RequestBody: Encodable {
        struct Content: Encodable {
            struct Part: Encodable { let text: String }
            let parts: [Part]
        }
        let contents: [Content]
    }

    private struct ResponseBody: Decodable {
        struct Candidate: Decodable {
            struct Content: Decodable {
                struct Part: Decodable { let text: String }
                let parts: [Part]
            }
            let content: Content
        }
        let candidates: [Candidate]
    }

    func summarize(previousSummary: String, newContext: String) async throws -> String {
        try await call(prompt: AIPrompts.summarize(previousSummary: previousSummary, newContext: newContext))
    }

    func ask(transcript: String, question: String) async throws -> String {
        try await call(prompt: AIPrompts.ask(transcript: transcript, question: question))
    }

    private func call(prompt: String) async throws -> String {
        guard let apiKey = KeychainStore.get("gemini_api_key"), !apiKey.isEmpty else {
            throw ProviderError.missingAPIKey(name)
        }

        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-goog-api-key")
        request.httpBody = try JSONEncoder().encode(RequestBody(contents: [.init(parts: [.init(text: prompt)])]))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw ProviderError.httpError(code, String(data: data, encoding: .utf8) ?? "")
        }

        do {
            let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
            guard let text = decoded.candidates.first?.content.parts.first?.text else {
                throw ProviderError.unexpectedResponse("candidats vides")
            }
            return text
        } catch {
            throw ProviderError.unexpectedResponse(error.localizedDescription)
        }
    }
}
