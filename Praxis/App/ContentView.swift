import SwiftUI
import SwiftData

/// Phase 2 (Praxis MVP): sidebar sections of the integrated app shell. Replaces the old
/// fixed-size two-column `HStack` (recording + AI notes side by side) with a resizable,
/// full-screen-capable `NavigationSplitView` — "intègre-le totalement, pas un truc à part"
/// per Pierre's review: one window, one visual identity, not a bolted-on Tâches window.
enum AppSection: String, CaseIterable, Identifiable {
    case accueil = "Accueil"
    case recording = "Enregistrement"
    case tasks = "Tâches"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .accueil: return "house"
        case .recording: return "waveform"
        case .tasks: return "checklist"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var session: AppSessionStore
    @EnvironmentObject private var transcription: LiveTranscriptionCoordinator
    @EnvironmentObject private var importCoordinator: ImportTranscriptionCoordinator
    @EnvironmentObject private var updateChecker: UpdateCheckCoordinator
    @EnvironmentObject private var aiSummary: AISummaryCoordinator
    @Query(filter: #Predicate<PraxisTask> { $0.needsReview && !$0.isDone })
    private var needsReviewTasks: [PraxisTask]

    @State private var selectedSection: AppSection? = .accueil
    @State private var isSettingsPresented = false

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $selectedSection) { section in
                HStack {
                    Label(section.rawValue, systemImage: section.icon)
                    if section == .tasks, !needsReviewTasks.isEmpty {
                        Spacer()
                        Text("\(needsReviewTasks.count)")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.25))
                            .clipShape(Capsule())
                    }
                }
                .tag(section)
            }
            .navigationTitle("Praxis")
            .toolbar {
                ToolbarItem {
                    Button {
                        isSettingsPresented = true
                    } label: {
                        Label("Réglages", systemImage: "gearshape")
                            .overlay(alignment: .topTrailing) {
                                if updateChecker.updateAvailable {
                                    Circle()
                                        .fill(Color.praxisAccent)
                                        .frame(width: 6, height: 6)
                                        .offset(x: 4, y: -2)
                                }
                            }
                    }
                    .help(updateChecker.updateAvailable ? "Mise à jour disponible (\(updateChecker.latestVersion ?? ""))" : "Réglages")
                }
            }
        } detail: {
            switch selectedSection ?? .accueil {
            case .accueil:
                AccueilSectionView()
            case .recording:
                RecordingSectionView()
            case .tasks:
                TasksSectionView()
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .task {
            await transcription.prepare()
            await importCoordinator.prepare()
            await updateChecker.checkForUpdates()
            // Auto-install without asking, per Pierre's request — but never while an
            // enregistrement is actually in progress, since installing quits the app.
            if updateChecker.updateAvailable, session.recordingState == .idle {
                await updateChecker.downloadAndInstallUpdate()
            }
        }
        .sheet(isPresented: $isSettingsPresented) {
            SettingsView()
                .environmentObject(aiSummary)
        }
    }
}
