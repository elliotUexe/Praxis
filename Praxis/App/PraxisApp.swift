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
    @StateObject private var focusTimer = FocusTimerCoordinator()
    @StateObject private var updateChecker = UpdateCheckCoordinator()

    var body: some Scene {
        WindowGroup("Praxis", id: "main") {
            ContentView()
                .environmentObject(session)
                .environmentObject(transcription)
                .environmentObject(importCoordinator)
                .environmentObject(aiSummary)
                .environmentObject(taskStore)
                .environmentObject(localLLM)
                .environmentObject(focusTimer)
                .environmentObject(updateChecker)
                .modelContainer(taskStore.modelContainer)
                .tint(.praxisAccent)
        }

        MenuBarExtra {
            MenuBarContentView()
                .environmentObject(session)
                .environmentObject(transcription)
                .environmentObject(taskStore)
                .modelContainer(taskStore.modelContainer)
        } label: {
            MenuBarIconLabel(recordingState: session.recordingState)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The Praxis "P" mark (template image, auto-tints for light/dark menu bar) with a small
/// status dot layered on top — keeps the brand glyph constant instead of swapping it out
/// for a different SF Symbol per state, while still surfacing recording status at a glance.
private struct MenuBarIconLabel: View {
    let recordingState: RecordingState

    var body: some View {
        Image("MenuBarIcon")
            .renderingMode(.template)
            .overlay(alignment: .bottomTrailing) {
                if let color = statusColor {
                    Circle()
                        .fill(color)
                        .frame(width: 6, height: 6)
                        .offset(x: 2, y: 2)
                }
            }
    }

    private var statusColor: Color? {
        switch recordingState {
        case .idle: return nil
        case .recording: return .red
        case .paused: return .orange
        case .transcribing: return .praxisAccent
        }
    }
}
