import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers

/// Full CRUD editor for a single task — used for both creation (`existingTask == nil`) and
/// editing. Every field is editable regardless of the task's `origin`: `needsReview` is a
/// visual filter (see TaskRowView), never an edit lock, per the Praxis MVP requirement that
/// Pierre can correct anything, including auto-imported tasks.
struct TaskFormSheet: View {
    @EnvironmentObject private var taskStore: TaskStoreCoordinator
    @EnvironmentObject private var focusTimer: FocusTimerCoordinator
    @Environment(\.dismiss) private var dismiss

    let existingTask: PraxisTask?

    @State private var title: String
    @State private var detail: String
    @State private var type: TaskType
    @State private var selectedCourseVaultPath: String?
    @State private var hasDueDate: Bool
    @State private var dueDate: Date
    @State private var estimatedDurationMinutes: Int
    @State private var blockedReason: String
    @State private var waitingOn: String
    @State private var newSubtaskTitle: String = ""
    /// Default duration offered for a new manual subtask — 30 min per Pierre's ask, but
    /// each row (this one included, once added) stays freely editable afterwards via the
    /// Stepper in `subtasksSection`.
    @State private var newSubtaskMinutes: Int = 30
    @State private var focusTarget: FocusTarget?
    @State private var isDeleteConfirming = false
    /// Walked once when the sheet appears. Building it inside `body` meant re-reading the
    /// whole folder tree on every keystroke in the title field.
    @State private var courseTree: [CourseFolderNode] = []
    @State private var isAttachmentDropTargeted = false

    init(existingTask: PraxisTask?) {
        self.existingTask = existingTask
        _title = State(initialValue: existingTask?.title ?? "")
        _detail = State(initialValue: existingTask?.detail ?? "")
        _type = State(initialValue: existingTask?.type ?? .rendu)
        _selectedCourseVaultPath = State(initialValue: existingTask?.course?.id)
        _hasDueDate = State(initialValue: existingTask?.dueDate != nil)
        _dueDate = State(initialValue: existingTask?.dueDate ?? Date())
        _estimatedDurationMinutes = State(initialValue: existingTask?.estimatedDurationMinutes ?? 60)
        _blockedReason = State(initialValue: existingTask?.blockedReason ?? "")
        _waitingOn = State(initialValue: existingTask?.waitingOn ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(existingTask == nil ? "Nouvelle tâche" : "Modifier la tâche")
                .font(.title3)

            typeSegmentedControl

            TextField("Titre", text: $title)
                .textFieldStyle(.roundedBorder)
                .onChange(of: title) { isDeleteConfirming = false }

            GrowingTextEditor(text: $detail, placeholder: "Détail (optionnel)", minHeight: 44, maxHeight: 180)
                .onChange(of: detail) { isDeleteConfirming = false }

            HStack(spacing: 6) {
                Image(systemName: "book.closed")
                    .foregroundStyle(.secondary)
                Text(selectedCourseLabel)
                    .font(.caption)
                    .foregroundStyle(selectedCourseVaultPath == nil ? .tertiary : .secondary)
                Menu("Changer") {
                    CoursePickerMenu(tree: courseTree) { relativePath in
                        selectedCourseVaultPath = relativePath
                    } trailing: {
                        Button("Aucun") { selectedCourseVaultPath = nil }
                    }
                }
                .font(.caption)
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
                if let selectedCourseVaultPath {
                    Button {
                        openCourseFolder(vaultPath: selectedCourseVaultPath)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Ouvrir le dossier du cours")
                }
            }

            dateSection

            typeSpecificFields

            if let existingTask {
                Divider()
                subtasksSection(for: existingTask)
                Divider()
                attachmentsSection(for: existingTask)
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
                    Button(isDeleteConfirming ? "Confirmer la suppression" : "Supprimer", role: .destructive) {
                        if isDeleteConfirming {
                            deleteTask()
                        } else {
                            isDeleteConfirming = true
                        }
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
        .onAppear { courseTree = CourseFolderTree.build() }
        .sheet(item: $focusTarget) { target in
            FocusTimerView(task: target.task, subtask: target.subtask)
                .environmentObject(focusTimer)
                .environmentObject(taskStore)
                .onDisappear { focusTimer.reset() }
        }
    }

    /// 5 equal segments, custom-built (SwiftUI's `.segmented` picker style truncates/
    /// scrolls with 5 long options) — all 5 types stay visible and comparable at once,
    /// per the design handoff.
    private var typeSegmentedControl: some View {
        HStack(spacing: 2) {
            ForEach(TaskType.allCases, id: \.self) { t in
                Button {
                    type = t
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: t.iconName)
                            .foregroundStyle(t.color)
                        Text(t.shortLabel)
                            .font(.caption2)
                            .foregroundStyle(type == t ? .primary : .secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(type == t ? Color(nsColor: .textBackgroundColor) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color.gray.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private struct FocusTarget: Identifiable {
        let id = UUID()
        let task: PraxisTask?
        let subtask: Subtask?
    }

    // MARK: - Sous-tâches

    /// Only shown once the task already exists (`existingTask != nil`) — a brand-new,
    /// not-yet-saved task has no `PraxisTask` row to attach subtasks to yet. Save the task
    /// once, then reopen it to break it down.
    private func subtasksSection(for task: PraxisTask) -> some View {
        let subtasks = task.subtasks.sorted { $0.order < $1.order }
        let remainingMinutes = subtasks.filter { !$0.isDone }.map(\.estimatedMinutes).reduce(0, +)

        return VStack(alignment: .leading, spacing: 6) {
            if task.hasSubtaskPastDeadline {
                Label("Un jalon est daté après l'échéance de la tâche.", systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            HStack {
                Text("Sous-tâches").font(.caption).foregroundStyle(.secondary)
                if !subtasks.isEmpty {
                    Text("\(subtasks.filter(\.isDone).count)/\(subtasks.count) · \(remainingMinutes) min restantes")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button {
                    focusTarget = FocusTarget(task: task, subtask: nil)
                } label: {
                    Label("Concentration", systemImage: "leaf")
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
                    SubtaskDateButton(subtask: subtask) { taskStore.save() }
                    DurationStepperControl(
                        minutes: subtask.estimatedMinutes,
                        onDecrement: { adjustSubtaskMinutes(subtask, by: -5) },
                        onIncrement: { adjustSubtaskMinutes(subtask, by: 5) },
                        onSetMinutes: { subtask.estimatedMinutes = max(5, $0); taskStore.save() }
                    )
                    Button {
                        focusTarget = FocusTarget(task: nil, subtask: subtask)
                    } label: {
                        Image(systemName: "leaf")
                            .foregroundStyle(Color.praxisAccent)
                    }
                    .buttonStyle(.plain)
                    .help("Démarrer une session de concentration sur cette sous-tâche")
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
                DurationStepperControl(
                    minutes: newSubtaskMinutes,
                    onDecrement: { newSubtaskMinutes = max(5, newSubtaskMinutes - 5) },
                    onIncrement: { newSubtaskMinutes += 5 },
                    onSetMinutes: { newSubtaskMinutes = max(5, $0) }
                )
                Button("Ajouter") { addManualSubtask(to: task) }
                    .disabled(newSubtaskTitle.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    // MARK: - Pièces jointes

    /// Shortcuts to vault files. Dropping a file from inside the vault references it in
    /// place; one from outside is copied into the course's `03 - TD-TP` folder first, so
    /// the attachment always points into the vault. Only shown once the task exists, like
    /// subtasks, since a not-yet-saved task has no row to attach to.
    private func attachmentsSection(for task: PraxisTask) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Pièces jointes").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    pickAttachments(for: task)
                } label: {
                    Label("Ajouter…", systemImage: "paperclip")
                }
                .font(.caption)
            }

            ForEach(task.attachments.sorted { $0.addedAt < $1.addedAt }, id: \.id) { attachment in
                HStack(spacing: 8) {
                    Image(systemName: attachment.exists ? "doc" : "doc.badge.exclamationmark")
                        .foregroundStyle(attachment.exists ? Color.secondary : Color.orange)
                    Button(attachment.displayName) {
                        NSWorkspace.shared.open(attachment.url)
                    }
                    .buttonStyle(.link)
                    .help(attachment.relativePath)
                    Spacer()
                    Button {
                        taskStore.detach(attachment)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Retirer le raccourci. Le fichier reste dans le vault.")
                }
                .font(.callout)
            }

            Text(task.course == nil
                 ? "Déposez un fichier du vault ici."
                 : "Déposez un fichier ici. Hors du vault, il sera copié dans « 03 - TD-TP » de la matière.")
                .font(.caption2)
                .foregroundStyle(isAttachmentDropTargeted ? AnyShapeStyle(Color.praxisAccent) : AnyShapeStyle(.tertiary))
                .frame(maxWidth: .infinity, minHeight: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
                        .foregroundStyle(isAttachmentDropTargeted ? Color.praxisAccent : Color.secondary.opacity(0.3))
                )
                .onDrop(of: [.fileURL], isTargeted: $isAttachmentDropTargeted) { providers in
                    handleAttachmentDrop(providers, for: task)
                }
        }
    }

    private func pickAttachments(for task: PraxisTask) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = task.course.map { VaultSettings.url(forRelativePath: $0.resolvedRelativePath) } ?? VaultSettings.root
        panel.message = "Choisissez les fichiers à joindre"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            taskStore.attach(fileURL: url, to: task)
        }
    }

    private func handleAttachmentDrop(_ providers: [NSItemProvider], for task: PraxisTask) -> Bool {
        var accepted = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            accepted = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    taskStore.attach(fileURL: url, to: task)
                }
            }
        }
        return accepted
    }

    private func addManualSubtask(to task: PraxisTask) {
        let trimmed = newSubtaskTitle.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let subtask = Subtask(
            title: trimmed,
            estimatedMinutes: newSubtaskMinutes,
            order: task.subtasks.count,
            origin: "manuel",
            parentTask: task
        )
        taskStore.modelContext.insert(subtask)
        taskStore.save()
        newSubtaskTitle = ""
        newSubtaskMinutes = 30
    }

    private func adjustSubtaskMinutes(_ subtask: Subtask, by delta: Int) {
        subtask.estimatedMinutes = max(5, subtask.estimatedMinutes + delta)
        taskStore.save()
    }

    private func openCourseFolder(vaultPath: String) {
        NSWorkspace.shared.open(VaultSettings.root.appendingPathComponent(vaultPath))
    }

    private func toggleSubtask(_ subtask: Subtask) {
        subtask.isDone.toggle()
        taskStore.save()
    }

    private func deleteSubtask(_ subtask: Subtask, from task: PraxisTask) {
        taskStore.modelContext.delete(subtask)
        taskStore.save()
    }

    /// Offered for every type, which is the point of this release: a DS, a révision and a
    /// point de blocage can all be dated now. The type only changes what the field is
    /// called and how the date reads on the row.
    @ViewBuilder
    private var dateSection: some View {
        Toggle(dateToggleLabel, isOn: $hasDueDate)
        if hasDueDate {
            DatePicker("", selection: $dueDate, displayedComponents: .date)
                .labelsHidden()
            HStack(spacing: 4) {
                ForEach(TaskScheduling.quickOffsets, id: \.label) { offset in
                    Button("+\(offset.label)") {
                        dueDate = TaskScheduling.date(offsetByDays: offset.days)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Spacer()
                Text(TaskScheduling.countdownLabel(for: dueDate))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var selectedCourseLabel: String {
        guard let selectedCourseVaultPath else { return "Aucune matière" }
        // Shown as the path reads on disk — the levels above a course are whatever the
        // folders are called, not a fixed Année · Pôle pair.
        return selectedCourseVaultPath.split(separator: "/").joined(separator: " · ")
    }

    private var dateToggleLabel: String {
        switch type {
        case .rendu: return "Date limite"
        case .revisionDS: return "Date du DS"
        case .revisionFond: return "À réviser avant le"
        case .blocage: return "À débloquer avant le"
        case .anticipation: return "Date indicative"
        }
    }

    @ViewBuilder
    private var typeSpecificFields: some View {
        switch type {
        case .revisionFond, .revisionDS:
            Stepper("Durée estimée : \(estimatedDurationMinutes) min", value: $estimatedDurationMinutes, in: 15...480, step: 15)
        case .blocage:
            TextField("Raison du blocage", text: $blockedReason)
                .textFieldStyle(.roundedBorder)
            TextField("En attente de…", text: $waitingOn)
                .textFieldStyle(.roundedBorder)
        case .rendu, .anticipation:
            EmptyView()
        }
    }

    private func save() {
        let task = existingTask ?? PraxisTask(title: title, type: type, origin: "manuel")
        task.title = title
        task.detail = detail.isEmpty ? nil : detail
        task.type = type
        task.updatedAt = Date()

        task.course = selectedCourseVaultPath.map { taskStore.findOrCreateCourse(vaultPath: $0) }

        // Unconditional on purpose. Conditioning this on the type is what used to wipe a
        // date the moment a task was reclassified, silently and without warning.
        task.dueDate = hasDueDate ? dueDate : nil
        task.estimatedDurationMinutes = (type == .revisionFond || type == .revisionDS) ? estimatedDurationMinutes : nil
        task.blockedReason = (type == .blocage && !blockedReason.isEmpty) ? blockedReason : nil
        task.waitingOn = (type == .blocage && !waitingOn.isEmpty) ? waitingOn : nil

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

/// −/champ tapable/+, delta 5 min, plancher 5 min — replaces the previous Stepper-only
/// controls (both for existing subtask rows and the new-subtask default row) with one the
/// value can also be typed directly into, per the design handoff.
private struct DurationStepperControl: View {
    let minutes: Int
    let onDecrement: () -> Void
    let onIncrement: () -> Void
    let onSetMinutes: (Int) -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onDecrement) {
                Image(systemName: "minus")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)

            TextField("", value: Binding(get: { minutes }, set: onSetMinutes), formatter: Self.formatter)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .frame(width: 30)

            Text("min")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Button(action: onIncrement) {
                Image(systemName: "plus")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
        }
        .font(.caption)
    }

    private static let formatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.minimum = 5
        return formatter
    }()
}

/// Compact milestone-date control for one subtask: a calendar glyph when unset, the short
/// date when set, and the picker itself tucked into a popover. A full `DatePicker` inline
/// would not fit a row that already carries a title, a duration stepper and two buttons in
/// a 420pt sheet.
private struct SubtaskDateButton: View {
    let subtask: Subtask
    let onChange: () -> Void

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            if let due = subtask.dueDate {
                Text(due.formatted(.dateTime.day().month(.abbreviated)))
                    .font(.caption2)
                    .foregroundStyle(Color.praxisAccent)
            } else {
                Image(systemName: "calendar")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .help(subtask.dueDate == nil ? "Dater ce jalon" : "Modifier la date de ce jalon")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                DatePicker(
                    "",
                    selection: Binding(
                        get: { subtask.dueDate ?? Date() },
                        set: { subtask.dueDate = $0; onChange() }
                    ),
                    displayedComponents: .date
                )
                .labelsHidden()
                .datePickerStyle(.graphical)

                HStack(spacing: 4) {
                    ForEach(TaskScheduling.quickOffsets, id: \.label) { offset in
                        Button("+\(offset.label)") {
                            subtask.dueDate = TaskScheduling.date(offsetByDays: offset.days)
                            onChange()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                if subtask.dueDate != nil {
                    Button("Retirer la date", role: .destructive) {
                        subtask.dueDate = nil
                        onChange()
                        isPresented = false
                    }
                    .controlSize(.small)
                }
            }
            .padding(12)
        }
    }
}

/// A text area that grows with its content, up to a ceiling, then scrolls.
///
/// `TextField(axis: .vertical)` grows but never shows a scrollbar, and `TextEditor` shows
/// one but fills whatever frame it is given. This measures the text with a hidden `Text`
/// laid out at the same width and font, and gives the editor exactly that height clamped
/// between the two bounds — so a one-line detail takes one line, a long one stops at
/// `maxHeight` and gets a scrollbar instead of pushing the rest of the form off screen.
private struct GrowingTextEditor: View {
    @Binding var text: String
    let placeholder: String
    let minHeight: CGFloat
    let maxHeight: CGFloat

    @State private var measuredHeight: CGFloat = 0

    private var height: CGFloat { min(max(measuredHeight, minHeight), maxHeight) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Same font and insets as the editor, so the measure matches what is shown.
            Text(text.isEmpty ? " " : text)
                .font(.body)
                .padding(.horizontal, 5)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .opacity(0)
                .background(
                    GeometryReader { geometry in
                        Color.clear.preference(key: MeasuredHeightKey.self, value: geometry.size.height)
                    }
                )

            if text.isEmpty {
                Text(placeholder)
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
            }

            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
        }
        .frame(height: height)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
        )
        .onPreferenceChange(MeasuredHeightKey.self) { measuredHeight = $0 }
    }

    private struct MeasuredHeightKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }
}
