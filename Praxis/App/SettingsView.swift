import SwiftUI
import AppKit

/// The settings sheet's sections.
///
/// Drawn by hand rather than with `TabView`: on macOS 27 a `TabView` inside a sheet lays
/// its five tab labels on top of one another in a single narrow box ("NÀLA…" over the
/// Audio tab), and nothing in its public API sizes that bar.
private enum SettingsTab: String, CaseIterable, Identifiable {
    case audio, ia, vault, mcp, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .audio: return "Audio"
        case .ia: return "IA"
        case .vault: return "Vault"
        case .mcp: return "MCP"
        case .about: return "À propos"
        }
    }

    var systemImage: String {
        switch self {
        case .audio: return "waveform"
        case .ia: return "sparkles"
        case .vault: return "folder"
        case .mcp: return "point.3.connected.trianglepath.dotted"
        case .about: return "info.circle"
        }
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var updateChecker: UpdateCheckCoordinator
    @EnvironmentObject private var aiSummary: AISummaryCoordinator
    @EnvironmentObject private var session: AppSessionStore
    @EnvironmentObject private var taskStore: TaskStoreCoordinator
    @EnvironmentObject private var mcpServer: MCPServerCoordinator
    @EnvironmentObject private var transcription: LiveTranscriptionCoordinator
    @EnvironmentObject private var importCoordinator: ImportTranscriptionCoordinator

    @State private var selectedTab: SettingsTab = .audio

    @State private var geminiKey: String = KeychainStore.get("gemini_api_key") ?? ""
    @State private var anthropicKey: String = KeychainStore.get("anthropic_api_key") ?? ""
    @State private var testResult: String?
    @State private var isTesting = false

    @AppStorage("appAppearance") private var appearanceRaw = AppAppearance.auto.rawValue
    @AppStorage(TranscriptionLanguage.storageKey) private var languageRaw = TranscriptionLanguage.auto.rawValue
    @AppStorage(TranscriptionEngine.storageKey) private var engineRaw = TranscriptionEngine.whisper.rawValue

    @State private var isVaultSetupPresented = false
    @State private var rollbackVersion = ""
    @State private var mcpEnabled = MCPServerCoordinator.isEnabled
    @State private var mcpCopied = false
    @State private var inputDevice: AudioInputGain.Device?
    @State private var inputGain: Double = 0

    @AppStorage(TranscriptionThresholds.noSpeechKey)
    private var noSpeechThreshold = TranscriptionThresholds.defaultNoSpeech
    @AppStorage(TranscriptionThresholds.compressionRatioKey)
    private var compressionRatioThreshold = TranscriptionThresholds.defaultCompressionRatio

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()

            selectedContent
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // Sized for the Audio tab, the tallest: engine + language + input level + two
            // thresholds. The other tabs sit at the top of the same frame instead of making
            // the sheet jump in height when switching.
            .frame(width: 540, height: 600)

            Divider()
            HStack {
                Spacer()
                Button("Fermer") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(SettingsTab.allCases) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 15))
                            .frame(height: 18)
                        Text(tab.title)
                            .font(.caption)
                    }
                    .frame(width: 72, height: 44)
                    .contentShape(Rectangle())
                    .foregroundStyle(selectedTab == tab ? Color.praxisAccent : Color.secondary)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(selectedTab == tab ? Color.praxisAccent.opacity(0.14) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var selectedContent: some View {
        switch selectedTab {
        case .audio: audioTab
        case .ia: iaTab
        case .vault: vaultTab
        case .mcp: mcpTab
        case .about: aboutTab
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
        ScrollView {
            audioTabContent
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var selectedEngine: TranscriptionEngine {
        TranscriptionEngine(rawValue: engineRaw) ?? .whisper
    }

    private var audioTabContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            engineSection

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Langue des cours").font(.caption).foregroundStyle(.secondary)
                Picker("Langue", selection: $languageRaw) {
                    ForEach(TranscriptionLanguage.allCases) { language in
                        Text(language.displayName).tag(language.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                Text(selectedEngine == .apple
                     ? "Apple ne détecte pas la langue : Automatique utilise celle du Mac, ou le français si Apple ne la reconnaît pas. Pour un cours en anglais, choisir Anglais."
                     : "Automatique détecte la langue à chaque fenêtre de 30 secondes. Forcer une langue est plus prévisible sur un cours mêlant les deux.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Apple checks its language asset per locale: a new language may need one.
            .onChange(of: languageRaw) {
                guard selectedEngine == .apple,
                      !transcription.isSessionActive, !importCoordinator.isTranscribing,
                      transcription.isReady || importCoordinator.isReady else { return }
                Task {
                    await transcription.unloadModels()
                    importCoordinator.unloadModel()
                    await transcription.prepare()
                    await importCoordinator.prepare()
                }
            }

            Divider()

            inputGainSection

            Divider()

            thresholdSection
                .disabled(selectedEngine == .apple)
                .opacity(selectedEngine == .apple ? 0.5 : 1)

            Spacer(minLength: 0)
        }
        .onAppear(perform: loadInputDevice)
    }

    /// Applies to the next recording and the next import. Refused during a session
    /// rather than swapping the recogniser underneath it.
    private var engineSection: some View {
        let busy = transcription.isSessionActive || importCoordinator.isTranscribing
        return VStack(alignment: .leading, spacing: 4) {
            Text("Moteur de transcription").font(.caption).foregroundStyle(.secondary)
            Picker("Moteur", selection: $engineRaw) {
                ForEach(TranscriptionEngine.allCases) { engine in
                    Text(engine.displayName).tag(engine.rawValue)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .disabled(busy || !TranscriptionEngine.isAppleAvailable)
            .onChange(of: engineRaw) {
                Task {
                    await transcription.applyEngineSetting()
                    await importCoordinator.applyEngineSetting()
                }
            }
            Text(engineHelp(busy: busy))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func engineHelp(busy: Bool) -> String {
        if !TranscriptionEngine.isAppleAvailable {
            return "La reconnaissance Apple demande macOS 26 ou plus récent : Whisper est utilisé."
        }
        if busy {
            return "Changement impossible pendant un enregistrement ou un import."
        }
        switch selectedEngine {
        case .whisper:
            return "Whisper turbo en direct, chaque passage repris par large-v3, large-v3 pour l'import. Plusieurs Go en mémoire ; peut sauter un passage entier."
        case .apple:
            return "Reconnaissance d'Apple intégrée au Mac, en direct comme à l'import. Presque rien en mémoire dans Praxis et bien plus économe ; ne saute rien, mais se trompe parfois de mot. Les seuils de filtrage ne s'appliquent pas."
        }
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
        VStack(alignment: .leading, spacing: 10) {
            Text("Dossier de cours").font(.caption).foregroundStyle(.secondary)
            Text(VaultSettings.root.path)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            Text("Profondeur des matières : \(VaultSettings.courseDepth)")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Button("Changer le dossier…") { isVaultSetupPresented = true }
                .controlSize(.small)

            Text("Praxis lit vos matières dans l'arborescence de ce dossier. Changer de dossier ne déplace rien : les matières déjà connues sont retrouvées par leur marqueur.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .sheet(isPresented: $isVaultSetupPresented) {
            VaultSetupView(isInitialSetup: false) {
                session.reloadCourses()
                taskStore.migrateCourses()
            }
        }
    }

    /// Same shape as the Obsidian entry already in Claude Desktop's configuration, so the
    /// two read as one family: an in-app server on a loopback port, a bearer token, and
    /// `mcp-remote` bridging the client's stdio to it.
    private var mcpTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Serveur MCP", isOn: $mcpEnabled)
                .onChange(of: mcpEnabled) {
                    MCPServerCoordinator.isEnabled = mcpEnabled
                    Task {
                        if mcpEnabled { await mcpServer.start(taskStore: taskStore) } else { await mcpServer.stop() }
                    }
                }
            Text("Permet à Claude (Cowork, Claude Code) de lire et créer des tâches directement dans Praxis. Local à cette machine uniquement.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Circle()
                    .fill(mcpServer.isRunning ? Color.green : Color.secondary)
                    .frame(width: 7, height: 7)
                Text(mcpServer.isRunning ? "En écoute sur \(MCPServerCoordinator.endpointURL)" : "Arrêté")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if mcpServer.isRunning {
                    Text("· \(mcpServer.requestCount) requête\(mcpServer.requestCount > 1 ? "s" : "")")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            if let error = mcpServer.lastError {
                Text(error).font(.caption2).foregroundStyle(.red)
            }

            Divider()

            Text("Configuration Claude Desktop").font(.caption).foregroundStyle(.secondary)
            Text("À ajouter dans mcpServers de claude_desktop_config.json, à côté de l'entrée obsidian.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(MCPServerCoordinator.claudeDesktopConfiguration)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 120)
            .padding(6)
            .background(Color.gray.opacity(0.08))
            .cornerRadius(6)

            HStack {
                Button(mcpCopied ? "Copié" : "Copier la configuration") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(MCPServerCoordinator.claudeDesktopConfiguration, forType: .string)
                    mcpCopied = true
                }
                .controlSize(.small)
                Spacer()
                Button("Régénérer le jeton") {
                    mcpServer.regenerateToken()
                    mcpCopied = false
                    Task { await mcpServer.restart(taskStore: taskStore) }
                }
                .controlSize(.small)
                .help("Invalide l'ancien jeton : la configuration côté Claude devra être mise à jour.")
            }

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


    /// Installing any published version, not only the newest.
    ///
    /// The warning is not decoration. Going back replaces the application, not the
    /// database: a build older than a schema change may refuse to open a store that has
    /// already been migrated, and `TaskStoreCoordinator` treats that as fatal. Praxis's own
    /// migrations only ever add fields, and copy the store aside first, precisely so this
    /// stays a way out rather than a trap — but a version far enough back is still a risk.
    @ViewBuilder
    private var versionRollbackSection: some View {
        if updateChecker.availableVersions.count > 1 {
            Divider()
            Text("Revenir à une version").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Picker("Version", selection: $rollbackVersion) {
                    Text("Choisir…").tag("")
                    ForEach(updateChecker.availableVersions, id: \.version) { entry in
                        Text(entry.version + (entry.version == updateChecker.currentVersion ? " (installée)" : ""))
                            .tag(entry.version)
                    }
                }
                .labelsHidden()
                Button("Installer") {
                    Task { await updateChecker.install(version: rollbackVersion) }
                }
                .controlSize(.small)
                .disabled(rollbackVersion.isEmpty || rollbackVersion == updateChecker.currentVersion || updateChecker.isUpdating)
            }
            Text("Une version antérieure peut ne pas savoir relire des données déjà migrées. Une copie de la base est faite avant chaque migration, dans Application Support/Praxis/Backups.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
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

            versionRollbackSection

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
