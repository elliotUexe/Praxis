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

    @State private var isFileImporterPresented = false
    @State private var isDropTargeted = false
    @State private var selectedTab: RecordingTab = .transcription
    @State private var captureText: String = ""
    @State private var captureConfirmation: String?

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
            sttModelsRow

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
                                transcription?.display.segments.map(\.text).joined(separator: " ") ?? ""
                            }
                            // The local-LLM live cycle used to run here alongside the paid
                            // summary; it's disconnected (see LocalLLMCoordinator
                            // .isAvailable) after crashing the app mid-recording. Without
                            // an API key there is simply no AI pass during a session now.
                            if aiSummary.selectedProvider.hasStoredKey {
                                aiSummary.startSession(
                                    outputFolder: outputURL.deletingLastPathComponent(),
                                    transcriptProvider: transcriptProvider
                                )
                            }
                        }
                    } else {
                        session.stopRecording()
                        Task { await transcription.stop() }
                        aiSummary.stopSession()
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
            // duplicating its logic; environment objects (aiSummary) are
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
                LiveTranscriptPane(
                    display: transcription.display,
                    onFlag: transcription.flag,
                    onUnflag: transcription.unflag
                )
                quickCaptureRow
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
                CoursePickerMenu(courses: session.availableCourses) { course in
                    session.overrideDestination(toCourseVaultPath: course.vaultPath)
                } trailing: {
                    Button("Autre dossier…") { session.pickCustomDestination() }
                }
            }
            .font(.caption)
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }


    /// Whisper models (live + refinement + import) total several GB and load eagerly at
    /// launch so a recording can start instantly. Pierre works in Praxis without recording
    /// most of the time, so this frees that RAM on demand — reloading reads the on-disk
    /// model cache, no re-download. Disabled while recording/transcribing (the coordinators
    /// refuse anyway, this just avoids offering a dead button).
    private var sttModelsRow: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(sttStatusColor)
                .frame(width: 6, height: 6)
            Text("Transcription \(sttStatusText)")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)

            if transcription.isLoadingModel || importCoordinator.isLoadingModel {
                ProgressView().controlSize(.small)
            } else if transcription.isReady || importCoordinator.isReady {
                Button("Décharger") {
                    Task {
                        await transcription.unloadModels()
                        importCoordinator.unloadModel()
                    }
                }
                .font(.system(size: 11))
                .disabled(session.recordingState != .idle || importCoordinator.isTranscribing)
            } else {
                Button("Charger") {
                    Task {
                        await transcription.prepare()
                        await importCoordinator.prepare()
                    }
                }
                .font(.system(size: 11))
            }
        }
    }

    private var sttStatusText: String {
        if transcription.isLoadingModel || importCoordinator.isLoadingModel { return "chargement…" }
        if transcription.isReady || importCoordinator.isReady { return "en mémoire" }
        return "déchargée"
    }

    private var sttStatusColor: Color {
        if transcription.isLoadingModel || importCoordinator.isLoadingModel { return .orange }
        if transcription.isReady || importCoordinator.isReady { return .green }
        return .gray
    }



    /// Jot a task down without leaving the lecture.
    ///
    /// The course is not asked for: `AppSessionStore` already resolved it from the schedule
    /// to know where to write the recording, so the task inherits it. The type is guessed
    /// from the words. And when a recording is running the task keeps the transcript path
    /// and the moment it was written, so "refaire l'exercice 4" can be traced back to what
    /// was being said at 42 minutes.
    ///
    /// Deliberately a plain field with no keyboard shortcut and no sheet: anything that
    /// grabs focus or opens a window costs more attention than the note is worth mid-course.
    private var quickCaptureRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle")
                    .foregroundStyle(.secondary)
                TextField("Noter une tâche pour ce cours…", text: $captureText)
                    .textFieldStyle(.plain)
                    .onSubmit(captureTask)
                    // Clears on the next keystroke rather than on a timer: the confirmation
                    // has served its purpose the moment you start writing the next one.
                    .onChange(of: captureText) { captureConfirmation = nil }
                if !captureText.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button("Ajouter", action: captureTask)
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.gray.opacity(0.08))
            .cornerRadius(8)

            if let captureConfirmation {
                Text(captureConfirmation)
                    .font(.caption2)
                    .foregroundStyle(Color.praxisAccent)
                    .padding(.leading, 8)
            }
        }
    }

    private func captureTask() {
        let trimmed = captureText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let task = PraxisTask(title: trimmed, type: TaskType(detectedFrom: trimmed), origin: "manuel")
        if let coursePath = session.destinationCourseVaultPath {
            task.course = taskStore.findOrCreateCourse(vaultPath: coursePath)
        }
        // Only while something is actually being recorded: outside a session there is no
        // moment to point at, and a transcript path with no timestamp helps nobody.
        if session.recordingState == .recording || session.recordingState == .paused,
           let recordingURL = session.currentRecordingURL {
            let transcriptURL = OutputFileManager.txtURL(
                in: recordingURL.deletingLastPathComponent(),
                baseName: recordingURL.deletingPathExtension().lastPathComponent
            )
            task.sourceTranscriptPath = transcriptURL.path
            let stamp = OutputFileManager.transcriptTimestamp(Float(session.elapsedSeconds))
            task.detail = "Noté à \(stamp) de l'enregistrement."
        }
        taskStore.modelContext.insert(task)
        taskStore.save()

        captureText = ""
        captureConfirmation = session.destinationCourseVaultPath
            .map { "Ajoutée à \(VaultPaths.courseDisplayName(fromVaultPath: $0))." }
            ?? "Ajoutée sans matière."
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
