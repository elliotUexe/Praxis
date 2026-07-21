import SwiftUI

/// "Résumés" section of the Phase 2 shell — reworked so there is one clear active summary
/// flow instead of two parallel blocks. Without a valid Gemini/Claude key
/// (`AIProviderKind.hasStoredKey`), everything — rolling summary AND Q&A — runs on the
/// local Qwen2.5-7B model automatically; with a valid key, the paid provider is the
/// default flow and the local model becomes an optional side-by-side comparison.
struct SummariesSectionView: View {
    @EnvironmentObject private var aiSummary: AISummaryCoordinator
    @EnvironmentObject private var localLLM: LocalLLMCoordinator

    @State private var questionText: String = ""

    private var usingFallback: Bool { !aiSummary.selectedProvider.hasStoredKey }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Notes IA")
                .font(.title3)

            statusBanner

            if usingFallback {
                if localLLM.isUserDisabled {
                    Text("IA locale désactivée (case à cocher dans Enregistrement) — aucune clé API payante configurée non plus, donc aucun résumé ne sera généré.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    localSummaryBlock(primary: true)
                }
            } else {
                paidSummaryBlock

                Toggle("Comparer aussi avec le résumé local (Qwen2.5-7B)", isOn: Binding(
                    get: { localLLM.isEnabled },
                    set: { localLLM.setEnabled($0) }
                ))
                .font(.caption)
                .disabled(localLLM.isUserDisabled)

                if localLLM.isUserDisabled {
                    Text("IA locale désactivée (case à cocher dans Enregistrement).")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else if localLLM.isEnabled {
                    localSummaryBlock(primary: false)
                }
            }

            Divider()

            Text("Question").font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Poser une question sur la transcription…", text: $questionText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(sendQuestion)
                Button("Envoyer") { sendQuestion() }
                    .disabled(questionText.isEmpty || isAnswering || (usingFallback && localLLM.isUserDisabled))
            }

            ScrollView {
                Text(answerMarkdown)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(Color.gray.opacity(0.05))
            .cornerRadius(8)
            .frame(minHeight: 80)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var statusBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: usingFallback ? "cpu" : "cloud")
                .foregroundStyle(.secondary)
            Text(usingFallback ? "Résumé : Qwen2.5-7B (local, aucune clé API)" : "Résumé : \(aiSummary.selectedProvider.rawValue)")
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

    private func localSummaryBlock(primary: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !primary {
                Text("Résumé local (Qwen2.5-7B, gratuit)").font(.caption).foregroundStyle(.secondary)
            } else if !aiSummary.selectedProvider.hasStoredKey {
                Text("Ajoutez une clé API dans Réglages pour utiliser Gemini/Claude.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if localLLM.isLoadingModel {
                ProgressView("Téléchargement/chargement du modèle local (une seule fois, plusieurs Go)…")
                    .font(.caption)
            } else if localLLM.isProcessing {
                ProgressView("Analyse en cours…")
                    .font(.caption)
            }

            if let error = localLLM.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            ScrollView {
                Text(localLLM.rollingSummaryMarkdown.isEmpty ? "Le résumé apparaîtra ici pendant l'enregistrement." : localLLM.rollingSummaryMarkdown)
                    .font(.callout)
                    .foregroundStyle(localLLM.rollingSummaryMarkdown.isEmpty ? .tertiary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(Color.blue.opacity(0.06))
            .cornerRadius(8)
            .frame(minHeight: primary ? 120 : 100)
        }
    }

    // MARK: - Unified Q&A (routes to whichever engine is actually active)

    private var isAnswering: Bool { usingFallback ? localLLM.isAnswering : aiSummary.isAnswering }
    private var answerMarkdown: String { usingFallback ? localLLM.answerMarkdown : aiSummary.answerMarkdown }

    private func sendQuestion() {
        guard !questionText.isEmpty else { return }
        if usingFallback {
            localLLM.question = questionText
            localLLM.askQuestion()
        } else {
            aiSummary.question = questionText
            aiSummary.askQuestion()
        }
        questionText = ""
    }
}
