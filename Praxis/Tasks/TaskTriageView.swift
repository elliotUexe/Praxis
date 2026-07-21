import SwiftUI
import SwiftData

/// Keyboard-driven review queue for auto-extracted tasks (`needsReview == true`) — "A"
/// accepts (keeps the task, clears the review flag), "R" rejects (archives via
/// `isRejected` rather than deleting — see `RejectedTasksView` for restore/permanent
/// delete, per Pierre's explicit "archiver, pas supprimer" call), "Entrée" opens the full
/// edit sheet, arrow keys move the selection.
struct TaskTriageView: View {
    @EnvironmentObject private var taskStore: TaskStoreCoordinator
    @EnvironmentObject private var localLLM: LocalLLMCoordinator
    @EnvironmentObject private var focusTimer: FocusTimerCoordinator
    @Environment(\.dismiss) private var dismiss

    @Query(
        filter: #Predicate<PraxisTask> { $0.needsReview && !$0.isDone && !$0.isRejected },
        sort: \PraxisTask.createdAt
    )
    private var queue: [PraxisTask]

    @State private var selectedIndex = 0
    @State private var editingTask: PraxisTask?
    // Fully qualified: this app also declares its own `FocusState` enum
    // (FocusTimerCoordinator.swift, for the concentration timer) which shadows SwiftUI's
    // `@FocusState` property wrapper within this module.
    @SwiftUI.FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Trier les tâches").font(.title3)
                Spacer()
                Text("A accepter · R rejeter · Entrée modifier · ↑↓ naviguer")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Button("Fermer") { dismiss() }
            }

            if queue.isEmpty {
                Text("Rien à trier.")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(Array(queue.enumerated()), id: \.element.id) { index, task in
                            triageCard(task, isSelected: index == selectedIndex)
                                .onTapGesture { selectedIndex = index }
                        }
                    }
                }
            }
        }
        .padding()
        .frame(width: 480, height: 520)
        .focusable()
        .focused($isFocused)
        .onAppear {
            isFocused = true
            selectedIndex = 0
        }
        .onKeyPress(action: handleKeyPress)
        .sheet(item: $editingTask) { task in
            TaskFormSheet(existingTask: task, availableCourses: CourseDirectoryScanner.scan())
                .environmentObject(taskStore)
                .environmentObject(localLLM)
                .environmentObject(focusTimer)
        }
    }

    private func triageCard(_ task: PraxisTask, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: task.type.iconName)
                .foregroundStyle(task.type.color)
                .frame(width: 22, height: 22)
                .background(task.type.color.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title).font(.callout)
                if let courseName = task.course?.displayName {
                    Text(courseName).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()

            Button { accept(task) } label: {
                Image(systemName: "checkmark")
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .background(Color.green.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .help("Accepter (A)")

            Button { reject(task) } label: {
                Image(systemName: "xmark")
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .background(Color.red.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .help("Rejeter (R)")
        }
        .padding(8)
        .background(isSelected ? Color.praxisAccent.opacity(0.12) : Color.gray.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func handleKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        guard !queue.isEmpty else { return .ignored }
        switch keyPress.key {
        case .upArrow:
            selectedIndex = max(0, selectedIndex - 1)
            return .handled
        case .downArrow:
            selectedIndex = min(queue.count - 1, selectedIndex + 1)
            return .handled
        case .return:
            if queue.indices.contains(selectedIndex) { editingTask = queue[selectedIndex] }
            return .handled
        default:
            break
        }
        switch keyPress.characters.lowercased() {
        case "a":
            if queue.indices.contains(selectedIndex) { accept(queue[selectedIndex]) }
            return .handled
        case "r":
            if queue.indices.contains(selectedIndex) { reject(queue[selectedIndex]) }
            return .handled
        default:
            return .ignored
        }
    }

    private func accept(_ task: PraxisTask) {
        withAnimation(.easeOut(duration: 0.3)) {
            task.needsReview = false
            task.updatedAt = Date()
        }
        taskStore.save()
        selectedIndex = min(selectedIndex, max(0, queue.count - 1))
    }

    private func reject(_ task: PraxisTask) {
        withAnimation(.easeOut(duration: 0.3)) {
            task.isRejected = true
            task.needsReview = false
            task.updatedAt = Date()
        }
        taskStore.save()
        selectedIndex = min(selectedIndex, max(0, queue.count - 1))
    }
}

/// Rejected tasks are archived, not deleted — this is the only place they're visible
/// again, with a way back (restore) or a real delete for tasks that truly don't matter.
struct RejectedTasksView: View {
    @EnvironmentObject private var taskStore: TaskStoreCoordinator
    @Environment(\.dismiss) private var dismiss
    let rejectedTasks: [PraxisTask]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Tâches rejetées").font(.title3)
                Spacer()
                Button("Fermer") { dismiss() }
            }

            if rejectedTasks.isEmpty {
                Text("Aucune tâche rejetée.")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
            } else {
                List {
                    ForEach(rejectedTasks) { task in
                        HStack(spacing: 8) {
                            Image(systemName: task.type.iconName)
                                .foregroundStyle(task.type.color)
                            Text(task.title)
                                .strikethrough()
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Restaurer") { restore(task) }
                                .font(.caption)
                            Button {
                                delete(task)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.red)
                        }
                    }
                }
            }
        }
        .padding()
        .frame(width: 420, height: 420)
    }

    private func restore(_ task: PraxisTask) {
        task.isRejected = false
        task.updatedAt = Date()
        taskStore.save()
    }

    private func delete(_ task: PraxisTask) {
        taskStore.modelContext.delete(task)
        taskStore.save()
    }
}
