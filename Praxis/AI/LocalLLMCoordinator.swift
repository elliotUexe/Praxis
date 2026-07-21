import Foundation
import MLX
import MLXLMCommon
import MLXLLM
import MLXHuggingFace
// Required at the #huggingFaceLoadModelContainer macro's expansion site — the macro
// generates code referencing these two modules directly (verified against the actual
// macro implementation in MLXHuggingFaceMacros/HuggingFaceIntegrationMacros.swift).
import HuggingFace
import Tokenizers

/// The two local models Pierre can pick between in Réglages — "Rapide" trades quality
/// for latency on the live 45s cycle (summary + extraction) and subtask breakdowns,
/// which were both too slow in real use on an M4 Pro. `qwen3_4b_4bit` is used as-is from
/// `LLMRegistry` rather than a custom `ModelConfiguration` — it's already vetted by
/// mlx-swift-lm, no risk of a typo'd Hugging Face id.
enum LocalModelChoice: String, CaseIterable, Identifiable {
    case rapide, qualite

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .rapide: return "Rapide (Qwen3-4B)"
        case .qualite: return "Qualité (Qwen2.5-7B)"
        }
    }

    var configuration: ModelConfiguration {
        switch self {
        case .rapide: return LLMRegistry.qwen3_4b_4bit
        case .qualite: return LLMRegistry.qwen2_5_7b
        }
    }
}

/// Phase 5 (Praxis MVP): on-device task extraction + rolling summary, running Qwen2.5-7B-
/// Instruct-4bit via mlx-swift-lm — no metered API call, per Pierre's explicit preference.
/// Mirrors `AISummaryCoordinator`'s timer/delta pattern (same shape: `startSession`,
/// `stopSession`, a `transcriptProvider` closure, processing only the new text since the
/// last pass) so the two coordinators are orchestrated identically from the recording UI —
/// this one is additive, not a replacement, and can run alongside the paid Gemini/Claude
/// summary (toggle in Settings) so Pierre can compare quality on the same real course.
@MainActor
final class LocalLLMCoordinator: ObservableObject {
    /// Master switch surfaced as a checkbox in the UI ("IA locale activée") — turning it
    /// off immediately unloads the model to free memory and blocks every local-LLM
    /// function (summary, extraction, Q&A, subtask proposals) for the rest of the
    /// session, including the no-paid-key auto-fallback. `isEnabled` is the actual
    /// per-session run flag every guard in this file checks; `setEnabled(_:)` is the only
    /// way to turn it on, so this master switch always wins regardless of caller.
    @Published var isUserDisabled = false {
        didSet {
            guard isUserDisabled != oldValue, isUserDisabled else { return }
            isEnabled = false
            unload()
        }
    }
    /// Persisted across launches (`UserDefaults`, not the app bundle — survives updates).
    /// Changing it while a model is loaded unloads immediately; the next actual use
    /// reloads with the new choice via `prepareIfNeeded()`.
    @Published var selectedModel: LocalModelChoice = LocalLLMCoordinator.loadSelectedModel() {
        didSet {
            guard selectedModel != oldValue else { return }
            UserDefaults.standard.set(selectedModel.rawValue, forKey: Self.selectedModelDefaultsKey)
            unload()
        }
    }
    @Published private(set) var isEnabled = false
    @Published private(set) var isModelLoaded = false
    @Published private(set) var isLoadingModel = false
    @Published private(set) var isProcessing = false
    @Published private(set) var isProposingSubtasks = false
    @Published var lastError: String?
    @Published private(set) var rollingSummaryMarkdown: String = ""

    /// Q&A, mirroring `AISummaryCoordinator.question`/`.answerMarkdown`/`.isAnswering` —
    /// the local fallback path when no paid API key is configured (see
    /// `AIProviderKind.hasStoredKey`).
    @Published var question: String = ""
    @Published private(set) var answerMarkdown: String = ""
    @Published private(set) var isAnswering = false

    private var modelContainer: ModelContainer?
    /// Reused across every call site in this file (summary, extraction, Q&A, subtask
    /// proposals) purely to avoid reloading the model — never for multi-turn memory, since
    /// each prompt already embeds all the context it needs (prior summary, existing
    /// subtasks, etc). `ChatSession` keeps a growing KV-cache of the conversation across
    /// calls, so every call site must call `chatSession.clear()` right before `respond()`:
    /// without it, prompts from unrelated tasks pile up in the same context, which both
    /// slows down generation (bigger prefill every call) and degrades output quality (the
    /// model drifts from "respond with only this JSON" after enough mixed-purpose turns).
    private var chatSession: ChatSession?

    /// Every prompt in this file wants compact, deterministic output (JSON or a short
    /// factual paragraph), never open-ended chat — so all call sites pin a token cap and a
    /// repetition penalty before calling `respond()`. Left at the library defaults
    /// (`maxTokens: nil`, no repetition penalty), a small quantized model can ramble or
    /// loop for minutes before hitting a natural stop token, which is what turned a
    /// one-line JSON answer into a 2-minute wait during testing.
    private static func generateParameters(maxTokens: Int) -> GenerateParameters {
        GenerateParameters(maxTokens: maxTokens, temperature: 0.3, repetitionPenalty: 1.15)
    }

    /// Qwen3 (the "Rapide" model) reasons in a `<think>…</think>` block before every
    /// answer by default — measured via `PraxisLLMBench`: 6.9s to generate a 4-line JSON
    /// answer, almost double Qwen2.5-7B's 3.7s despite being a smaller model, because most
    /// of the token budget went to unused reasoning. Appending `/no_think` (Qwen3's own
    /// convention) drops that to 1.6s with an empty think block. Qwen2.5 has no notion of
    /// this token, so it's only appended for `.rapide` to avoid adding stray noise to
    /// Qwen2.5 prompts.
    private func promptSuppressingThinking(_ prompt: String) -> String {
        guard selectedModel == .rapide else { return prompt }
        return prompt + "\n/no_think"
    }

    private var timer: Timer?
    private var lastProcessedLength = 0
    /// Counts `processNewText` passes that actually ran (not skipped ticks) — drives the
    /// extraction-every-tick / summary-every-other-tick alternation.
    private var tickCount = 0
    /// Text from ticks where the summary was skipped, folded into the next summary call
    /// so alternating passes doesn't silently drop content from the rolling summary.
    private var pendingSummaryDelta = ""
    private var transcriptProvider: (() -> String)?
    private weak var taskStore: TaskStoreCoordinator?
    private var currentCourseVaultPath: String?
    private var currentSourceLabel: String?

    /// The only way to turn local-LLM functionality on — routes through `isUserDisabled`
    /// so no caller (the no-key auto-fallback, the "Comparer aussi" toggle) can override
    /// an explicit user opt-out. Setting to `false` is always allowed.
    func setEnabled(_ value: Bool) {
        guard !(value && isUserDisabled) else { return }
        isEnabled = value
    }

    /// Drops the loaded model and chat session, freeing the multi-GB of weights from
    /// memory. Safe to call any time, including mid-generation (in-flight calls already
    /// hold their own local reference via `guard let chatSession`); `prepareIfNeeded()`
    /// reloads from the on-disk cache on the next actual use if re-enabled.
    private func unload() {
        modelContainer = nil
        chatSession = nil
        isModelLoaded = false
    }

    private static let selectedModelDefaultsKey = "localLLMSelectedModel"

    private static func loadSelectedModel() -> LocalModelChoice {
        UserDefaults.standard.string(forKey: selectedModelDefaultsKey)
            .flatMap(LocalModelChoice.init(rawValue:)) ?? .rapide
    }

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
            let container = try await #huggingFaceLoadModelContainer(configuration: selectedModel.configuration)
            modelContainer = container
            chatSession = ChatSession(container)
            isModelLoaded = true
            // Caps MLX's recycled-buffer cache so it doesn't balloon toward swap during a
            // long live session running alongside WhisperKit — measured need on M4 Pro
            // 24 Go, not a hard requirement of the API itself.
            MLX.Memory.cacheLimit = 2 * 1024 * 1024 * 1024
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
        tickCount = 0
        pendingSummaryDelta = ""
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
        guard !isUserDisabled, !question.isEmpty, let transcript = transcriptProvider?() else { return }
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
            Réponds en français, en Markdown, de façon concise et factuelle.
            """
            await chatSession.clear()
            chatSession.generateParameters = Self.generateParameters(maxTokens: 500)
            guard let response = try? await chatSession.respond(to: promptSuppressingThinking(prompt)) else { return }
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
        // `isProcessing` must be claimed before anything else, including reading the
        // transcript — a pass that runs past the next 45s tick previously let a second
        // tick slip through everything up to `await prepareIfNeeded()` (itself a no-op
        // once loaded) and start a second concurrent `respond()` on the same shared
        // `chatSession`, racing its `generateParameters` against the first call's. A tick
        // that bails here touches nothing, so its text is simply picked up next tick.
        guard isEnabled, !isProcessing, let transcript = transcriptProvider?(), transcript.count > lastProcessedLength else { return }
        isProcessing = true
        defer { isProcessing = false }

        let delta = String(transcript.dropFirst(lastProcessedLength))
        lastProcessedLength = transcript.count
        guard delta.trimmingCharacters(in: .whitespacesAndNewlines).count > 20 else { return }

        await prepareIfNeeded()
        guard isModelLoaded else { return }

        tickCount += 1
        pendingSummaryDelta += delta

        await extractAndInsertTasks(delta: delta)
        // Extraction runs every tick (real-time value); the summary rewrite is the
        // expensive call (re-embeds + regenerates the whole rolling summary), so it only
        // runs every other tick. `pendingSummaryDelta` accumulates the skipped tick's text
        // so nothing is missing from the summary once it does run.
        if tickCount.isMultiple(of: 2) {
            await updateSummary(delta: pendingSummaryDelta)
            pendingSummaryDelta = ""
        }
    }

    private func updateSummary(delta: String) async {
        guard let chatSession else { return }
        let courseContext = currentCourseVaultPath.map { " de \(VaultPaths.courseDisplayName(fromVaultPath: $0))" } ?? ""
        // Capped to the last ~4000 chars: the full summary re-embedded every call was
        // both slow (bigger prompt to prefill every pass) and unbounded as a session goes
        // on. A long session's early content still lives in the exported Markdown, just
        // not necessarily reflected verbatim after enough later passes have trimmed it.
        let existingSummary = rollingSummaryMarkdown.isEmpty ? "(vide)" : String(rollingSummaryMarkdown.suffix(4000))
        let truncationNote = rollingSummaryMarkdown.count > 4000
            ? " (début tronqué, poursuis dans la continuité de ce qui suit)"
            : ""
        let prompt = """
        Tu résumes un cours\(courseContext) en direct, en français, de façon concise (style note de cours, pas de blabla). Voici le résumé jusqu'ici\(truncationNote) :
        ---
        \(existingSummary)
        ---
        Nouveau passage transcrit à intégrer :
        ---
        \(delta)
        ---
        Réponds UNIQUEMENT avec le résumé mis à jour dans son ensemble, sans préambule ni commentaire.
        """
        await chatSession.clear()
        chatSession.generateParameters = Self.generateParameters(maxTokens: 800)
        guard let response = try? await chatSession.respond(to: promptSuppressingThinking(prompt)) else { return }
        rollingSummaryMarkdown = response.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractAndInsertTasks(delta: String) async {
        guard let chatSession, let taskStore else { return }
        let courseName = currentCourseVaultPath.map(VaultPaths.courseDisplayName)
        let prompt = Self.extractionPrompt(for: delta, courseName: courseName)
        await chatSession.clear()
        chatSession.generateParameters = Self.generateParameters(maxTokens: 500)
        guard let response = try? await chatSession.respond(to: promptSuppressingThinking(prompt)),
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

    // MARK: - Subtask proposals ("Découper avec l'IA")

    /// Proposes a timed subtask breakdown for a macro task — e.g. "faire un dossier de 10
    /// pages" → "Définir le plan" (30 min), one block per part, "Relecture" (1h). Never
    /// writes to SwiftData itself: `SubtaskProposalView` shows the result for Pierre to
    /// edit/accept first, same review-before-commit spirit as `needsReview` on extracted
    /// tasks. `existingSubtasks` non-empty means "régénérer" — the prompt is told what's
    /// already done so it adjusts the remaining breakdown instead of starting over.
    func proposeSubtasks(
        taskTitle: String,
        taskDetail: String?,
        taskType: TaskType,
        dueDate: Date?,
        existingSubtasks: [(title: String, isDone: Bool)]
    ) async -> [ProposedSubtask] {
        guard !isUserDisabled else { return [] }
        isProposingSubtasks = true
        defer { isProposingSubtasks = false }

        await prepareIfNeeded()
        guard let chatSession else { return [] }

        let prompt = Self.subtaskProposalPrompt(
            taskTitle: taskTitle,
            taskDetail: taskDetail,
            taskType: taskType,
            dueDate: dueDate,
            existingSubtasks: existingSubtasks
        )
        await chatSession.clear()
        chatSession.generateParameters = Self.generateParameters(maxTokens: 600)
        guard let response = try? await chatSession.respond(to: promptSuppressingThinking(prompt)),
              let raw = Self.parseSubtaskProposals(from: response) else { return [] }
        return raw.map { ProposedSubtask(title: $0.title, estimatedMinutes: $0.estimatedMinutes) }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "d MMMM"
        return f
    }()

    private static func subtaskProposalPrompt(
        taskTitle: String,
        taskDetail: String?,
        taskType: TaskType,
        dueDate: Date?,
        existingSubtasks: [(title: String, isDone: Bool)]
    ) -> String {
        var context = "Tâche : \"\(taskTitle)\"\n"
        if let taskDetail, !taskDetail.isEmpty {
            context += "Détail : \(taskDetail)\n"
        }
        context += "Type : \(taskType.displayName)\n"
        if let dueDate {
            context += "Échéance : \(dayFormatter.string(from: dueDate))\n"
        }

        var progressContext = ""
        if !existingSubtasks.isEmpty {
            let lines = existingSubtasks
                .map { "- [\($0.isDone ? "fait" : "à faire")] \($0.title)" }
                .joined(separator: "\n")
            progressContext = """


            Sous-tâches déjà définies (avec leur état actuel) :
            \(lines)

            Propose une suite cohérente avec ce qui est déjà fait — ne répète pas ce qui est terminé, ajuste le reste du découpage en fonction de l'avancement réel.
            """
        }

        return """
        Tu proposes un découpage en sous-tâches concrètes et chronométrées pour aider à réaliser une tâche. Chaque sous-tâche est une étape actionnable avec une durée réaliste en minutes — privilégie des blocs de 15 à 90 minutes, ni des micro-étapes de 5 minutes ni un seul bloc de plusieurs heures. Si le détail de la tâche le permet, propose au moins 3 sous-tâches plutôt qu'un seul bloc générique ; si le détail est trop pauvre pour un vrai découpage, propose une seule sous-tâche invitant à préciser la tâche (ex. "préciser le contenu attendu").

        \(context)\(progressContext)

        Réponds UNIQUEMENT en français, avec un JSON valide de cette forme exacte, sans texte autour, sans balises markdown :
        {"subtasks": [{"title": "...", "estimatedMinutes": 30}]}
        """
    }

    private static func parseSubtaskProposals(from response: String) -> [RawProposedSubtask]? {
        guard let data = extractJSONData(from: response) else { return nil }
        return try? JSONDecoder().decode(SubtaskProposalResponse.self, from: data).subtasks
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
        guard let data = extractJSONData(from: response) else { return nil }
        return try? JSONDecoder().decode(ExtractionResponse.self, from: data).tasks
    }

    /// Shared by every JSON-producing prompt in this file (task extraction, subtask
    /// proposals): local models don't reliably skip the occasional stray sentence around
    /// the JSON despite instructions, so take the outermost `{...}` span rather than
    /// trusting the response to be pure JSON.
    private static func extractJSONData(from response: String) -> Data? {
        guard let openBrace = response.firstIndex(of: "{"),
              let closeBrace = response.lastIndex(of: "}"),
              openBrace < closeBrace else { return nil }
        return String(response[openBrace...closeBrace]).data(using: .utf8)
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

    // MARK: - Q&A on an existing course (no live session required)

    /// Answers a question against a course's saved transcripts/summaries — unlike
    /// `askQuestion()`, which only works during a live recording (bound to
    /// `transcriptProvider`), this reads whatever's already on disk for the course. No
    /// embeddings for this pass: chunks each document, scores chunks by normalized term
    /// overlap with the question, feeds the model only the best-scoring chunks up to a
    /// character budget — cheap and good enough for a single course folder's worth of text.
    func askCourseQuestion(courseVaultPath: String, question: String) async -> String? {
        guard !isUserDisabled, !question.isEmpty else { return nil }
        await prepareIfNeeded()
        guard let chatSession else { return nil }

        let documents = Self.collectCourseDocuments(courseVaultPath: courseVaultPath)
        guard !documents.isEmpty else {
            return "Aucun fichier de cours trouvé (Transcriptions/ ou Resumes/ vides ou absents)."
        }

        let scoredChunks = documents
            .flatMap { document in
                Self.chunk(document.text, maxWords: 500).map { (fileName: document.fileName, text: $0) }
            }
            .map { chunk in (chunk: chunk, score: Self.termOverlapScore(chunk: chunk.text, question: question)) }
            .filter { $0.score > 0 }
            .sorted { $0.score > $1.score }

        guard !scoredChunks.isEmpty else {
            return "Aucun passage pertinent trouvé pour cette question dans les fichiers de ce cours."
        }

        var budget = 8000
        var selected: [(fileName: String, text: String)] = []
        for scored in scoredChunks {
            guard budget > 0 else { break }
            selected.append(scored.chunk)
            budget -= scored.chunk.text.count
        }

        let excerptsText = selected
            .map { "[\($0.fileName)]\n\($0.text)" }
            .joined(separator: "\n---\n")

        let prompt = """
        Tu réponds à une question sur un cours à partir d'extraits de fichiers réels (transcriptions ou résumés). Utilise uniquement ces extraits, cite entre crochets le(s) nom(s) de fichier dont provient l'information dans ta réponse.

        Extraits :
        ---
        \(excerptsText)
        ---

        Question : \(question)
        Réponds en français, en Markdown, de façon concise et factuelle.
        """

        await chatSession.clear()
        chatSession.generateParameters = Self.generateParameters(maxTokens: 600)
        guard let response = try? await chatSession.respond(to: promptSuppressingThinking(prompt)) else { return nil }
        return response.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct CourseDocument {
        let fileName: String
        let text: String
    }

    /// Reads `.md`/`.txt` files under `Transcriptions/` and `Resumes/`, falling back to
    /// the course root if both are absent/empty — an unreadable file is skipped, not fatal
    /// to the rest of the question.
    private static func collectCourseDocuments(courseVaultPath: String) -> [CourseDocument] {
        let courseRoot = VaultPaths.root.appendingPathComponent(courseVaultPath)
        let subfolders = ["Transcriptions", "Resumes"].map { courseRoot.appendingPathComponent($0) }
        var searchRoots = subfolders.filter { FileManager.default.fileExists(atPath: $0.path) }
        if searchRoots.isEmpty { searchRoots = [courseRoot] }

        var documents: [CourseDocument] = []
        for root in searchRoots {
            guard let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { continue }
            for url in entries {
                guard ["md", "txt"].contains(url.pathExtension.lowercased()),
                      let text = try? String(contentsOf: url, encoding: .utf8),
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                documents.append(CourseDocument(fileName: url.lastPathComponent, text: text))
            }
        }
        return documents
    }

    /// Small hardcoded French stopword list + accent/case folding (same folding used
    /// elsewhere in the app, e.g. `TasksSectionView.slug`) — no embeddings for this MVP
    /// pass, just normalized term overlap between the question and each chunk.
    private static let frenchStopwords: Set<String> = [
        "le", "la", "les", "de", "des", "du", "un", "une", "et", "ou", "que", "qui", "dans",
        "pour", "avec", "sur", "est", "sont", "ce", "cette", "ces", "a", "au", "aux", "en",
        "il", "elle", "on", "nous", "vous", "ils", "elles", "je", "tu", "se", "son", "sa",
        "ses", "mais", "donc", "or", "ni", "car", "quoi", "comment", "quand", "pourquoi"
    ]

    private static func normalizedTerms(_ text: String) -> Set<String> {
        let normalized = text.lowercased().folding(options: .diacriticInsensitive, locale: .current)
        let words = normalized.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        return Set(words.filter { !frenchStopwords.contains($0) && $0.count > 1 })
    }

    private static func termOverlapScore(chunk: String, question: String) -> Int {
        normalizedTerms(chunk).intersection(normalizedTerms(question)).count
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

/// A subtask candidate shown for review in `SubtaskProposalView` — not yet a persisted
/// `Subtask`. `id` is synthesized locally (never decoded from the LLM's JSON) purely so
/// SwiftUI can diff the proposal list; it has no relation to `Subtask.id`.
struct ProposedSubtask: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var estimatedMinutes: Int
}

private struct SubtaskProposalResponse: Decodable {
    let subtasks: [RawProposedSubtask]
}

private struct RawProposedSubtask: Decodable {
    let title: String
    let estimatedMinutes: Int
}
