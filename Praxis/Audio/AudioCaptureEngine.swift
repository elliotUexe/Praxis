import AVFoundation

/// Live sessions get their sole AVAudioEngine mic tap from WhisperKit's own
/// AudioProcessor (see LiveTranscriptionCoordinator) — a second independent
/// AVAudioEngine tap on the same input device crashes CoreAudio. This is what's
/// left of the original standalone capture engine: just the permission check.
enum AudioCaptureEngine {
    static func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}
