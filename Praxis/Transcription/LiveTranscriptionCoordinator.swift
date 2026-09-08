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
    private var currentOutputURL: URL?
    /// Where the live transcript is written, next to the WAV and with the same base name,
    /// so a live session and an imported file produce the same pair of artifacts. Unlike
    /// `currentOutputURL` this is deliberately NOT cleared on `stop()`: refinement jobs
    /// finish asynchronously and can still improve segments after the session ended, and
    /// they must be able to rewrite the file. It's reset on the next `start()`.
    private var transcriptURL: URL?

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
        lastError = nil
        currentOutputURL = outputURL
        transcriptURL = OutputFileManager.txtURL(
            in: outputURL.deletingLastPathComponent(),
            baseName: outputURL.deletingPathExtension().lastPathComponent
        )

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
        if let url = currentOutputURL {
            writeCheckpointWAV(to: url)
        }
        writeTranscript()
        currentOutputURL = nil

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
        // `audioSamples`; periodically snapshot it to disk so a crash loses at most one
        // checkpoint interval instead of the whole session.
        checkpointTimer?.invalidate()
        checkpointTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let url = self.currentOutputURL else { return }
                self.writeCheckpointWAV(to: url)
                self.writeTranscript()
            }
        }
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
        let text = displaySegments
            .map { OutputFileManager.transcriptLine(start: $0.start, text: $0.text) }
            .joined(separator: "\n")
        try? text.write(to: transcriptURL, atomically: true, encoding: .utf8)
    }

    private func writeCheckpointWAV(to url: URL) {
        guard let whisperKit else { return }
        let samples = Array(whisperKit.audioProcessor.audioSamples)
        guard !samples.isEmpty else { return }

        guard let floatFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(WhisperKit.sampleRate),
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(pcmFormat: floatFormat, frameCapacity: AVAudioFrameCount(samples.count)) else {
            return
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { ptr in
            buffer.floatChannelData?[0].update(from: ptr.baseAddress!, count: samples.count)
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Double(WhisperKit.sampleRate),
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        guard let file = try? AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        ) else { return }
        try? file.write(from: buffer)
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
                // Refinements routinely land after the session was stopped, when the
                // checkpoint timer is already gone. Without this the saved file would keep
                // the rough first-pass text for the tail of every recording.
                self.writeTranscript()
            }
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
