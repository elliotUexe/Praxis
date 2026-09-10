import SwiftUI

/// 3 onglets natifs (IA / Vault / À propos) — remplace l'ancien `VStack` plat unique où
/// clés API, modèle local et mise à jour s'empilaient sans hiérarchie, par le handoff design.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var updateChecker: UpdateCheckCoordinator
    @EnvironmentObject private var aiSummary: AISummaryCoordinator

    @State private var geminiKey: String = KeychainStore.get("gemini_api_key") ?? ""
    @State private var anthropicKey: String = KeychainStore.get("anthropic_api_key") ?? ""
    @State private var testResult: String?
    @State private var isTesting = false

    @AppStorage("appAppearance") private var appearanceRaw = AppAppearance.auto.rawValue
    @AppStorage(TranscriptionLanguage.storageKey) private var languageRaw = TranscriptionLanguage.auto.rawValue

    @State private var inputDevice: AudioInputGain.Device?
    @State private var inputGain: Double = 0

    @AppStorage(TranscriptionThresholds.noSpeechKey)
    private var noSpeechThreshold = TranscriptionThresholds.defaultNoSpeech
    @AppStorage(TranscriptionThresholds.compressionRatioKey)
    private var compressionRatioThreshold = TranscriptionThresholds.defaultCompressionRatio

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                audioTab
                    .tabItem { Label("Audio", systemImage: "waveform") }
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

            appearanceSection

            Spacer(minLength: 0)
        }
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

    private var audioTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Langue des cours").font(.caption).foregroundStyle(.secondary)
                Picker("Langue", selection: $languageRaw) {
                    ForEach(TranscriptionLanguage.allCases) { language in
                        Text(language.displayName).tag(language.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                Text("Automatique détecte la langue à chaque fenêtre de 30 secondes. Forcer une langue est plus prévisible sur un cours mêlant les deux.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            inputGainSection

            Divider()

            thresholdSection

            Spacer(minLength: 0)
        }
        .onAppear(perform: loadInputDevice)
    }

    /// The device's own capture level, not a multiplier applied afterwards. Amplifying
    /// samples that are already recorded raises the lecturer and the room by the same
    /// amount and changes nothing for Whisper; turning the microphone up captures more of a
    /// quiet voice in the first place.
    @ViewBuilder
    private var inputGainSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Niveau d'entrée").font(.caption).foregroundStyle(.secondary)

            if let inputDevice {
                Text(inputDevice.name)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                if inputDevice.volume != nil, inputDevice.isSettable {
                    HStack(spacing: 8) {
                        Image(systemName: "mic")
                            .foregroundStyle(.secondary)
                        Slider(value: $inputGain, in: 0...1)
                            .onChange(of: inputGain) {
                                AudioInputGain.setVolume(Float(inputGain), on: inputDevice.id)
                            }
                        Text("\(Int(inputGain * 100)) %")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                    Text("C'est le même réglage que Réglages Système > Son > Entrée : le modifier ici le modifie partout.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Ce micro n'expose pas de réglage de niveau. Un iPhone utilisé comme micro, par exemple, gère son gain lui-même.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Aucune entrée audio détectée.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Button("Actualiser", systemImage: "arrow.clockwise", action: loadInputDevice)
                .font(.caption)
                .controlSize(.small)
        }
    }

    /// Left at Whisper's own defaults out of the box. They are calibrated for clean audio
    /// and they cost text in a noisy hall, but loosening them buys approximate text at the
    /// price of accuracy — a trade worth offering, not worth making on Pierre's behalf.
    private var thresholdSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Filtrage").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Valeurs par défaut") {
                    noSpeechThreshold = TranscriptionThresholds.defaultNoSpeech
                    compressionRatioThreshold = TranscriptionThresholds.defaultCompressionRatio
                }
                .font(.caption2)
                .controlSize(.small)
                .disabled(
                    noSpeechThreshold == TranscriptionThresholds.defaultNoSpeech
                        && compressionRatioThreshold == TranscriptionThresholds.defaultCompressionRatio
                )
            }

            thresholdSlider(
                title: "Seuil de silence",
                value: $noSpeechThreshold,
                range: TranscriptionThresholds.noSpeechRange,
                help: "Plus bas, une voix faible est moins souvent prise pour du silence."
            )

            thresholdSlider(
                title: "Seuil de répétition",
                value: $compressionRatioThreshold,
                range: TranscriptionThresholds.compressionRatioRange,
                help: "Plus haut, un passage hésitant est moins souvent jeté comme hallucination."
            )
        }
    }

    private func thresholdSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        help: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption2)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
            Text(help)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func loadInputDevice() {
        inputDevice = AudioInputGain.defaultInputDevice()
        inputGain = Double(inputDevice?.volume ?? 0)
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
