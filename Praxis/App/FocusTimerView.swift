import SwiftUI

/// Session-picker → countdown → "planté"/"fané" summary, for one `PraxisTask` or `Subtask`.
/// Presented as a sheet from `TaskFormSheet` — task-level or per-subtask via the "🌱"
/// button on each row.
struct FocusTimerView: View {
    @EnvironmentObject private var focusTimer: FocusTimerCoordinator
    @EnvironmentObject private var taskStore: TaskStoreCoordinator
    @Environment(\.dismiss) private var dismiss

    let task: PraxisTask?
    let subtask: Subtask?

    @State private var selectedDuration = 25

    private var targetTitle: String? { subtask?.title ?? task?.title }

    var body: some View {
        VStack(spacing: 20) {
            switch focusTimer.state {
            case .idle:
                idleSetup
            case .running, .paused:
                activeSession
            case .finished(_, let completed):
                finishedSummary(completed: completed)
            }
        }
        .padding(32)
        .frame(width: 360, height: 460)
    }

    private var idleSetup: some View {
        VStack(spacing: 16) {
            Image(systemName: "leaf")
                .font(.system(size: 40))
                .foregroundStyle(Color.praxisAccent)
            Text("Session de concentration").font(.title3)
            if let targetTitle {
                Text(targetTitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Picker("Durée", selection: $selectedDuration) {
                Text("15 min").tag(15)
                Text("25 min").tag(25)
            }
            .pickerStyle(.segmented)
            .frame(width: 220)

            Button("Démarrer") {
                focusTimer.start(durationMinutes: selectedDuration, task: task, subtask: subtask, taskStore: taskStore)
            }
            .buttonStyle(.borderedProminent)
            .tint(.praxisAccent)
        }
    }

    private var activeSession: some View {
        VStack(spacing: 20) {
            GrowingTreeView(growthStage: focusTimer.growthStage, wilted: false)

            Text(formattedTime)
                .font(.system(size: 40, weight: .semibold, design: .rounded))
                .monospacedDigit()

            HStack(spacing: 12) {
                Button(isPaused ? "Reprendre" : "Pause") {
                    isPaused ? focusTimer.resume() : focusTimer.pause()
                }
                .buttonStyle(.bordered)

                Button("Abandonner", role: .destructive) {
                    focusTimer.abandon()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func finishedSummary(completed: Bool) -> some View {
        VStack(spacing: 16) {
            GrowingTreeView(growthStage: completed ? 1.0 : focusTimer.growthStage, wilted: !completed)

            Text(completed ? "Session terminée — arbre planté 🌳" : "Session abandonnée")
                .font(.title3)
                .multilineTextAlignment(.center)

            Button("Fermer") {
                focusTimer.reset()
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .tint(.praxisAccent)
        }
    }

    private var isPaused: Bool {
        if case .paused = focusTimer.state { return true }
        return false
    }

    private var formattedTime: String {
        String(format: "%02d:%02d", focusTimer.remainingSeconds / 60, focusTimer.remainingSeconds % 60)
    }
}

/// Drawn entirely in SwiftUI (no image asset) — trunk height and foliage size scale with
/// `growthStage` (0...1). `wilted` desaturates everything for the "abandoned" state, kept
/// visually distinct from the "completed" green/full tree.
private struct GrowingTreeView: View {
    let growthStage: Double
    let wilted: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            Capsule()
                .fill(trunkColor)
                .frame(width: 12, height: 10 + 70 * stage)

            if stage > 0.15 {
                ForEach(0..<3, id: \.self) { layer in
                    Circle()
                        .fill(foliageColor.opacity(0.9 - Double(layer) * 0.15))
                        .frame(
                            width: foliageDiameter - CGFloat(layer) * 14,
                            height: foliageDiameter - CGFloat(layer) * 14
                        )
                        .offset(y: -foliageOffsetY + CGFloat(layer) * 6)
                }
            }

            if stage >= 1.0 && !wilted {
                Image(systemName: "checkmark.seal.fill")
                    .font(.title)
                    .foregroundStyle(.white, Color.praxisAccent)
                    .offset(y: -foliageOffsetY - 46)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: 180, height: 180)
        .animation(.easeInOut(duration: 0.6), value: growthStage)
        .animation(.easeInOut, value: wilted)
    }

    private var stage: CGFloat { CGFloat(min(1.0, max(0.0, growthStage))) }
    private var trunkColor: Color { wilted ? Color.brown.opacity(0.35) : .brown }
    private var foliageColor: Color { wilted ? Color.gray.opacity(0.4) : .green }
    private var foliageDiameter: CGFloat { 40 + 70 * stage }
    private var foliageOffsetY: CGFloat { 10 + 70 * stage }
}
