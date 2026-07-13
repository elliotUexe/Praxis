import SwiftUI
import AppKit

struct MenuBarContentView: View {
    @EnvironmentObject private var session: AppSessionStore
    @EnvironmentObject private var transcription: LiveTranscriptionCoordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Praxis")
                .font(.headline)

            Text(statusLabel)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if !session.lastTranscriptSnippet.isEmpty {
                Text(session.lastTranscriptSnippet)
                    .font(.caption)
                    .lineLimit(2)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Button(session.recordingState == .idle ? "Démarrer" : "Arrêter") {
                    if session.recordingState == .idle {
                        Task {
                            guard let outputURL = await session.beginRecordingSession() else { return }
                            await transcription.start(outputURL: outputURL)
                        }
                    } else {
                        session.stopRecording()
                        Task { await transcription.stop() }
                    }
                }
                .disabled(!transcription.isReady && session.recordingState == .idle)

                Button(session.recordingState == .paused ? "Reprendre" : "Pause") {
                    if session.recordingState == .paused {
                        session.resumeRecording()
                        transcription.resume()
                    } else {
                        session.pauseRecording()
                        transcription.pause()
                    }
                }
                .disabled(session.recordingState == .idle)
            }

            Divider()

            Button("Ouvrir Praxis") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }

            Button("Quitter Praxis") {
                NSApp.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 260)
    }

    private var statusLabel: String {
        switch session.recordingState {
        case .idle: return "Prêt"
        case .recording: return "Enregistrement en cours (\(formattedElapsed))"
        case .paused: return "En pause (\(formattedElapsed))"
        case .transcribing: return "Transcription…"
        }
    }

    private var formattedElapsed: String {
        let total = Int(session.elapsedSeconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
