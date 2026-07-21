import SwiftUI

/// 3 onglets natifs (IA / Vault / À propos) — remplace l'ancien `VStack` plat unique où
/// clés API, modèle local et mise à jour s'empilaient sans hiérarchie, par le handoff design.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var updateChecker: UpdateCheckCoordinator
    @EnvironmentObject private var localLLM: LocalLLMCoordinator
    @EnvironmentObject private var aiSummary: AISummaryCoordinator

    @State private var geminiKey: String = KeychainStore.get("gemini_api_key") ?? ""
    @State private var anthropicKey: String = KeychainStore.get("anthropic_api_key") ?? ""
    @State private var testResult: String?
    @State private var isTesting = false

    @AppStorage("appAppearance") private var appearanceRaw = AppAppearance.auto.rawValue

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                iaTab
                    .tabItem { Label("IA", systemImage: "sparkles") }
                vaultTab
                    .tabItem { Label("Vault", systemImage: "folder") }
                aboutTab
                    .tabItem { Label("À propos", systemImage: "info.circle") }
            }
            .padding(20)
            .frame(width: 380, height: 440)

            Divider()
            HStack {
                Spacer()
                Button("Fermer") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
    }

    private var iaTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Provider actif partout : \(aiSummary.selectedProvider.rawValue)")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Clé API Gemini").font(.caption).foregroundStyle(.secondary)
                SecureField("AIza…", text: $geminiKey)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: geminiKey) { KeychainStore.set(geminiKey, forKey: "gemini_api_key") }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Clé API Anthropic (Claude)").font(.caption).foregroundStyle(.secondary)
                SecureField("sk-ant-…", text: $anthropicKey)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: anthropicKey) { KeychainStore.set(anthropicKey, forKey: "anthropic_api_key") }
            }

            if let testResult {
                Text(testResult)
                    .font(.caption)
                    .foregroundStyle(testResult.hasPrefix("✓") ? .green : .red)
            }

            Button(isTesting ? "Test en cours…" : "Tester la connexion Gemini") {
                testGemini()
            }
            .disabled(isTesting || geminiKey.isEmpty)
            .font(.caption)

            Divider()

            localLLMEnableSection
            localModelSection

            Divider()

            appearanceSection

            Spacer(minLength: 0)
        }
    }

    /// A standalone control — distinct from `localModelSection` (Rapide/Qualité, a
    /// different setting) and from the read-only status badge in `RecordingSectionView`,
    /// which no longer has an interactive toggle of its own per the design handoff
    /// ("pas une Toggle SwiftUI pleine largeur ... la vraie bascule reste dans Réglages").
    private var localLLMEnableSection: some View {
        Toggle("IA locale activée", isOn: Binding(
            get: { !localLLM.isUserDisabled },
            set: { localLLM.isUserDisabled = !$0 }
        ))
        .font(.callout)
    }

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Apparence").font(.caption).foregroundStyle(.secondary)
            Picker("Apparence", selection: $appearanceRaw) {
                ForEach(AppAppearance.allCases) { appearance in
                    Text(appearance.displayName).tag(appearance.rawValue)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
    }

    private var vaultTab: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Vault Obsidian").font(.caption).foregroundStyle(.secondary)
            Text(VaultPaths.root.path)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private var aboutTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Praxis").font(.title3)
            updateSection
            Spacer(minLength: 0)
        }
    }

    private var localModelSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Modèle IA local").font(.caption).foregroundStyle(.secondary)
            Picker("Modèle", selection: $localLLM.selectedModel) {
                ForEach(LocalModelChoice.allCases) { choice in
                    Text(choice.displayName).tag(choice)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            Text("Le premier usage d'un nouveau modèle déclenche un téléchargement de plusieurs Go.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var updateSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Mise à jour").font(.caption).foregroundStyle(.secondary)

            Text("Version installée : \(updateChecker.currentVersion)")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            if updateChecker.isUpdating {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(updateChecker.updateStatusText ?? "Mise à jour…")
                        .font(.caption)
                }
            } else if updateChecker.updateAvailable, let version = updateChecker.latestVersion {
                Text("Nouvelle version disponible : \(version) — installation automatique en cours au prochain lancement.")
                    .font(.caption)
                    .foregroundStyle(.green)
                HStack {
                    Button("Installer maintenant") {
                        Task { await updateChecker.downloadAndInstallUpdate() }
                    }
                    .font(.caption)
                    .disabled(updateChecker.latestDMGURL == nil)

                    if let url = updateChecker.latestReleaseURL {
                        Link("Voir sur GitHub", destination: url)
                            .font(.caption)
                    }
                }
            } else if updateChecker.noReleasePublished {
                Text("Aucune release publiée pour l'instant.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
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
            .disabled(updateChecker.isChecking || updateChecker.isUpdating)
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
