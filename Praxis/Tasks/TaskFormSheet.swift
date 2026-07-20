import SwiftUI
import SwiftData

/// Full CRUD editor for a single task — used for both creation (`existingTask == nil`) and
/// editing. Every field is editable regardless of the task's `origin`: `needsReview` is a
/// visual filter (see TaskRowView), never an edit lock, per the Praxis MVP requirement that
/// Pierre can correct anything, including auto-imported tasks.
struct TaskFormSheet: View {
    @EnvironmentObject private var taskStore: TaskStoreCoordinator
    @EnvironmentObject private var localLLM: LocalLLMCoordinator
    @Environment(\.dismiss) private var dismiss

    let existingTask: PraxisTask?
    let availableCourses: [CourseOption]

    @State private var title: String
    @State private var detail: String
    @State private var type: TaskType
    @State private var selectedCourseVaultPath: String?
    @State private var hasDueDate: Bool
    @State private var dueDate: Date
    @State private var estimatedDurationMinutes: Int
    @State private var blockedReason: String
    @State private var waitingOn: String
    @State private var hasHorizonDate: Bool
    @State private var horizonDate: Date
    @State private var isSubtaskProposalPresented = false
    @State private var newSubtaskTitle: String = ""

    init(existingTask: PraxisTask?, availableCourses: [CourseOption]) {
        self.existingTask = existingTask
        self.availableCourses = availableCourses
        _title = State(initialValue: existingTask?.title ?? "")
        _detail = State(initialValue: existingTask?.detail ?? "")
        _type = State(initialValue: existingTask?.type ?? .rendu)
        _selectedCourseVaultPath = State(initialValue: existingTask?.course?.id)
        _hasDueDate = State(initialValue: existingTask?.dueDate != nil)
        _dueDate = State(initialValue: existingTask?.dueDate ?? Date())
        _estimatedDurationMinutes = State(initialValue: existingTask?.estimatedDurationMinutes ?? 60)
        _blockedReason = State(initialValue: existingTask?.blockedReason ?? "")
        _waitingOn = State(initialValue: existingTask?.waitingOn ?? "")
        _hasHorizonDate = State(initialValue: existingTask?.horizonDate != nil)
        _horizonDate = State(initialValue: existingTask?.horizonDate ?? Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(existingTask == nil ? "Nouvelle tâche" : "Modifier la tâche")
                .font(.title3)

            Picker("Type", selection: $type) {
                ForEach(TaskType.allCases, id: \.self) { t in
                    Text(t.displayName).tag(t)
                }
            }

            TextField("Titre", text: $title)
                .textFieldStyle(.roundedBorder)

            TextField("Détail (optionnel)", text: $detail, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)

            Picker("Cours", selection: $selectedCourseVaultPath) {
                Text("Aucun").tag(String?.none)
                ForEach(availableCourses) { course in
                    Text("\(course.year) · \(course.pole) · \(course.displayName)")
                        .tag(String?.some(course.vaultPath))
                }
            }

            typeSpecificFields

            if let existingTask {
                Divider()
                subtasksSection(for: existingTask)
            }

            if let existingTask, !existingTask.comments.isEmpty {
                Divider()
                Text("Commentaires").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(existingTask.comments.sorted { $0.createdAt < $1.createdAt }) { comment in
                            Text("• \(comment.text)")
                                .font(.caption)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 100)
            }

            Spacer(minLength: 0)

            HStack {
                if existingTask != nil {
                    Button("Supprimer", role: .destructive) {
                        deleteTask()
                    }
                }
                Spacer()
                Button("Annuler") { dismiss() }
                Button("Enregistrer") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(width: 420)
        .sheet(isPresented: $isSubtaskProposalPresented) {
            if let existingTask {
                SubtaskProposalView(task: existingTask)
                    .environmentObject(taskStore)
                    .environmentObject(localLLM)
            }
        }
    }

    // MARK: - Sous-tâches

    /// Only shown once the task already exists (`existingTask != nil`) — a brand-new,
    /// not-yet-saved task has no `PraxisTask` row to attach subtasks to yet. Save the task
    /// once, then reopen it to break it down.
    private func subtasksSection(for task: PraxisTask) -> some View {
        let subtasks = task.subtasks.sorted { $0.order < $1.order }
        let remainingMinutes = subtasks.filter { !$0.isDone }.map(\.estimatedMinutes).reduce(0, +)

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Sous-tâches").font(.caption).foregroundStyle(.secondary)
                if !subtasks.isEmpty {
                    Text("\(subtasks.filter(\.isDone).count)/\(subtasks.count) · \(remainingMinutes) min restantes")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button {
                    isSubtaskProposalPresented = true
                } label: {
                    Label("Découper avec l'IA", systemImage: "sparkles")
                }
                .font(.caption)
            }

            ForEach(subtasks) { subtask in
                HStack(spacing: 8) {
                    Button {
                        toggleSubtask(subtask)
                    } label: {
                        Image(systemName: subtask.isDone ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(subtask.isDone ? .green : .secondary)
                    }
                    .buttonStyle(.plain)

                    Text(subtask.title)
                        .strikethrough(subtask.isDone)
                        .foregroundStyle(subtask.isDone ? .secondary : .primary)
                    Spacer()
                    Text("\(subtask.estimatedMinutes) min")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        deleteSubtask(subtask, from: task)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
                .font(.callout)
            }

            HStack {
                TextField("Ajouter une sous-tâche…", text: $newSubtaskTitle)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addManualSubtask(to: task) }
                Button("Ajouter") { addManualSubtask(to: task) }
                    .disabled(newSubtaskTitle.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func addManualSubtask(to task: PraxisTask) {
        let trimmed = newSubtaskTitle.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let subtask = Subtask(
            title: trimmed,
            estimatedMinutes: 30,
            order: task.subtasks.count,
            origin: "manuel",
            parentTask: task
        )
        taskStore.modelContext.insert(subtask)
        taskStore.save()
        newSubtaskTitle = ""
    }

    private func toggleSubtask(_ subtask: Subtask) {
        subtask.isDone.toggle()
        taskStore.save()
    }

    private func deleteSubtask(_ subtask: Subtask, from task: PraxisTask) {
        taskStore.modelContext.delete(subtask)
        taskStore.save()
    }

    @ViewBuilder
    private var typeSpecificFields: some View {
        switch type {
        case .rendu:
            Toggle("Échéance", isOn: $hasDueDate)
            if hasDueDate {
                DatePicker("Date limite", selection: $dueDate, displayedComponents: .date)
            }
        case .revisionFond, .revisionDS:
            Stepper("Durée estimée : \(estimatedDurationMinutes) min", value: $estimatedDurationMinutes, in: 15...480, step: 15)
        case .blocage:
            TextField("Raison du blocage", text: $blockedReason)
                .textFieldStyle(.roundedBorder)
            TextField("En attente de…", text: $waitingOn)
                .textFieldStyle(.roundedBorder)
        case .anticipation:
            Toggle("Horizon", isOn: $hasHorizonDate)
            if hasHorizonDate {
                DatePicker("Date indicative", selection: $horizonDate, displayedComponents: .date)
            }
        }
    }

    private func save() {
        let task = existingTask ?? PraxisTask(title: title, type: type, origin: "manuel")
        task.title = title
        task.detail = detail.isEmpty ? nil : detail
        task.type = type
        task.updatedAt = Date()

        task.course = selectedCourseVaultPath.map { taskStore.findOrCreateCourse(vaultPath: $0) }

        task.dueDate = (type == .rendu && hasDueDate) ? dueDate : nil
        task.estimatedDurationMinutes = (type == .revisionFond || type == .revisionDS) ? estimatedDurationMinutes : nil
        task.blockedReason = (type == .blocage && !blockedReason.isEmpty) ? blockedReason : nil
        task.waitingOn = (type == .blocage && !waitingOn.isEmpty) ? waitingOn : nil
        task.horizonDate = (type == .anticipation && hasHorizonDate) ? horizonDate : nil

        if existingTask == nil {
            taskStore.modelContext.insert(task)
        }
        taskStore.save()
        dismiss()
    }

    private func deleteTask() {
        guard let existingTask else { return }
        taskStore.modelContext.delete(existingTask)
        taskStore.save()
        dismiss()
    }
}
