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

    @AppStorage("appAppearance") private var appearanceRaw = AppAppearance.auto.rawValue

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
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
                Divider()
                sidebarStatusRow
            }
            .navigationTitle("Praxis")
        } detail: {
            switch selectedSection ?? .accueil {
            case .accueil:
                AccueilSectionView(selectedSection: $selectedSection)
            case .recording:
                RecordingSectionView()
            case .tasks:
                TasksSectionView()
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .preferredColorScheme((AppAppearance(rawValue: appearanceRaw) ?? .auto).colorScheme)
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

    /// "Réglages accessibles depuis un bouton ⚙ à côté du statut" per the design handoff —
    /// bottom-left footer of the sidebar (below the section list), matching the reference
    /// design exactly (a first attempt placed this above the list instead, which read as
    /// competing with the native "Praxis" sidebar title for the same top real estate).
    private var sidebarStatusRow: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Text(statusLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                isSettingsPresented = true
            } label: {
                Image(systemName: "gearshape")
                    .overlay(alignment: .topTrailing) {
                        if updateChecker.updateAvailable {
                            Circle()
                                .fill(Color.praxisAccent)
                                .frame(width: 6, height: 6)
                                .offset(x: 4, y: -2)
                        }
                    }
            }
            .buttonStyle(.plain)
            .help(updateChecker.updateAvailable ? "Mise à jour disponible (\(updateChecker.latestVersion ?? ""))" : "Réglages")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var statusLabel: String {
        switch session.recordingState {
        case .idle: return "Prêt"
        case .recording: return "Enregistrement"
        case .paused: return "En pause"
        case .transcribing: return "Transcription…"
        }
    }

    private var statusColor: Color {
        switch session.recordingState {
        case .idle: return .secondary
        case .recording: return .red
        case .paused: return .orange
        case .transcribing: return .praxisAccent
        }
    }
}
