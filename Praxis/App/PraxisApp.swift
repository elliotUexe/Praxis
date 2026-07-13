import SwiftUI
import SwiftData

@main
struct PraxisApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var session = AppSessionStore()
    @StateObject private var transcription = LiveTranscriptionCoordinator()
    @StateObject private var importCoordinator = ImportTranscriptionCoordinator()
    @StateObject private var aiSummary = AISummaryCoordinator()
    @StateObject private var taskStore = TaskStoreCoordinator()
    @StateObject private var localLLM = LocalLLMCoordinator()

    var body: some Scene {
        WindowGroup("Praxis", id: "main") {
            ContentView()
                .environmentObject(session)
                .environmentObject(transcription)
                .environmentObject(importCoordinator)
                .environmentObject(aiSummary)
                .environmentObject(taskStore)
                .environmentObject(localLLM)
                .modelContainer(taskStore.modelContainer)
        }

        MenuBarExtra {
            MenuBarContentView()
                .environmentObject(session)
                .environmentObject(transcription)
        } label: {
            Image(systemName: menuBarSymbol)
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarSymbol: String {
        switch session.recordingState {
        case .idle: return "waveform"
        case .recording: return "waveform.circle.fill"
        case .paused: return "pause.circle"
        case .transcribing: return "arrow.triangle.2.circlepath"
        }
    }
}
