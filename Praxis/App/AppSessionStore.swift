import Foundation
import AppKit

enum RecordingState: Equatable {
    case idle
    case recording
    case paused
    case transcribing
}

/// A course folder offered in the destination override menu. `year`/`pole` are stored
/// directly (not re-parsed from `vaultPath` at display time) so the override menu can
/// group courses into a Année → Pôle → Cours cascade.
struct CourseOption: Identifiable, Hashable {
    let vaultPath: String
    let year: String    // "1A" | "2A" | "3A"
    let pole: String    // "GEM" | "INP"
    var id: String { vaultPath }
    var displayName: String { VaultPaths.courseDisplayName(fromVaultPath: vaultPath) }
}

@MainActor
final class AppSessionStore: ObservableObject {
    @Published private(set) var recordingState: RecordingState = .idle
    @Published private(set) var elapsedSeconds: TimeInterval = 0
    @Published var lastTranscriptSnippet: String = ""
    @Published var lastError: String?
    @Published private(set) var currentRecordingURL: URL?

    /// Vault-relative course path the destination folder currently points at, resolved
    /// from `ScheduleCache` at init and overridable at any time (before or during a
    /// recording) via `overrideDestination(toCourseVaultPath:)`.
    @Published private(set) var destinationCourseVaultPath: String?
    /// Set when Pierre picks "Autre dossier…" instead of a resolved course — mutually
    /// exclusive with `destinationCourseVaultPath` (setting one clears the other).
    @Published private(set) var customDestinationFolder: URL?
    @Published private(set) var availableCourses: [CourseOption] = []

    private var timer: Timer?
    private var sessionStart: Date?
    private var outputFolder: URL?

    init() {
        resolveDestinationFromSchedule()
        availableCourses = CourseDirectoryScanner.scan()
    }

    /// Resolves mic permission and the output WAV path, and flips state to `.recording`.
    /// Does NOT open a mic tap itself: `LiveTranscriptionCoordinator` owns the sole
    /// AVAudioEngine input tap (via WhisperKit's AudioProcessor) for live sessions —
    /// a second independent AVAudioEngine tap on the same input device (this class's
    /// former `AudioCaptureEngine`) crashes CoreAudio with an
    /// AUGraphNodeBaseV3::CreateRecordingTap assertion. The caller passes the returned
    /// URL to `LiveTranscriptionCoordinator.start(outputURL:)`, which produces the WAV
    /// via periodic checkpoints of the same buffer it transcribes from.
    func beginRecordingSession() async -> URL? {
        guard recordingState == .idle else { return nil }

        let granted = await AudioCaptureEngine.requestMicrophonePermission()
        guard granted else {
            lastError = "Accès au micro refusé. Autorisez Praxis dans Réglages Système > Confidentialité et sécurité > Micro."
            return nil
        }

        // Prefer a folder resolved from the schedule cache or picked manually; only fall
        // back to a folder-chooser prompt if neither has ever produced one for this run.
        guard let folder = outputFolder ?? pickOutputFolder() else { return nil }
        outputFolder = folder

        let baseName = OutputFileManager.timestampedBaseName()
        let wavURL = OutputFileManager.wavURL(in: folder, baseName: baseName)

        currentRecordingURL = wavURL
        recordingState = .recording
        sessionStart = Date()
        elapsedSeconds = 0
        startTimer()
        return wavURL
    }

    func pauseRecording() {
        guard recordingState == .recording else { return }
        recordingState = .paused
    }

    func resumeRecording() {
        guard recordingState == .paused else { return }
        recordingState = .recording
    }

    func stopRecording() {
        guard recordingState != .idle else { return }
        recordingState = .idle
        timer?.invalidate()
        timer = nil
        sessionStart = nil
        elapsedSeconds = 0
        currentRecordingURL = nil
    }

    /// Resolves the current course from the pre-generated schedule cache (no network call)
    /// and points the destination folder at that course's `Transcriptions/` folder, creating
    /// it if needed. Called at init; produces no destination if the cache is empty or no
    /// slot matches "now" — `beginRecordingSession` then falls back to the manual picker.
    private func resolveDestinationFromSchedule() {
        guard let coursePath = ScheduleCache.courseVaultPath(for: Date()) else { return }
        overrideDestination(toCourseVaultPath: coursePath)
    }

    /// Lets Pierre override the auto-detected course at any time — before or during a
    /// recording, per the Praxis MVP requirement that the destination is never locked in.
    func overrideDestination(toCourseVaultPath coursePath: String) {
        let folder = VaultPaths.transcriptionsFolder(forCourseVaultPath: coursePath)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        outputFolder = folder
        destinationCourseVaultPath = coursePath
        customDestinationFolder = nil
    }

    /// Lets Pierre point the destination at any folder on disk, entirely outside the
    /// course-mapping mechanism — not every recording is a lecture in a known UE.
    func pickCustomDestination() {
        guard let folder = pickOutputFolder() else { return }
        outputFolder = folder
        customDestinationFolder = folder
        destinationCourseVaultPath = nil
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.sessionStart else { return }
                self.elapsedSeconds = Date().timeIntervalSince(start)
            }
        }
    }

    private func pickOutputFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choisir"
        panel.message = "Choisissez le dossier où enregistrer la transcription"
        return panel.runModal() == .OK ? panel.url : nil
    }
}
