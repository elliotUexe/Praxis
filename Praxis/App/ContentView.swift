import SwiftUI

/// Phase 2 (Praxis MVP): sidebar sections of the integrated app shell. Replaces the old
/// fixed-size two-column `HStack` (recording + AI notes side by side) with a resizable,
/// full-screen-capable `NavigationSplitView` — "intègre-le totalement, pas un truc à part"
/// per Pierre's review: one window, one visual identity, not a bolted-on Tâches window.
enum AppSection: String, CaseIterable, Identifiable {
    case recording = "Enregistrement"
    case tasks = "Tâches"
    case summaries = "Résumés"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .recording: return "waveform"
        case .tasks: return "checklist"
        case .summaries: return "text.book.closed"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var transcription: LiveTranscriptionCoordinator
    @EnvironmentObject private var importCoordinator: ImportTranscriptionCoordinator

    @State private var selectedSection: AppSection? = .recording
    @State private var isSettingsPresented = false

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $selectedSection) { section in
                Label(section.rawValue, systemImage: section.icon)
                    .tag(section)
            }
            .navigationTitle("Praxis")
            .toolbar {
                ToolbarItem {
                    Button {
                        isSettingsPresented = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
        } detail: {
            switch selectedSection ?? .recording {
            case .recording:
                RecordingSectionView()
            case .tasks:
                TasksSectionView()
            case .summaries:
                SummariesSectionView()
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .task {
            await transcription.prepare()
            await importCoordinator.prepare()
        }
        .sheet(isPresented: $isSettingsPresented) {
            SettingsView()
        }
    }
}
