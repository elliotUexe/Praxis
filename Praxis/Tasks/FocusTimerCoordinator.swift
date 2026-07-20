import Foundation

enum FocusState: Equatable {
    case idle
    case running(session: FocusSession)
    case paused(session: FocusSession)
    case finished(session: FocusSession, completed: Bool)

    static func == (lhs: FocusState, rhs: FocusState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle): return true
        case (.running(let a), .running(let b)): return a.id == b.id
        case (.paused(let a), .paused(let b)): return a.id == b.id
        case (.finished(let a, let ac), .finished(let b, let bc)): return a.id == b.id && ac == bc
        default: return false
        }
    }
}

/// One concentration timer at a time, app-wide (like `AppSessionStore`) — a session keeps
/// running even if Pierre navigates away from the Tâches section. Same 1s-`Timer` pattern
/// as `AppSessionStore.startTimer()`. Every session is persisted as a `FocusSession`, on
/// completion *and* on abandon, rather than discarded — "planté" vs "fané" in
/// `FocusTimerView` is read straight off `wasCompleted`.
@MainActor
final class FocusTimerCoordinator: ObservableObject {
    @Published private(set) var state: FocusState = .idle
    @Published private(set) var remainingSeconds: Int = 0
    @Published private(set) var plannedSeconds: Int = 0

    private var timer: Timer?
    private weak var taskStore: TaskStoreCoordinator?

    var isActive: Bool {
        switch state {
        case .idle, .finished: return false
        case .running, .paused: return true
        }
    }

    /// 0.0 (seed) → 1.0 (fully grown) — drives `GrowingTreeView`.
    var growthStage: Double {
        guard plannedSeconds > 0 else { return 0 }
        let elapsed = plannedSeconds - remainingSeconds
        return min(1.0, max(0.0, Double(elapsed) / Double(plannedSeconds)))
    }

    func start(
        durationMinutes: Int,
        task: PraxisTask?,
        subtask: Subtask?,
        taskStore: TaskStoreCoordinator
    ) {
        self.taskStore = taskStore
        let session = FocusSession(plannedDurationMinutes: durationMinutes, linkedTask: task, linkedSubtask: subtask)
        taskStore.modelContext.insert(session)
        taskStore.save()

        plannedSeconds = durationMinutes * 60
        remainingSeconds = plannedSeconds
        state = .running(session: session)
        restartTicking()
    }

    func pause() {
        guard case .running(let session) = state else { return }
        timer?.invalidate()
        timer = nil
        state = .paused(session: session)
    }

    func resume() {
        guard case .paused(let session) = state else { return }
        state = .running(session: session)
        restartTicking()
    }

    /// Ends the session early — logged as `wasCompleted = false`, never silently discarded.
    func abandon() {
        guard let session = currentSession else { return }
        timer?.invalidate()
        timer = nil
        session.wasCompleted = false
        session.completedAt = Date()
        taskStore?.save()
        state = .finished(session: session, completed: false)
    }

    /// Closes the "planté"/"fané" summary and resets to idle — call when the sheet dismisses.
    func reset() {
        timer?.invalidate()
        timer = nil
        state = .idle
        remainingSeconds = 0
        plannedSeconds = 0
    }

    private var currentSession: FocusSession? {
        switch state {
        case .running(let session), .paused(let session), .finished(let session, _): return session
        case .idle: return nil
        }
    }

    private func restartTicking() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard case .running(let session) = state else { return }
        remainingSeconds = max(0, remainingSeconds - 1)
        guard remainingSeconds == 0 else { return }

        timer?.invalidate()
        timer = nil
        session.wasCompleted = true
        session.completedAt = Date()
        taskStore?.save()
        state = .finished(session: session, completed: true)
    }
}
