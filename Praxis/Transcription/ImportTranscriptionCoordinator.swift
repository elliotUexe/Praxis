import Foundation
import WhisperKit

@MainActor
final class ImportTranscriptionCoordinator: ObservableObject {
    @Published private(set) var isTranscribing = false
    @Published private(set) var isLoadingModel = false
    @Published private(set) var isReady = false
    @Published private(set) var progressText: String = ""
    @Published var lastError: String? {
        didSet { if let lastError { transcriptionLog.error("import: \(lastError, privacy: .public)") } }
    }
    @Published private(set) var lastOutputURL: URL?

    /// Same rule as the live coordinator: the engine is fixed at `prepare()`.
    @Published private(set) var engine: TranscriptionEngine = .current

    private var whisperKit: WhisperKit?

    /// Same queue as `LiveTranscriptionCoordinator`, for the same race: a switch of engine
    /// while the import model was still loading left `isReady` describing the wrong one.
    private var lastOperation: Task<Void, Never>?

    private func serialized(_ operation: @escaping @MainActor () async -> Void) async {
        let previous = lastOperation
        let task = Task { @MainActor in
            await previous?.value
            await operation()
        }
        lastOperation = task
        await task.value
    }

    func prepare() async {
        await serialized { await self.performPrepare() }
    }

    private func performPrepare(modelName: String = "large-v3-v20240930_626MB") async {
        if isReady, engine == .current { return }
        if isReady { performUnload() }
        engine = .current
        isLoadingModel = true
        defer { isLoadingModel = false }
        if engine == .apple {
            guard #available(macOS 26, *) else { return }
            do {
                try await AppleSpeech.ensureAssets(locale: await AppleSpeech.locale())
                isReady = true
            } catch {
                lastError = "Reconnaissance Apple indisponible : \(error.localizedDescription)"
            }
            return
        }
        do {
            whisperKit = try await WhisperKit(WhisperKitConfig(model: modelName, load: true))
            isReady = true
        } catch {
            lastError = "Impossible de charger le modèle d'import : \(error.localizedDescription)"
        }
    }

    /// Frees the import model. Refuses mid-transcription rather than pulling the model out
    /// from under a running job; `prepare()` reloads from the on-disk cache on demand.
    func unloadModel() async {
        await serialized { self.performUnload() }
    }

    private func performUnload() {
        guard !isTranscribing else {
            lastError = "Impossible de décharger pendant une transcription."
            return
        }
        whisperKit = nil
        isReady = false
    }

    /// See `LiveTranscriptionCoordinator.applyEngineSetting()`.
    func applyEngineSetting() async {
        await serialized {
            guard !self.isTranscribing, TranscriptionEngine.current != self.engine else { return }
            let wasLoaded = self.isReady
            self.performUnload()
            self.engine = .current
            if wasLoaded { await self.performPrepare() }
        }
    }

    func transcribe(fileURL: URL) async {
        await serialized {}
        if engine == .apple {
            await transcribeWithApple(fileURL: fileURL)
            return
        }
        guard let whisperKit else {
            lastError = "Modèle d'import non chargé."
            return
        }
        isTranscribing = true
        progressText = "Transcription de \(fileURL.lastPathComponent)…"
        lastError = nil
        lastOutputURL = nil

        let decodingOptions = TranscriptionDefaults.decodingOptions()

        do {
            let results = try await whisperKit.transcribe(
                audioPath: fileURL.path,
                decodeOptions: decodingOptions
            ) { progress in
                Task { @MainActor [weak self] in
                    self?.progressText = "Transcription de \(fileURL.lastPathComponent)… (fenêtre \(progress.windowId + 1))"
                }
                return true
            }

            let lines = results.flatMap(\.segments).map {
                OutputFileManager.transcriptLine(start: $0.start, text: $0.text)
            }

            try write(lines: lines, nextTo: fileURL)
        } catch {
            lastError = "Erreur de transcription : \(error.localizedDescription)"
            progressText = ""
        }

        isTranscribing = false
    }

    /// One pass over the whole file. The analyser gives no per-window progress, but a
    /// 41-minute lecture takes about twenty seconds, so none is needed.
    private func transcribeWithApple(fileURL: URL) async {
        guard #available(macOS 26, *), isReady else {
            lastError = "Reconnaissance Apple non prête."
            return
        }
        isTranscribing = true
        progressText = "Transcription de \(fileURL.lastPathComponent)…"
        lastError = nil
        lastOutputURL = nil
        do {
            let locale = await AppleSpeech.locale()
            try await AppleSpeech.ensureAssets(locale: locale)
            let parts = try await AppleSpeech.transcribe(fileURL: fileURL, locale: locale)
            let lines = parts.map { OutputFileManager.transcriptLine(start: $0.start, text: $0.text) }
            try write(lines: lines, nextTo: fileURL)
        } catch {
            lastError = "Erreur de transcription : \(error.localizedDescription)"
            progressText = ""
        }
        isTranscribing = false
    }

    private func write(lines: [String], nextTo fileURL: URL) throws {
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        let outputURL = OutputFileManager.txtURL(in: fileURL.deletingLastPathComponent(), baseName: baseName)
        try lines.joined(separator: "\n").write(to: outputURL, atomically: true, encoding: .utf8)
        lastOutputURL = outputURL
        progressText = "Terminé — \(lines.count) segments."
    }

}
