import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var updateChecker: UpdateCheckCoordinator

    @State private var geminiKey: String = KeychainStore.get("gemini_api_key") ?? ""
    @State private var anthropicKey: String = KeychainStore.get("anthropic_api_key") ?? ""
    @State private var testResult: String?
    @State private var isTesting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Réglages IA")
                .font(.title3)

            VStack(alignment: .leading, spacing: 4) {
                Text("Clé API Gemini").font(.caption).foregroundStyle(.secondary)
                SecureField("AIza…", text: $geminiKey)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Clé API Anthropic (Claude)").font(.caption).foregroundStyle(.secondary)
                SecureField("sk-ant-…", text: $anthropicKey)
                    .textFieldStyle(.roundedBorder)
            }

            if let testResult {
                Text(testResult)
                    .font(.caption)
                    .foregroundStyle(testResult.hasPrefix("✓") ? .green : .red)
            }

            HStack {
                Button(isTesting ? "Test en cours…" : "Tester la connexion Gemini") {
                    testGemini()
                }
                .disabled(isTesting || geminiKey.isEmpty)

                Spacer()

                Button("Enregistrer") {
                    KeychainStore.set(geminiKey, forKey: "gemini_api_key")
                    KeychainStore.set(anthropicKey, forKey: "anthropic_api_key")
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }

            Divider()

            updateSection
        }
        .padding(20)
        .frame(width: 380)
    }

    private var updateSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Mise à jour").font(.caption).foregroundStyle(.secondary)

            Text("Version installée : \(updateChecker.currentVersion)")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            if updateChecker.updateAvailable, let version = updateChecker.latestVersion {
                Text("Nouvelle version disponible : \(version)")
                    .font(.caption)
                    .foregroundStyle(.green)
                if let url = updateChecker.latestReleaseURL {
                    Link("Télécharger sur GitHub", destination: url)
                        .font(.caption)
                }
            } else if let error = updateChecker.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
            } else if !updateChecker.isChecking {
                Text("À jour.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Button(updateChecker.isChecking ? "Vérification…" : "Vérifier maintenant") {
                Task { await updateChecker.checkForUpdates() }
            }
            .disabled(updateChecker.isChecking)
            .font(.caption)
        }
    }

    private func testGemini() {
        KeychainStore.set(geminiKey, forKey: "gemini_api_key")
        isTesting = true
        testResult = nil
        Task {
            defer { isTesting = false }
            do {
                _ = try await GeminiProvider().summarize(previousSummary: "", newContext: "Test de connexion.")
                testResult = "✓ Connexion Gemini réussie."
            } catch {
                testResult = "✗ \(error.localizedDescription)"
            }
        }
    }
}
