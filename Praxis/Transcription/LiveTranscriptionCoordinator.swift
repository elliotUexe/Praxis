import Foundation
import AVFoundation
import WhisperKit

struct DisplaySegment: Identifiable, Equatable {
    var id: Float { start }
    let start: Float
    let end: Float
    var text: String
    var isRefined: Bool
}

@MainActor
final class LiveTranscriptionCoordinator: ObservableObject {
    @Published private(set) var displaySegments: [DisplaySegment] = []
    @Published private(set) var unconfirmedText: String = ""
    /// Passages marked as unreliable during the lecture. Owned here rather than by the view
    /// for the same reason `displaySegments` is: the view is thrown away and rebuilt
    /// constantly, and these have to reach `writeTranscript()`.
    @Published private(set) var flags: [TranscriptFlag] = []
    @Published private(set) var isReady = false
    @Published private(set) var isRefiningReady = false
    @Published private(set) var isLoadingModel = false
    @Published var lastError: String?

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

    func prepare(
        liveModelName: String = "large-v3-v20240930_turbo",
        refineModelName: String = "large-v3-v20240930_626MB"
    ) async {
        guard whisperKit == nil, !isLoadingModel else { return }
        isLoadingModel = true

        async let liveLoad: Void = loadLiveModel(liveModelName)
        async let refineLoad: Void = loadRefineModel(refineModelName)
        _ = await (liveLoad, refineLoad)

        isLoadingModel = false
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
        guard audioStreamTranscriber == nil else {
            lastError = "Impossible de décharger pendant un enregistrement."
            return
        }
        whisperKit = nil
        isReady = false
        await refinementCoordinator.unload()
        isRefiningReady = false
    }

    func start(outputURL: URL) async {
        guard let whisperKit, let tokenizer = whisperKit.tokenizer else {
            lastError = "Modèle non chargé."
            return
        }
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

        let decodingOptions = DecodingOptions(
            task: .transcribe,
            language: "fr",
            skipSpecialTokens: true,
            compressionRatioThreshold: 2.4,
            noSpeechThreshold: 0.6
        )

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
    }

    func stop() async {
        checkpointTimer?.invalidate()
        checkpointTimer = nil
        appendNewSamplesToWAV()
        // Releasing the last reference closes the file and finalises the WAV header.
        wavFile = nil
        writtenSampleCount = 0
        writeTranscript()

        await audioStreamTranscriber?.stopStreamTranscription()
        streamTask?.cancel()
        streamTask = nil
        audioStreamTranscriber = nil
    }

    /// `AudioStreamTranscriber` has no pause concept of its own — its polling loop just
    /// finds no new audio while the processor is paused. `pauseRecording`/`resumeRecordingLive`
    /// are AudioProcessing's documented pair for suspending/continuing the *same* `audioSamples`
    /// array, which is exactly what our absolute-time-offset segment/checkpoint indexing needs.
    func pause() {
        whisperKit?.audioProcessor.pauseRecording()
        checkpointTimer?.invalidate()
        checkpointTimer = nil
    }

    func resume() {
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
    private func appendNewSamplesToWAV() {
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

        let newSamples = Array(samples[writtenSampleCount..<total])
        guard let floatFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(WhisperKit.sampleRate),
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(pcmFormat: floatFormat, frameCapacity: AVAudioFrameCount(newSamples.count)) else {
            return
        }
        buffer.frameLength = AVAudioFrameCount(newSamples.count)
        newSamples.withUnsafeBufferPointer { ptr in
            buffer.floatChannelData?[0].update(from: ptr.baseAddress!, count: newSamples.count)
        }

        do {
            try file.write(from: buffer)
            writtenSampleCount = total
        } catch {
            lastError = "Erreur d'écriture audio : \(error.localizedDescription)"
        }
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

        Task {
            guard let refinedText = try? await refinementCoordinator.refine(samples: samples),
                  !refinedText.isEmpty else { return }
            await MainActor.run {
                guard let idx = self.displaySegments.firstIndex(where: { $0.start == segment.start }) else { return }
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
