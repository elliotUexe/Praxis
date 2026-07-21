import SwiftUI
import UniformTypeIdentifiers

/// "Enregistrement" section of the Phase 2 shell — extracted verbatim (behavior-preserving)
/// from ContentView's old fixed-size `recordingColumn`, so it can live inside the new
/// resizable/full-screen `NavigationSplitView`.
struct RecordingSectionView: View {
    @EnvironmentObject private var session: AppSessionStore
    @EnvironmentObject private var transcription: LiveTranscriptionCoordinator
    @EnvironmentObject private var importCoordinator: ImportTranscriptionCoordinator
    @EnvironmentObject private var aiSummary: AISummaryCoordinator
    @EnvironmentObject private var taskStore: TaskStoreCoordinator
    @EnvironmentObject private var localLLM: LocalLLMCoordinator

    @State private var isFileImporterPresented = false
    @State private var isDropTargeted = false
    @State private var selectedTab: RecordingTab = .transcription

    private enum RecordingTab: String, CaseIterable {
        case transcription = "Transcription"
        case resume = "Résumé"
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 32))
            Text("Praxis")
                .font(.title2)
            Text(stateLabel)
                .foregroundStyle(.secondary)

            if session.recordingState == .recording || session.recordingState == .paused {
                chronoView
            }

            courseDestinationRow
            localLLMStatusBadge

            if let currentURL = session.currentRecordingURL {
                Text(currentURL.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if let error = session.lastError ?? transcription.lastError ?? importCoordinator.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 12) {
                Button(session.recordingState == .idle ? "Démarrer" : "Arrêter") {
                    if session.recordingState == .idle {
                        Task {
                            guard let outputURL = await session.beginRecordingSession() else { return }
                            await transcription.start(outputURL: outputURL)
                            let transcriptProvider: () -> String = { [weak transcription] in
                                transcription?.displaySegments.map(\.text).joined(separator: " ") ?? ""
                            }
                            // No valid key for the selected paid provider → everything
                            // (summary + Q&A) runs on the local model instead, not just
                            // the extraction that already always ran locally.
                            let hasKey = aiSummary.selectedProvider.hasStoredKey
                            if hasKey {
                                aiSummary.startSession(
                                    outputFolder: outputURL.deletingLastPathComponent(),
                                    transcriptProvider: transcriptProvider
                                )
                            } else {
                                localLLM.setEnabled(true)
                            }
                            localLLM.startSession(
                                taskStore: taskStore,
                                courseVaultPath: session.destinationCourseVaultPath,
                                sourceLabel: outputURL.deletingPathExtension().lastPathComponent,
                                transcriptProvider: transcriptProvider
                            )
                        }
                    } else {
                        session.stopRecording()
                        Task { await transcription.stop() }
                        aiSummary.stopSession()
                        localLLM.stopSession()
                    }
                }
                .disabled(!transcription.isReady && session.recordingState == .idle)

                Button(session.recordingState == .paused ? "Reprendre" : "Pause") {
                    if session.recordingState == .paused {
                        session.resumeRecording()
                        transcription.resume()
                    } else {
                        session.pauseRecording()
                        transcription.pause()
                    }
                }
                .disabled(session.recordingState == .idle)
            }

            if transcription.isLoadingModel {
                ProgressView("Chargement des modèles (rapide + raffinement)…")
                    .font(.caption)
            }

            // The former standalone "Résumés" sidebar section now lives here as a second
            // tab — eliminates the aller-retour between Enregistrement and Résumés during
            // a live session. Reuses SummariesSectionView's body as-is rather than
            // duplicating its logic; environment objects (aiSummary, localLLM) are
            // inherited the same way RecordingSectionView's own already are, no explicit
            // re-injection needed since this isn't crossing a `.sheet()` boundary.
            Picker("", selection: $selectedTab) {
                ForEach(RecordingTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch selectedTab {
            case .transcription:
                transcriptionScrollView
            case .resume:
                SummariesSectionView()
            }

            Divider()

            VStack(spacing: 6) {
                Text("Importer un enregistrement")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Choisir un fichier…") {
                    isFileImporterPresented = true
                }
                .disabled(!importCoordinator.isReady || importCoordinator.isTranscribing)

                if importCoordinator.isLoadingModel {
                    ProgressView("Chargement du modèle d'import…")
                        .font(.caption)
                } else if importCoordinator.isTranscribing {
                    ProgressView(importCoordinator.progressText)
                        .font(.caption)
                } else if let outputURL = importCoordinator.lastOutputURL {
                    Text("Transcrit → \(outputURL.lastPathComponent)")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(8)
            .background(isDropTargeted ? Color.accentColor.opacity(0.15) : Color.gray.opacity(0.05))
            .cornerRadius(8)
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers: providers)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.audio, .mpeg4Audio, .wav],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                Task { await importCoordinator.transcribe(fileURL: url) }
            }
        }
        .onChange(of: importCoordinator.lastOutputURL) { _, newValue in
            guard let newValue else { return }
            Task { await processImportedTranscript(at: newValue) }
        }
    }

    /// Phase 5's Import hook: runs the same local-LLM extraction/summary the live path
    /// uses, but as one batch pass over the finished transcript rather than a timer.
    private func processImportedTranscript(at url: URL) async {
        guard localLLM.isEnabled, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        await localLLM.processFullTranscript(
            text,
            taskStore: taskStore,
            courseVaultPath: VaultPaths.courseVaultPath(fromFileURL: url),
            sourceLabel: url.deletingPathExtension().lastPathComponent
        )
    }

    private var destinationLabel: String {
        if let coursePath = session.destinationCourseVaultPath {
            return VaultPaths.courseDisplayName(fromVaultPath: coursePath)
        }
        if let customFolder = session.customDestinationFolder {
            return customFolder.lastPathComponent
        }
        return "Aucun cours détecté"
    }

    /// Cascade Année → Pôle → Cours, plus une sortie "Autre dossier…" pour enregistrer
    /// complètement ailleurs, hors du mapping de cours (tous les enregistrements ne sont
    /// pas un cours d'une UE connue).
    private var courseDestinationRow: some View {
        HStack(spacing: 4) {
            Image(systemName: "book.closed")
                .foregroundStyle(.secondary)
            Text(destinationLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            Menu("Changer") {
                ForEach(CourseDirectoryScanner.years, id: \.self) { year in
                    let coursesForYear = session.availableCourses.filter { $0.year == year }
                    if !coursesForYear.isEmpty {
                        Menu(year) {
                            ForEach(CourseDirectoryScanner.poles, id: \.self) { pole in
                                let coursesForPole = coursesForYear.filter { $0.pole == pole }
                                if !coursesForPole.isEmpty {
                                    Menu(pole) {
                                        ForEach(coursesForPole) { course in
                                            Button(course.displayName) {
                                                session.overrideDestination(toCourseVaultPath: course.vaultPath)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                Divider()
                Button("Autre dossier…") {
                    session.pickCustomDestination()
                }
            }
            .font(.caption)
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    /// Read-only status badge, not an interactive control — per the design handoff, the
    /// real on/off switch lives in Réglages (`SettingsView.localLLMEnableSection`) as its
    /// own standalone button, distinct from this recording-view status indicator.
    private var localLLMStatusBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(localLLMStatusColor)
                .frame(width: 6, height: 6)
            Text("IA locale \(localLLMStatusText)")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
    }

    private var localLLMStatusText: String {
        if localLLM.isUserDisabled { return "désactivée" }
        if localLLM.isModelLoaded { return "en mémoire" }
        if localLLM.isLoadingModel { return "chargement…" }
        return "déchargée"
    }

    private var localLLMStatusColor: Color {
        if localLLM.isUserDisabled { return .gray }
        if localLLM.isModelLoaded { return .green }
        if localLLM.isLoadingModel { return .orange }
        return .secondary
    }

    private var transcriptionScrollView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(transcription.displaySegments) { segment in
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(segment.text)
                            .foregroundStyle(.primary)
                        if !segment.isRefined {
                            Image(systemName: "ellipsis.circle")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .help("En attente de raffinement")
                        }
                    }
                }
                if !transcription.unconfirmedText.isEmpty {
                    Text(transcription.unconfirmedText)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
        .frame(minHeight: 150)
        .frame(maxHeight: .infinity)
        .background(Color.gray.opacity(0.08))
        .cornerRadius(8)
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in
                await importCoordinator.transcribe(fileURL: url)
            }
        }
        return true
    }

    /// State label only — no longer embeds the elapsed time as a mixed string, so the
    /// chrono can get its own dedicated, more legible presentation (see `chronoView`)
    /// instead of being buried inside a small secondary-colored sentence.
    private var stateLabel: String {
        switch session.recordingState {
        case .idle: return "Prêt"
        case .recording: return "Enregistrement en cours"
        case .paused: return "En pause"
        case .transcribing: return "Transcription en cours…"
        }
    }

    /// Bold tabular digits at 36pt, `.primary` not `.secondary` — a thin monospace chrono
    /// tested earlier read as barely legible; this is the corrected version.
    private var chronoView: some View {
        VStack(spacing: 2) {
            Text("Temps écoulé")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Text(formattedElapsed)
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
    }

    private var formattedElapsed: String {
        let total = Int(session.elapsedSeconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
