import Foundation
import AVFoundation
import OSLog
import WhisperKit

/// Transcription failures used to live only in `lastError`, on screen: a session that
/// failed to start left no trace anywhere once the window was closed (2026-10-05, an hour
/// of "recording" with no file and nothing in the system log to say why).
let transcriptionLog = Logger(subsystem: "com.pierretranchand.Praxis", category: "transcription")

struct DisplaySegment: Identifiable, Equatable {
    var id: Float { start }
    let start: Float
    let end: Float
    var text: String
    var isRefined: Bool
}

/// The three pieces of transcription state that change several times a second.
///
/// Split out of `LiveTranscriptionCoordinator` because `ObservableObject` invalidates per
/// *object*, not per property: while a lecture was being transcribed, every `unconfirmedText`
/// update invalidated everything that held the coordinator — including `PraxisApp` itself,
/// which owns it as a `@StateObject`. The whole view tree was being rebuilt several times a
/// second, and an open `Menu` does not survive that: picking a course in the task form was
/// impossible during a recording, because the cascade was torn down between clicks.
///
/// Held by the coordinator as a plain `let`, so mutating it does not touch the coordinator's
/// own `objectWillChange`. Only the view that actually shows the transcript observes it.
@MainActor
final class LiveTranscriptDisplay: ObservableObject {
    @Published fileprivate(set) var segments: [DisplaySegment] = []
    @Published fileprivate(set) var unconfirmedText: String = ""
    /// Passages marked as unreliable during the lecture. Owned here rather than by the view
    /// because the view is thrown away and rebuilt constantly, and these have to reach
    /// `writeTranscript()`.
    @Published fileprivate(set) var flags: [TranscriptFlag] = []
    /// Peak amplitude of the most recent capture buffer, 0…1 linear. Sampled here rather
    /// than polled by the view because it belongs to the same tick as the text: it changes
    /// several times a second, and it must not be published on the coordinator itself.
    @Published fileprivate(set) var inputPeak: Float = 0
}

@MainActor
final class LiveTranscriptionCoordinator: ObservableObject {
    /// Everything that ticks. See `LiveTranscriptDisplay` for why it is not published here.
    let display = LiveTranscriptDisplay()

    /// Internal accessors so the transcription logic below reads the same as it did when
    /// these were stored properties.
    private var displaySegments: [DisplaySegment] {
        get { display.segments }
        set { display.segments = newValue }
    }
    private var unconfirmedText: String {
        get { display.unconfirmedText }
        set { display.unconfirmedText = newValue }
    }
    private var flags: [TranscriptFlag] {
        get { display.flags }
        set { display.flags = newValue }
    }

    @Published private(set) var isReady = false
    @Published private(set) var isRefiningReady = false
    @Published private(set) var isLoadingModel = false
    @Published var lastError: String? {
        didSet { if let lastError { transcriptionLog.error("live: \(lastError, privacy: .public)") } }
    }
    /// The engine the loaded state belongs to. Read from the setting at `prepare()`, so a
    /// change in Réglages never swaps the recogniser under a running session.
    @Published private(set) var engine: TranscriptionEngine = .current

    /// `AppleLiveTranscriber` only exists from macOS 26; held untyped so the coordinator
    /// itself keeps the app's deployment target.
    private var appleSession: AnyObject?
    /// The locale Apple's assets were checked for, reused by `start()`.
    private var appleLocale: Locale?

    /// True from the moment `start()` is called until it returns. `start()` can take a
    /// while (an Apple language asset to fetch, a Whisper load to finish), and during that
    /// window Arrêter found nothing to stop, Pause did nothing, and an engine switch could
    /// slip in — then the session started anyway, behind an interface that thought it idle.
    @Published private(set) var isStarting = false

    var isSessionActive: Bool { isStarting || audioStreamTranscriber != nil || appleSession != nil }

    /// The stop in progress, if any. An Apple stop closes the audio at once but then
    /// lets the analyser finish (bounded at 30 s); the interface is idle by then, so a
    /// Démarrer clicked meanwhile must wait for it rather than be refused as "already
    /// recording" — which also stopped the new session's clock straight away.
    private var stopTask: Task<Void, Never>?

    /// Changes with every session. A refinement queued in one session and landing after
    /// the next has started must not rewrite the new transcript — both usually have a
    /// segment starting at 0.0.
    private var sessionID = UUID()

    /// Loading, unloading and switching engine, strictly one after the other.
    ///
    /// They used to overlap. Switching engine while a load was still running unloaded,
    /// asked `prepare()` for the new engine — which saw `isLoadingModel` and did nothing —
    /// and then the old load landed and set `isReady` for an engine no longer selected.
    /// The start button lit up, `start()` failed before creating any file, and the session
    /// clock ran for an hour over nothing; the other way round, the spinner never stopped.
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

    /// Whether `start()` can actually run with what is loaded — for the engine selected,
    /// not merely "something finished loading".
    private var isLoadedForEngine: Bool {
        switch engine {
        case .apple: return isReady && appleLocale != nil
        case .whisper: return isReady && whisperKit != nil
        }
    }

    private var whisperKit: WhisperKit?
    private let refinementCoordinator = RefinementCoordinator()
    private var audioStreamTranscriber: AudioStreamTranscriber?
    private var streamTask: Task<Void, Never>?
    private var refinedStarts: Set<Float> = []
    /// Starts already turned into a `DisplaySegment`. WhisperKit hands back the *whole*
    /// confirmed list on every callback, not a delta, so the previous membership test
    /// (`displaySegments.contains(where:)`) was a linear scan run once per incoming
    /// segment: quadratic in session length, several times per second. It showed up as
    /// 629 of 2901 samples inside `ingest` when profiling a 1h24 recording.
    private var ingestedStarts: Set<Float> = []
    private var checkpointTimer: Timer?
    /// Where the live transcript is written, next to the WAV and with the same base name,
    /// so a live session and an imported file produce the same pair of artifacts. Unlike
    /// the audio file this is deliberately NOT released on `stop()`: refinement jobs finish
    /// asynchronously and can still improve segments after the session ended, and they must
    /// be able to rewrite the file. It's reset on the next `start()`.
    private var transcriptURL: URL?
    /// Held open for the whole session so each checkpoint appends its delta instead of
    /// recreating the file. Nil until `start()` opens it, and released in `stop()`.
    private var wavFile: AVAudioFile?
    /// How many samples of `audioProcessor.audioSamples` have already reached `wavFile`.
    private var writtenSampleCount = 0
    /// Kept for `stop()`, which hands it to `AudioCompressor` once the file is closed.
    private var sessionWAVURL: URL?
    /// For the no-audio warning: a session that writes nothing for its first seconds is
    /// one whose microphone never delivered, and should say so while it can be fixed.
    private var sessionStartedAt: Date?
    private var sessionSampleCount = 0
    private var warnedSilentInput = false
    /// For the same warning mid-session: the microphone can also go quiet halfway through
    /// (device switched, Mac asleep) while the clock runs on.
    private var lastCheckedSampleCount = 0
    private var lastAudioProgressAt: Date?

    func prepare() async {
        await serialized { await self.performPrepare() }
    }

    private func performPrepare(
        liveModelName: String = "large-v3-v20240930_turbo",
        refineModelName: String = "large-v3-v20240930_626MB"
    ) async {
        if isReady, engine == .current, isLoadedForEngine { return }
        if isReady || whisperKit != nil || appleLocale != nil { await performUnload() }
        engine = .current
        if engine == .apple {
            await prepareApple()
            return
        }
        isLoadingModel = true

        async let liveLoad: Void = loadLiveModel(liveModelName)
        async let refineLoad: Void = loadRefineModel(refineModelName)
        _ = await (liveLoad, refineLoad)

        isLoadingModel = false
    }

    /// Nothing to load into Praxis: the recogniser lives in the system. What can be
    /// missing is the language asset, which macOS downloads once for every app.
    private func prepareApple() async {
        guard #available(macOS 26, *) else { return }
        isLoadingModel = true
        defer { isLoadingModel = false }
        let locale = await AppleSpeech.locale()
        do {
            try await AppleSpeech.ensureAssets(locale: locale)
            appleLocale = locale
            isReady = true
        } catch {
            lastError = "Reconnaissance Apple indisponible : \(error.localizedDescription)"
        }
    }

    /// Follows a change of engine in Réglages: frees whatever the old engine held and, if
    /// transcription was loaded, prepares the new one. Never during a session — the
    /// setting is then picked up by the next `prepare()`.
    ///
    /// Queued behind any load in flight, so the switch happens once that load has landed.
    func applyEngineSetting() async {
        await serialized {
            guard !self.isSessionActive, TranscriptionEngine.current != self.engine else { return }
            let wasLoaded = self.isReady
            await self.performUnload()
            self.engine = .current
            if wasLoaded { await self.performPrepare() }
        }
    }

    /// Reloads for a new language. Only Apple cares: its assets are per locale, while
    /// Whisper reads the language at every decode.
    func applyLanguageSetting() async {
        await serialized {
            guard !self.isSessionActive, self.engine == .apple, self.isReady else { return }
            await self.performUnload()
            await self.performPrepare()
        }
    }

    private func loadLiveModel(_ name: String) async {
        do {
            whisperKit = try await WhisperKit(WhisperKitConfig(model: name, load: true))
            isReady = true
        } catch {
            lastError = "Impossible de charger le modèle live : \(error.localizedDescription)"
        }
    }

    private func loadRefineModel(_ name: String) async {
        do {
            try await refinementCoordinator.prepare(modelName: name)
            isRefiningReady = true
        } catch {
            lastError = "Impossible de charger le modèle de raffinement : \(error.localizedDescription)"
        }
    }

    /// Frees both Whisper models (live + refinement) — several GB combined, loaded eagerly
    /// at launch by `ContentView.task` so a recording can start instantly. Pierre works in
    /// Praxis without recording most of the time, so this reclaims that RAM on demand;
    /// `prepare()` reloads from the on-disk model cache (no re-download) when needed.
    /// Refuses while a stream is live rather than yanking the model out from under it.
    func unloadModels() async {
        await serialized { await self.performUnload() }
    }

    private func performUnload() async {
        guard !isSessionActive else {
            lastError = "Impossible de décharger pendant un enregistrement."
            return
        }
        whisperKit = nil
        isReady = false
        await refinementCoordinator.unload()
        isRefiningReady = false
        appleLocale = nil
    }

    /// Returns whether a session really started. The caller must stop its own clock on
    /// `false`: nothing is being recorded, and pretending otherwise is how an hour of
    /// lecture was lost.
    @discardableResult
    func start(outputURL: URL) async -> Bool {
        guard !isStarting else {
            lastError = "Un enregistrement est déjà en train de démarrer."
            return false
        }
        isStarting = true
        defer { isStarting = false }
        if let stopTask { await stopTask.value }
        guard audioStreamTranscriber == nil, appleSession == nil else {
            lastError = "Un enregistrement est déjà en cours."
            return false
        }
        // A load or a switch still in flight finishes first, so the engine checked below
        // is the one that will actually run. Not when what is loaded already matches:
        // waiting then would hold a Whisper start behind the refinement model's load.
        if !(isLoadedForEngine && engine == .current) {
            await serialized {}
        }
        guard isLoadedForEngine else {
            lastError = "Transcription pas prête (\(engine.displayName)) : enregistrement non démarré. Rechargez via « Charger »."
            return false
        }
        if engine == .apple {
            return await startApple(outputURL: outputURL)
        }
        guard let whisperKit, let tokenizer = whisperKit.tokenizer else {
            lastError = "Modèle Whisper non chargé : enregistrement non démarré."
            return false
        }
        guard resetSession(outputURL: outputURL) else { return false }

        let decodingOptions = TranscriptionDefaults.decodingOptions()

        let transcriber = AudioStreamTranscriber(
            audioEncoder: whisperKit.audioEncoder,
            featureExtractor: whisperKit.featureExtractor,
            segmentSeeker: whisperKit.segmentSeeker,
            textDecoder: whisperKit.textDecoder,
            tokenizer: tokenizer,
            audioProcessor: whisperKit.audioProcessor,
            decodingOptions: decodingOptions
        ) { [weak self] _, newState in
            Task { @MainActor in
                guard let self else { return }
                self.unconfirmedText = newState.unconfirmedSegments.map(\.text).joined(separator: " ")
                self.sampleInputLevel()
                self.ingest(confirmedSegments: newState.confirmedSegments)
            }
        }
        audioStreamTranscriber = transcriber

        streamTask = Task {
            do {
                try await transcriber.startStreamTranscription()
            } catch {
                await MainActor.run {
                    self.lastError = "Erreur de transcription : \(error.localizedDescription)"
                }
            }
        }

        restartCheckpointTimer()
        transcriptionLog.info("session start: whisper \(TranscriptionLanguage.current.rawValue, privacy: .public) → \(outputURL.lastPathComponent, privacy: .public)")
        return true
    }

    /// False when the WAV cannot be created: recording into nothing is exactly the
    /// failure this whole path exists to refuse.
    private func resetSession(outputURL: URL) -> Bool {
        sessionID = UUID()
        sessionStartedAt = Date()
        sessionSampleCount = 0
        lastCheckedSampleCount = 0
        lastAudioProgressAt = Date()
        warnedSilentInput = false
        displaySegments = []
        unconfirmedText = ""
        refinedStarts = []
        ingestedStarts = []
        flags = []
        lastError = nil
        transcriptURL = OutputFileManager.txtURL(
            in: outputURL.deletingLastPathComponent(),
            baseName: outputURL.deletingPathExtension().lastPathComponent
        )
        openWAVFile(at: outputURL)
        if wavFile == nil {
            lastError = "Impossible de créer le fichier audio dans \(outputURL.deletingLastPathComponent().lastPathComponent) : enregistrement non démarré."
            return false
        }
        return true
    }

    /// Apple's results arrive already final, so they go straight in as refined text:
    /// there is no second pass to wait for, and nothing to dim.
    private func startApple(outputURL: URL) async -> Bool {
        guard #available(macOS 26, *) else { return false }
        // The language may have changed since `prepare()`: use the one selected now, and
        // make sure its asset is there (instant when it is, which is the usual case).
        let locale = await AppleSpeech.locale()
        do {
            try await AppleSpeech.ensureAssets(locale: locale)
        } catch {
            lastError = "Langue \(locale.identifier) indisponible pour Apple : enregistrement non démarré (\(error.localizedDescription))."
            return false
        }
        appleLocale = locale
        guard resetSession(outputURL: outputURL) else { return false }
        let session = AppleLiveTranscriber()
        appleSession = session
        do {
            try await session.start(
                locale: locale,
                onVolatile: { [weak self] text in self?.unconfirmedText = text },
                onFinal: { [weak self] part in self?.ingestApple(part) },
                onLevel: { [weak self] peak in self?.display.inputPeak = peak }
            )
        } catch {
            await session.stop()
            appleSession = nil
            wavFile = nil
            // The empty WAV `resetSession` created would otherwise sit in the course
            // folder looking like a recording.
            if let wavURL = sessionWAVURL { try? FileManager.default.removeItem(at: wavURL) }
            sessionWAVURL = nil
            lastError = "Impossible de démarrer la reconnaissance Apple : \(error.localizedDescription)"
            return false
        }
        restartCheckpointTimer()
        transcriptionLog.info("session start: apple \(locale.identifier, privacy: .public) → \(outputURL.lastPathComponent, privacy: .public)")
        return true
    }

    private func ingestApple(_ part: TimedText) {
        guard !ingestedStarts.contains(part.start) else { return }
        ingestedStarts.insert(part.start)
        displaySegments.append(DisplaySegment(start: part.start, end: part.end, text: part.text, isRefined: true))
    }

    func stop() async {
        let task = Task { await self.performStop() }
        stopTask = task
        await task.value
        if stopTask == task { stopTask = nil }
    }

    private func performStop() async {
        if #available(macOS 26, *), let session = appleSession as? AppleLiveTranscriber {
            await stopApple(session)
            return
        }
        checkpointTimer?.invalidate()
        checkpointTimer = nil
        appendNewSamplesToWAV()
        // Releasing the last reference closes the file and finalises the WAV header, which
        // has to happen before anything reads the file back.
        wavFile = nil
        writtenSampleCount = 0
        writeTranscript()

        if let wavURL = sessionWAVURL {
            sessionWAVURL = nil
            compressRecording(at: wavURL)
        }

        await audioStreamTranscriber?.stopStreamTranscription()
        streamTask?.cancel()
        streamTask = nil
        audioStreamTranscriber = nil
    }

    /// The microphone stops before the last WAV write, so the file ends where capture did;
    /// the analyser then finishes the sentence in flight, and the transcript is written
    /// once more with it.
    ///
    /// The audio is closed and handed to compression *before* waiting for the analyser:
    /// the recording must never depend on the recogniser finishing.
    @available(macOS 26, *)
    private func stopApple(_ session: AppleLiveTranscriber) async {
        checkpointTimer?.invalidate()
        checkpointTimer = nil
        session.stopCapture()
        appendNewSamplesToWAV()
        wavFile = nil
        writtenSampleCount = 0
        if let wavURL = sessionWAVURL {
            sessionWAVURL = nil
            compressRecording(at: wavURL)
        }
        writeTranscript()

        await session.finishAnalysis()
        appleSession = nil
        unconfirmedText = ""
        writeTranscript()
        transcriptionLog.info("session stop: apple, \(self.sessionSampleCount / 16_000, privacy: .public) s audio, \(self.displaySegments.count, privacy: .public) segments")
    }

    /// `AudioStreamTranscriber` has no pause concept of its own — its polling loop just
    /// finds no new audio while the processor is paused. `pauseRecording`/`resumeRecordingLive`
    /// are AudioProcessing's documented pair for suspending/continuing the *same* `audioSamples`
    /// array, which is exactly what our absolute-time-offset segment/checkpoint indexing needs.
    func pause() {
        if #available(macOS 26, *), let session = appleSession as? AppleLiveTranscriber {
            session.pause()
        }
        whisperKit?.audioProcessor.pauseRecording()
        checkpointTimer?.invalidate()
        checkpointTimer = nil
    }

    func resume() {
        // A pause is not silence from a dead microphone.
        lastAudioProgressAt = Date()
        if #available(macOS 26, *), let session = appleSession as? AppleLiveTranscriber {
            do {
                try session.resume()
            } catch {
                lastError = "Reprise impossible : \(error.localizedDescription)"
            }
            restartCheckpointTimer()
            return
        }
        guard let whisperKit else { return }
        try? whisperKit.audioProcessor.resumeRecordingLive(inputDeviceID: nil, callback: nil)
        restartCheckpointTimer()
    }

    private func restartCheckpointTimer() {
        // WhisperKit's AudioProcessor is the sole mic tap for live sessions (see
        // AppSessionStore.beginRecordingSession). It keeps the full session's audio in
        // `audioSamples`; periodically flush the new tail to disk so a crash loses at most
        // one checkpoint interval instead of the whole session.
        checkpointTimer?.invalidate()
        checkpointTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.appendNewSamplesToWAV()
                self.writeTranscript()
                self.checkInputArriving()
            }
        }
    }

    /// Marks a passage as unreliable. `substring` is the exact wording covered, or nil to
    /// cover the whole segment. Writing immediately rather than waiting for the next
    /// checkpoint keeps the gesture honest: a mark you made is a mark that is on disk.
    func flag(segmentStart: Float, substring: String?) {
        let flag = TranscriptFlag(segmentStart: segmentStart, substring: substring)
        guard !flags.contains(flag) else { return }
        flags.append(flag)
        writeTranscript()
    }

    func unflag(segmentStart: Float, substring: String?) {
        let flag = TranscriptFlag(segmentStart: segmentStart, substring: substring)
        guard let index = flags.firstIndex(of: flag) else { return }
        flags.remove(at: index)
        writeTranscript()
    }

    /// Persists the transcript next to the WAV. Called on every 10s checkpoint, on
    /// `stop()`, and again whenever a late refinement lands, so a crash costs at most one
    /// checkpoint of text instead of the whole session — which is exactly what was lost on
    /// 2026-09-07, when three recordings produced WAVs and no transcript at all because
    /// nothing on the live path ever wrote one.
    ///
    /// Rewrites the whole file each time rather than appending: segments are mutated in
    /// place by the refinement pass, so an append-only file would keep the rough first
    /// pass forever. Writing nothing while the transcript is empty avoids littering course
    /// folders with empty files when a recording captures no speech.
    private func writeTranscript() {
        guard let transcriptURL, !displaySegments.isEmpty else { return }
        let entries = displaySegments.map { TranscriptEntry(start: $0.start, text: $0.text) }
        let text = TranscriptMarkup.document(entries: entries, flags: flags)
        try? text.write(to: transcriptURL, atomically: true, encoding: .utf8)
    }

    private static let wavSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: Double(WhisperKit.sampleRate),
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false
    ]

    /// Opened once per session and appended to. The previous implementation recreated the
    /// file with `AVAudioFile(forWriting:)` on every 10s checkpoint, which truncates and
    /// rewrites it whole, after copying the entire sample buffer: at the 160 MB mark of a
    /// 1h24 course that meant copying and rewriting 160 MB every ten seconds, tens of GB
    /// of SSD writes to produce a single 160 MB file.
    private func openWAVFile(at url: URL) {
        sessionWAVURL = url
        wavFile = try? AVAudioFile(
            forWriting: url,
            settings: Self.wavSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        writtenSampleCount = 0
        if wavFile == nil {
            lastError = "Impossible de créer le fichier audio."
        }
    }

    /// Appends only what arrived since the last checkpoint, so the cost is proportional to
    /// the ten seconds added rather than to the whole session. Deliberately kept on the
    /// main actor: once the write is ~640 KB instead of 160 MB it costs about a
    /// millisecond, and staying here avoids racing another writer on the same file handle.
    /// Runs at each checkpoint, which only ticks while recording (not paused).
    private func checkInputArriving() {
        let now = Date()
        if sessionSampleCount > lastCheckedSampleCount {
            lastCheckedSampleCount = sessionSampleCount
            lastAudioProgressAt = now
            if warnedSilentInput {
                warnedSilentInput = false
                lastError = nil
            }
            return
        }
        guard !warnedSilentInput, let since = lastAudioProgressAt,
              now.timeIntervalSince(since) >= 15 else { return }
        warnedSilentInput = true
        lastError = sessionSampleCount == 0
            ? "Aucun son reçu du micro depuis 15 s : vérifiez l'entrée audio et l'autorisation Micro."
            : "Le micro ne transmet plus rien depuis 15 s : l'enregistrement est interrompu. Vérifiez l'entrée audio."
    }

    private func appendNewSamplesToWAV() {
        if #available(macOS 26, *), let session = appleSession as? AppleLiveTranscriber {
            let samples = session.drainSamples()
            // Put back what a transient write error refused, so the file and the
            // analyser's timeline stay aligned. Not when there is no file at all: they
            // would only pile up in memory.
            if !writeToWAV(samples), wavFile != nil {
                session.requeue(samples)
            }
            return
        }
        guard let whisperKit, let file = wavFile else { return }
        let samples = whisperKit.audioProcessor.audioSamples
        let total = samples.count

        // The buffer is expected to grow monotonically and to survive pause/resume (see
        // `resume()`). If it ever shrinks it was reset underneath us, and appending would
        // splice unrelated audio together — better to stop writing than to produce a file
        // that silently misrepresents the session.
        guard total >= writtenSampleCount else {
            lastError = "Tampon audio réinitialisé, l'enregistrement peut être incomplet."
            wavFile = nil
            return
        }
        guard total > writtenSampleCount else { return }

        if writeToWAV(Array(samples[writtenSampleCount..<total]), file: file) {
            writtenSampleCount = total
        }
    }

    /// Appends 16 kHz mono samples to the session's WAV. Both engines write the same
    /// format, which is what lets `AudioCompressor` stay unaware of which one recorded.
    @discardableResult
    private func writeToWAV(_ newSamples: [Float], file: AVAudioFile? = nil) -> Bool {
        guard let file = file ?? wavFile, !newSamples.isEmpty else { return false }
        guard let floatFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(WhisperKit.sampleRate),
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(pcmFormat: floatFormat, frameCapacity: AVAudioFrameCount(newSamples.count)) else {
            return false
        }
        buffer.frameLength = AVAudioFrameCount(newSamples.count)
        newSamples.withUnsafeBufferPointer { ptr in
            buffer.floatChannelData?[0].update(from: ptr.baseAddress!, count: newSamples.count)
        }

        do {
            try file.write(from: buffer)
            sessionSampleCount += newSamples.count
            return true
        } catch {
            lastError = "Erreur d'écriture audio : \(error.localizedDescription)"
            return false
        }
    }

    /// Hands the finished WAV to the encoder off the main actor: about three seconds of
    /// work for a 90-minute lecture, which on the main actor would be three seconds of
    /// frozen interface at the end of every course. The WAV survives a failure, so the
    /// worst case is a recording that stayed large.
    private func compressRecording(at wavURL: URL) {
        Task.detached(priority: .utility) { [weak self] in
            do {
                try AudioCompressor.compressToM4A(wavURL: wavURL)
            } catch {
                await MainActor.run {
                    self?.lastError = "Compression audio impossible, l'enregistrement reste en WAV : \(error.localizedDescription)"
                }
            }
        }
    }

    /// WhisperKit already measures the energy of every buffer it captures and nothing was
    /// reading it. Surfacing it is what turns "the transcript is bad" into a number: a
    /// lecturer who never lifts the meter off the floor is a capture problem, one who
    /// registers clearly is not.
    private func sampleInputLevel() {
        // `audioEnergy` is on the concrete `AudioProcessor`, not on the `AudioProcessing`
        // protocol `whisperKit.audioProcessor` is typed as. The cast is the default
        // implementation WhisperKit builds for itself; if that ever changes the meter goes
        // quiet rather than the recording breaking.
        guard let processor = whisperKit?.audioProcessor as? AudioProcessor,
              let latest = processor.audioEnergy.last else { return }
        display.inputPeak = latest.max
    }

    private func ingest(confirmedSegments: [TranscriptionSegment]) {
        for segment in confirmedSegments where !ingestedStarts.contains(segment.start) {
            ingestedStarts.insert(segment.start)
            displaySegments.append(DisplaySegment(
                start: segment.start,
                end: segment.end,
                text: segment.text.trimmingCharacters(in: .whitespaces),
                isRefined: false
            ))
            enqueueRefinement(for: segment)
        }
    }

    private func enqueueRefinement(for segment: TranscriptionSegment) {
        guard isRefiningReady, !refinedStarts.contains(segment.start) else { return }
        refinedStarts.insert(segment.start)

        guard let samples = extractSamples(start: segment.start, end: segment.end) else { return }
        let session = sessionID

        Task {
            guard let refinedText = try? await refinementCoordinator.refine(samples: samples),
                  !refinedText.isEmpty else { return }
            await MainActor.run {
                guard self.sessionID == session,
                      let idx = self.displaySegments.firstIndex(where: { $0.start == segment.start }) else { return }
                self.displaySegments[idx].text = refinedText
                self.displaySegments[idx].isRefined = true
                // The rewrite just moved the ground under any flag on this segment.
                self.relocateFlags(onSegment: segment.start, in: refinedText)
                // Refinements routinely land after the session was stopped, when the
                // checkpoint timer is already gone. Without this the saved file would keep
                // the rough first-pass text for the tail of every recording.
                self.writeTranscript()
            }
        }
    }

    private func relocateFlags(onSegment start: Float, in newText: String) {
        for index in flags.indices where flags[index].segmentStart == start {
            flags[index] = TranscriptMarkup.relocated(flags[index], in: newText)
        }
    }

    private func extractSamples(start: Float, end: Float) -> [Float]? {
        guard let whisperKit else { return nil }
        let sampleRate = Float(WhisperKit.sampleRate)
        let audioSamples = whisperKit.audioProcessor.audioSamples
        let startIdx = max(0, Int(start * sampleRate))
        let endIdx = min(audioSamples.count, Int(end * sampleRate))
        guard startIdx < endIdx else { return nil }
        return Array(audioSamples[startIdx..<endIdx])
    }
}
