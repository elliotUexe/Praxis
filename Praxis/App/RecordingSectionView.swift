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
    @StateObject private var transcriptSelection = TranscriptSelectionModel()

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
                                transcription?.displaySegments.map(\.text).joined(separator: " ") ?? ""
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



    /// Only the tail of the transcript is handed to SwiftUI. This `VStack` lays out every
    /// child on every update, and updates fire several times per second while someone is
    /// speaking, so the layout cost grew linearly with session length: sampling a real
    /// 1h24 course showed the app pegged at 119% CPU with the main thread almost entirely
    /// inside `sizeThatFits`. Capping the rendered window makes that cost constant.
    ///
    /// `transcription.displaySegments` itself stays complete on purpose — it is the source
    /// of truth for the `.txt` written next to the WAV, so trimming it would silently
    /// truncate every saved transcript.
    private static let visibleSegmentLimit = 100

    private var visibleSegments: ArraySlice<DisplaySegment> {
        transcription.displaySegments.suffix(Self.visibleSegmentLimit)
    }

    private var hiddenSegmentCount: Int {
        max(0, transcription.displaySegments.count - Self.visibleSegmentLimit)
    }

    private var transcriptionScrollView: some View {
        TranscriptTextView(
            segments: Array(visibleSegments),
            flags: transcription.flags,
            unconfirmedText: transcription.unconfirmedText,
            hiddenSegmentCount: hiddenSegmentCount,
            selection: transcriptSelection
        )
        .overlay(alignment: .topLeading) { flagPill }
        .frame(minHeight: 150)
        .frame(maxHeight: .infinity)
        .background(Color.gray.opacity(0.08))
        .cornerRadius(8)
    }

    /// Floats over the selection rather than living in the toolbar: the gesture is
    /// "select the bad passage, confirm", and a button on the other side of the window
    /// would break that into two unrelated movements.
    @ViewBuilder
    private var flagPill: some View {
        if transcriptSelection.action != .none {
            GeometryReader { geometry in
                let size = CGSize(width: 108, height: 22)
                let anchor = transcriptSelection.anchor
                let above = anchor.minY - size.height / 2 - 6
                Button(action: applyFlagAction) {
                    Label(
                        transcriptSelection.action == .add ? "Signaler" : "Retirer",
                        systemImage: transcriptSelection.action == .add ? "exclamationmark.triangle" : "xmark.circle"
                    )
                    .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .frame(width: size.width, height: size.height)
                .position(
                    // Kept inside the transcript on both axes: a selection on the first
                    // line puts the pill below instead of off the top edge, and one at the
                    // right margin slides back in rather than being clipped.
                    x: min(max(anchor.midX, size.width / 2), max(size.width / 2, geometry.size.width - size.width / 2)),
                    y: above > size.height / 2 ? above : anchor.maxY + size.height / 2 + 6
                )
            }
        }
    }

    private func applyFlagAction() {
        switch transcriptSelection.action {
        case .add:
            for target in transcriptSelection.targets {
                transcription.flag(segmentStart: target.segmentStart, substring: target.substring)
            }
        case .remove:
            for target in transcriptSelection.targets {
                transcription.unflag(segmentStart: target.segmentStart, substring: target.substring)
            }
        case .none:
            break
        }
        transcriptSelection.dismissAndDeselect()
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
