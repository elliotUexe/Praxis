import SwiftUI

/// "Résumé" tab inside Enregistrement. The local-model fallback that used to cover this
/// when no API key was set is disconnected (see `LocalLLMCoordinator.isAvailable`), so
/// without a Gemini/Claude key there is no summary and no Q&A at all — the view says so
/// plainly rather than showing controls that can't do anything.
struct SummariesSectionView: View {
    @EnvironmentObject private var aiSummary: AISummaryCoordinator

    @State private var questionText: String = ""

    private var usingFallback: Bool { !aiSummary.selectedProvider.hasStoredKey }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Notes IA")
                .font(.title3)

            statusBanner

            if usingFallback {
                Text("Aucune clé API configurée. Le résumé et les questions nécessitent une clé Gemini ou Claude, à renseigner dans Réglages. La transcription, elle, fonctionne normalement.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                paidSummaryBlock

                Divider()

                Text("Question").font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("Poser une question sur la transcription…", text: $questionText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(sendQuestion)
                    Button("Envoyer") { sendQuestion() }
                        .disabled(questionText.isEmpty || aiSummary.isAnswering)
                }

                ScrollView {
                    Text(aiSummary.answerMarkdown)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .background(Color.gray.opacity(0.05))
                .cornerRadius(8)
                .frame(minHeight: 80)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var statusBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: usingFallback ? "exclamationmark.circle" : "cloud")
                .foregroundStyle(.secondary)
            Text(usingFallback ? "Résumé : indisponible (aucune clé API)" : "Résumé : \(aiSummary.selectedProvider.rawValue)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var paidSummaryBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Provider", selection: $aiSummary.selectedProvider) {
                ForEach(AIProviderKind.allCases) { provider in
                    Text(provider.rawValue).tag(provider)
                }
            }
            .labelsHidden()

            Picker("Fréquence", selection: $aiSummary.frequency) {
                ForEach(SummaryFrequency.allCases) { freq in
                    Text(freq.rawValue).tag(freq)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                if aiSummary.isSummarizing {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("⚡ Actualiser") { aiSummary.refreshNow() }
            }

            if let error = aiSummary.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            ScrollView {
                Text(aiSummary.summaryMarkdown.isEmpty ? "Le résumé apparaîtra ici pendant l'enregistrement." : aiSummary.summaryMarkdown)
                    .font(.callout)
                    .foregroundStyle(aiSummary.summaryMarkdown.isEmpty ? .tertiary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(Color.gray.opacity(0.08))
            .cornerRadius(8)
            .frame(minHeight: 120)
        }
    }



    private func sendQuestion() {
        guard !questionText.isEmpty, !usingFallback else { return }
        aiSummary.question = questionText
        aiSummary.askQuestion()
        questionText = ""
    }
}
