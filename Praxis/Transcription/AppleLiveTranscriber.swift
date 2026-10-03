import Foundation
import AVFoundation
import Speech

/// Live transcription with Apple's SpeechAnalyzer: its own microphone tap, the analyser fed
/// from it, and the same tap's audio kept for the recording on disk.
///
/// Whisper's path gets all three from WhisperKit's `AudioProcessor`. Here nothing else
/// listens to the microphone — WhisperKit is not even loaded in this mode — so the single
/// tap rule from `AudioCaptureEngine` still holds.
///
/// Positions in the transcript are positions in the recording: buffers go to the analyser
/// without timestamps, so it counts audio as it arrives, and a pause simply stops the
/// buffers. That is the same timeline the WAV is written on, and the same one Whisper's
/// segments used, so flags and `[H:MM:SS]` lines mean the same thing in both modes.
@available(macOS 26, *)
final class AppleLiveTranscriber: @unchecked Sendable {
    /// What the recording on disk is written in, shared with the Whisper path.
    static let recordingFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Error>?

    /// Touched only from the tap's audio thread once capture has started.
    private var toAnalyzer: AVAudioConverter?
    private var toRecording: AVAudioConverter?

    /// Audio captured since the coordinator last wrote to the WAV. Filled on the audio
    /// thread, drained on the main actor every checkpoint, hence the lock.
    private let lock = NSLock()
    private var pendingSamples: [Float] = []

    struct StartError: LocalizedError {
        let errorDescription: String?
    }

    private var onLevel: (@MainActor (Float) -> Void)?

    func start(
        locale: Locale,
        onVolatile: @escaping @MainActor (String) -> Void,
        onFinal: @escaping @MainActor (TimedText) -> Void,
        onLevel: @escaping @MainActor (Float) -> Void
    ) async throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        try await startAnalysis(locale: locale, inputFormat: inputFormat, onVolatile: onVolatile, onFinal: onFinal)
        self.onLevel = onLevel

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    /// Everything but the microphone, so the same path can be driven from a file in a test.
    func startAnalysis(
        locale: Locale,
        inputFormat: AVAudioFormat,
        onVolatile: @escaping @MainActor (String) -> Void,
        onFinal: @escaping @MainActor (TimedText) -> Void
    ) async throws {
        let transcriber = AppleSpeech.makeTranscriber(locale: locale, live: true)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        guard inputFormat.sampleRate > 0,
              let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: [transcriber], considering: inputFormat
              ) else {
            throw StartError(errorDescription: "Aucune entrée audio utilisable.")
        }
        toAnalyzer = AVAudioConverter(from: inputFormat, to: analyzerFormat)
        toRecording = AVAudioConverter(from: inputFormat, to: Self.recordingFormat)

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = continuation

        // Awaiting each handler on the main actor, rather than firing a Task per result,
        // is what lets `stop()` know the last final text has landed once this loop ends.
        resultsTask = Task {
            for try await result in transcriber.results {
                if result.isFinal {
                    let part = AppleSpeech.timed(result)
                    if !part.text.isEmpty { await onFinal(part) }
                    await onVolatile("")
                } else {
                    await onVolatile(String(result.text.characters))
                }
            }
        }

        try await analyzer.prepareToAnalyze(in: analyzerFormat)
        try await analyzer.start(inputSequence: stream)
    }

    /// One capture buffer, in the input's own format: to the analyser, to the recording,
    /// and its peak to the level meter. Runs on the audio thread.
    func process(_ buffer: AVAudioPCMBuffer) {
        if let converted = toAnalyzer.flatMap({ Self.convert(buffer, using: $0) }) {
            inputContinuation?.yield(AnalyzerInput(buffer: converted))
        }
        if let recorded = toRecording.flatMap({ Self.convert(buffer, using: $0) }),
           let channel = recorded.floatChannelData?[0] {
            let samples = UnsafeBufferPointer(start: channel, count: Int(recorded.frameLength))
            lock.withLock { pendingSamples.append(contentsOf: samples) }
        }
        if let onLevel {
            let peak = Self.peak(of: buffer)
            Task { @MainActor in onLevel(peak) }
        }
    }

    /// Hands over what was captured since the last call, for the WAV.
    func drainSamples() -> [Float] {
        lock.withLock {
            defer { pendingSamples.removeAll(keepingCapacity: true) }
            return pendingSamples
        }
    }

    func pause() {
        engine.pause()
    }

    func resume() throws {
        try engine.start()
    }

    /// Stops the microphone first, so nothing arrives after the last WAV write, then lets
    /// the analyser finish the sentence it was in the middle of. Returns once every final
    /// result has been delivered.
    func stop() async {
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        inputContinuation?.finish()
        inputContinuation = nil
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        _ = try? await resultsTask?.value
        resultsTask = nil
        analyzer = nil
    }

    /// Sample-rate converters keep state between calls, which is what keeps a stream of
    /// small buffers seamless; `.noDataNow` after the one buffer preserves that state
    /// instead of flushing it as `.endOfStream` would.
    private static func convert(_ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter) -> AVAudioPCMBuffer? {
        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else {
            return nil
        }
        var delivered = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if delivered {
                status.pointee = .noDataNow
                return nil
            }
            delivered = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && output.frameLength > 0 ? output : nil
    }

    private static func peak(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        var peak: Float = 0
        for i in 0..<Int(buffer.frameLength) {
            peak = max(peak, abs(channel[i]))
        }
        return min(peak, 1)
    }
}
