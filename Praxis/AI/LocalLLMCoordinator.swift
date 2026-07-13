import Foundation
import MLXLMCommon
import MLXLLM
import MLXHuggingFace
// Required at the #huggingFaceLoadModelContainer macro's expansion site — the macro
// generates code referencing these two modules directly (verified against the actual
// macro implementation in MLXHuggingFaceMacros/HuggingFaceIntegrationMacros.swift).
import HuggingFace
import Tokenizers

/// Phase 5 (Praxis MVP): on-device task extraction + rolling summary, running Qwen2.5-7B-
/// Instruct-4bit via mlx-swift-lm — no metered API call, per Pierre's explicit preference.
/// Mirrors `AISummaryCoordinator`'s timer/delta pattern (same shape: `startSession`,
/// `stopSession`, a `transcriptProvider` closure, processing only the new text since the
/// last pass) so the two coordinators are orchestrated identically from the recording UI —
/// this one is additive, not a replacement, and can run alongside the paid Gemini/Claude
/// summary (toggle in Settings) so Pierre can compare quality on the same real course.
@MainActor
final class LocalLLMCoordinator: ObservableObject {
    @Published var isEnabled = false
    @Published private(set) var isModelLoaded = false
    @Published private(set) var isLoadingModel = false
    @Published private(set) var isProcessing = false
    @Published var lastError: String?
    @Published private(set) var rollingSummaryMarkdown: String = ""

    /// Q&A, mirroring `AISummaryCoordinator.question`/`.answerMarkdown`/`.isAnswering` —
    /// the local fallback path when no paid API key is configured (see
    /// `AIProviderKind.hasStoredKey`).
    @Published var question: String = ""
    @Published private(set) var answerMarkdown: String = ""
    @Published private(set) var isAnswering = false

    private var modelContainer: ModelContainer?
    private var chatSession: ChatSession?

    private var timer: Timer?
    private var lastProcessedLength = 0
    private var transcriptProvider: (() -> String)?
    private weak var taskStore: TaskStoreCoordinator?
    private var currentCourseVaultPath: String?
    private var currentSourceLabel: String?

    /// Loads the model on first use (one-time multi-GB download, cached by MLX after
    /// that). Safe to call repeatedly — no-ops once loaded or while already loading.
    func prepareIfNeeded() async {
        guard modelContainer == nil, !isLoadingModel else { return }
        isLoadingModel = true
        lastError = nil
        do {
            // A freestanding macro from MLXHuggingFace (Macros.swift) — not MLXLMCommon.
            // Verified directly against the package source after the id-only free function
            // turned out to need an explicit downloader/tokenizerLoader after all.
            let container = try await #huggingFaceLoadModelContainer(configuration: LLMRegistry.qwen2_5_7b)
            modelContainer = container
            chatSession = ChatSession(container)
            isModelLoaded = true
        } catch {
            lastError = "Impossible de charger le modèle local (Qwen2.5-7B) : \(error.localizedDescription)"
        }
        isLoadingModel = false
    }

    /// `sourceLabel` is a traceable identifier for extracted tasks' `sourceTranscriptPath`
    /// — not necessarily a file that exists on disk yet (live sessions don't persist a
    /// transcript .md today, a known gap from earlier phases), just something Pierre can
    /// recognize the recording by later.
    func startSession(
        taskStore: TaskStoreCoordinator,
        courseVaultPath: String?,
        sourceLabel: String?,
        transcriptProvider: @escaping () -> String
    ) {
        guard isEnabled else { return }
        self.taskStore = taskStore
        self.currentCourseVaultPath = courseVaultPath
        self.currentSourceLabel = sourceLabel
        self.transcriptProvider = transcriptProvider
        rollingSummaryMarkdown = ""
        lastProcessedLength = 0
        Task { await prepareIfNeeded() }
        restartTimer()
    }

    func stopSession() {
        timer?.invalidate()
        timer = nil
        transcriptProvider = nil
    }

    /// Local counterpart to `AISummaryCoordinator.askQuestion()` — same shape
    /// (`transcriptProvider` tied to the session, cleared on `stopSession`), used when
    /// `AIProviderKind.hasStoredKey` is false for the selected paid provider.
    func askQuestion() {
        guard !question.isEmpty, let transcript = transcriptProvider?() else { return }
        let q = question
        Task {
            isAnswering = true
            defer { isAnswering = false }
            await prepareIfNeeded()
            guard let chatSession else { return }
            let prompt = """
            Tu es un assistant de cours\(currentCourseVaultPath.map { " (\(VaultPaths.courseDisplayName(fromVaultPath: $0)))" } ?? ""). Voici la transcription en cours :
            ---
            \(String(transcript.suffix(8000)))
            ---
            Question : \(q)
            Réponds en Markdown, de façon concise et factuelle.
            """
            guard let response = try? await chatSession.respond(to: prompt) else { return }
            answerMarkdown = response.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// One-shot entry point for the Import (batch) path — no growing live transcript to
    /// poll, so this runs extraction + a single summary pass over the whole text once,
    /// chunked to keep each model call focused on a manageable span.
    func processFullTranscript(
        _ text: String,
        taskStore: TaskStoreCoordinator,
        courseVaultPath: String?,
        sourceLabel: String?
    ) async {
        guard isEnabled else { return }
        await prepareIfNeeded()
        guard isModelLoaded else { return }

        self.taskStore = taskStore
        self.currentCourseVaultPath = courseVaultPath
        self.currentSourceLabel = sourceLabel

        isProcessing = true
        defer { isProcessing = false }

        for chunk in Self.chunk(text, maxWords: 400) {
            await extractAndInsertTasks(delta: chunk)
        }
        await updateSummary(delta: text)
    }

    private func restartTimer() {
        timer?.invalidate()
        // 45s: frequent enough to feel "live" without re-prompting the model on every
        // single short segment (each call costs real inference time on-device).
        timer = Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.processNewText() }
        }
    }

    private func processNewText() async {
        guard isEnabled, let transcript = transcriptProvider?(), transcript.count > lastProcessedLength else { return }
        let delta = String(transcript.dropFirst(lastProcessedLength))
        lastProcessedLength = transcript.count
        guard delta.trimmingCharacters(in: .whitespacesAndNewlines).count > 20 else { return }

        await prepareIfNeeded()
        guard isModelLoaded else { return }

        isProcessing = true
        defer { isProcessing = false }

        await extractAndInsertTasks(delta: delta)
        await updateSummary(delta: delta)
    }

    private func updateSummary(delta: String) async {
        guard let chatSession else { return }
        let courseContext = currentCourseVaultPath.map { " de \(VaultPaths.courseDisplayName(fromVaultPath: $0))" } ?? ""
        let prompt = """
        Tu résumes un cours\(courseContext) en direct, en français, de façon concise (style note de cours, pas de blabla). Voici le résumé jusqu'ici :
        ---
        \(rollingSummaryMarkdown.isEmpty ? "(vide)" : rollingSummaryMarkdown)
        ---
        Nouveau passage transcrit à intégrer :
        ---
        \(delta)
        ---
        Réponds UNIQUEMENT avec le résumé mis à jour dans son ensemble, sans préambule ni commentaire.
        """
        guard let response = try? await chatSession.respond(to: prompt) else { return }
        rollingSummaryMarkdown = response.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractAndInsertTasks(delta: String) async {
        guard let chatSession, let taskStore else { return }
        let courseName = currentCourseVaultPath.map(VaultPaths.courseDisplayName)
        let prompt = Self.extractionPrompt(for: delta, courseName: courseName)
        guard let response = try? await chatSession.respond(to: prompt),
              let candidates = Self.parseCandidates(from: response),
              !candidates.isEmpty else { return }

        let course = currentCourseVaultPath.map { taskStore.findOrCreateCourse(vaultPath: $0) }
        for candidate in candidates {
            let task = PraxisTask(
                title: candidate.title,
                type: candidate.type,
                course: course,
                detail: candidate.detail,
                origin: "llm_local"
            )
            task.sourceTranscriptPath = currentSourceLabel
            task.needsReview = true
            candidate.apply(to: task)
            taskStore.modelContext.insert(task)
        }
        taskStore.save()
    }

    // MARK: - Extraction prompt + parsing

    private static func extractionPrompt(for text: String, courseName: String?) -> String {
        """
        Tu extrais les tâches concrètes réellement mentionnées dans cet extrait de cours\(courseName.map { " (\($0))" } ?? "") (français ou anglais). Types possibles :
        - "rendu" : deadline précise pour un livrable (a un `dueDate`)
        - "revisionFond" : point signalé comme important/difficile à réviser, sans date
        - "revisionDS" : révision explicitement liée à un examen/DS à venir
        - "blocage" : question ou point resté visiblement non résolu
        - "anticipation" : mention lointaine, non urgente (a éventuellement un `horizonDate`)

        Ignore le bavardage et les généralités. Ne garde que les tâches concrètes et réellement énoncées — s'il n'y en a aucune, réponds avec une liste vide.

        Réponds UNIQUEMENT avec un JSON valide de cette forme exacte, sans texte autour, sans balises markdown :
        {"tasks": [{"type": "rendu", "title": "...", "detail": "...", "dueDate": "AAAA-MM-JJ"}]}

        Champs optionnels selon le type : "dueDate" (rendu), "estimatedDurationMinutes" (revisionFond/revisionDS), "blockedReason" et "waitingOn" (blocage), "horizonDate" (anticipation).

        Extrait :
        ---
        \(text)
        ---
        """
    }

    private static func parseCandidates(from response: String) -> [ExtractedTaskCandidate]? {
        guard let openBrace = response.firstIndex(of: "{"),
              let closeBrace = response.lastIndex(of: "}"),
              openBrace < closeBrace else { return nil }
        let jsonString = String(response[openBrace...closeBrace])
        guard let data = jsonString.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ExtractionResponse.self, from: data).tasks
    }

    /// Splits into ~`maxWords`-word chunks on paragraph boundaries where possible, so the
    /// Import (batch) path processes a long transcript in digestible pieces instead of one
    /// giant prompt.
    private static func chunk(_ text: String, maxWords: Int) -> [String] {
        let paragraphs = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var chunks: [String] = []
        var current: [String] = []
        var wordCount = 0
        for paragraph in paragraphs {
            let words = paragraph.split(separator: " ").count
            if wordCount + words > maxWords, !current.isEmpty {
                chunks.append(current.joined(separator: "\n"))
                current = []
                wordCount = 0
            }
            current.append(paragraph)
            wordCount += words
        }
        if !current.isEmpty { chunks.append(current.joined(separator: "\n")) }
        return chunks
    }
}

private struct ExtractionResponse: Decodable {
    let tasks: [ExtractedTaskCandidate]
}

private struct ExtractedTaskCandidate: Decodable {
    let type: TaskType
    let title: String
    let detail: String?
    let dueDate: String?
    let estimatedDurationMinutes: Int?
    let blockedReason: String?
    let waitingOn: String?
    let horizonDate: String?

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    func apply(to task: PraxisTask) {
        if let dueDate, let date = Self.dateFormatter.date(from: dueDate) {
            task.dueDate = date
        }
        task.estimatedDurationMinutes = estimatedDurationMinutes
        task.blockedReason = blockedReason
        task.waitingOn = waitingOn
        if let horizonDate, let date = Self.dateFormatter.date(from: horizonDate) {
            task.horizonDate = date
        }
    }
}
