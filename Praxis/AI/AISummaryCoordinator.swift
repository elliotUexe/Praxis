import Foundation

enum SummaryFrequency: String, CaseIterable, Identifiable {
    case oneMinute = "1 min"
    case twoMinutes = "2 min"
    case fiveMinutes = "5 min"
    case paused = "Pause"

    var id: String { rawValue }

    var interval: TimeInterval? {
        switch self {
        case .oneMinute: return 60
        case .twoMinutes: return 120
        case .fiveMinutes: return 300
        case .paused: return nil
        }
    }
}

@MainActor
final class AISummaryCoordinator: ObservableObject {
    @Published var selectedProvider: AIProviderKind = .gemini
    @Published var frequency: SummaryFrequency = .twoMinutes {
        didSet { restartTimer() }
    }
    @Published private(set) var summaryMarkdown: String = ""
    @Published private(set) var isSummarizing = false
    @Published var lastError: String?

    @Published var question: String = ""
    @Published private(set) var answerMarkdown: String = ""
    @Published private(set) var isAnswering = false

    private var timer: Timer?
    private var lastSummarizedLength = 0
    private var notesURL: URL?
    private var transcriptProvider: (() -> String)?

    func startSession(outputFolder: URL, transcriptProvider: @escaping () -> String) {
        notesURL = outputFolder.appendingPathComponent("Notes_IA.md")
        self.transcriptProvider = transcriptProvider
        summaryMarkdown = ""
        answerMarkdown = ""
        lastSummarizedLength = 0
        restartTimer()
    }

    func stopSession() {
        timer?.invalidate()
        timer = nil
        transcriptProvider = nil
        notesURL = nil
    }

    func refreshNow() {
        Task { await runSummary() }
    }

    func askQuestion() {
        guard !question.isEmpty, let transcript = transcriptProvider?() else { return }
        let q = question
        Task {
            isAnswering = true
            defer { isAnswering = false }
            do {
                let provider = selectedProvider.makeProvider()
                answerMarkdown = try await provider.ask(transcript: transcript, question: q)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    private func restartTimer() {
        timer?.invalidate()
        timer = nil
        guard let interval = frequency.interval else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.runSummary() }
        }
    }

    private func runSummary() async {
        guard let transcript = transcriptProvider?(), transcript.count > lastSummarizedLength else { return }
        let newContext = String(transcript.dropFirst(lastSummarizedLength))
        lastSummarizedLength = transcript.count

        isSummarizing = true
        defer { isSummarizing = false }

        do {
            let provider = selectedProvider.makeProvider()
            summaryMarkdown = try await provider.summarize(previousSummary: summaryMarkdown, newContext: newContext)
            lastError = nil
            writeNotes()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func writeNotes() {
        guard let notesURL else { return }
        try? summaryMarkdown.write(to: notesURL, atomically: true, encoding: .utf8)
    }
}
