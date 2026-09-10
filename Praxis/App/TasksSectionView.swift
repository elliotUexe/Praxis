import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers

/// "Tâches" section — the real Praxis MVP dashboard: CRUD on all 5 task types, grouped by
/// type, with full edit access regardless of a task's origin (manual or auto-imported).
struct TasksSectionView: View {
    @EnvironmentObject private var taskStore: TaskStoreCoordinator
    @EnvironmentObject private var localLLM: LocalLLMCoordinator
    @EnvironmentObject private var focusTimer: FocusTimerCoordinator
    @Query(filter: #Predicate<PraxisTask> { !$0.isRejected }, sort: \PraxisTask.createdAt, order: .reverse)
    private var allTasks: [PraxisTask]
    @Query(filter: #Predicate<PraxisTask> { $0.isRejected }, sort: \PraxisTask.updatedAt, order: .reverse)
    private var rejectedTasks: [PraxisTask]
    @State private var isRejectedTasksPresented = false

    /// Vault path of the course to filter on, nil = toutes les matières. Owned by
    /// `ContentView` so Accueil can navigate here with a course already selected.
    @Binding var courseFilter: String?

    @State private var editingTask: PraxisTask?
    @State private var isCreatingTask = false
    @State private var isTriagePresented = false
    /// Folded sections, seeded from `TaskHorizon.startsCollapsed`. Held as raw values so the
    /// set survives without `TaskHorizon` needing to be `Hashable` for anything else.
    @State private var collapsedHorizons: Set<Int> = Set(
        TaskHorizon.allCases.filter(\.startsCollapsed).map(\.rawValue)
    )

    /// Everything below this point reads `visibleTasks`, never `allTasks` directly, so the
    /// course filter applies uniformly to the list, the counts, and the export menu.
    private var visibleTasks: [PraxisTask] {
        guard let courseFilter else { return allTasks }
        return allTasks.filter { $0.course?.id == courseFilter }
    }

    private var needsReviewCount: Int { visibleTasks.filter { $0.needsReview && !$0.isDone }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            courseFilterBar
            Divider()
            taskListByHorizon
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheet(item: $editingTask) { task in
            TaskFormSheet(existingTask: task)
                .environmentObject(taskStore)
                .environmentObject(localLLM)
                .environmentObject(focusTimer)
        }
        .sheet(isPresented: $isCreatingTask) {
            TaskFormSheet(existingTask: nil)
                .environmentObject(taskStore)
                .environmentObject(localLLM)
                .environmentObject(focusTimer)
        }
        .sheet(isPresented: $isTriagePresented) {
            TaskTriageView()
                .environmentObject(taskStore)
                .environmentObject(localLLM)
                .environmentObject(focusTimer)
        }
        .sheet(isPresented: $isRejectedTasksPresented) {
            RejectedTasksView(rejectedTasks: rejectedTasks)
                .environmentObject(taskStore)
        }
    }

    /// Two things stay visible: triage, because it is work waiting on you, and the primary
    /// action. Export, import checks and the rejected archive are maintenance — they used to
    /// sit in the same row as "Nouvelle tâche", five controls wide, drowning the one button
    /// that matters.
    private var header: some View {
        HStack(spacing: 8) {
            Text("Tâches").font(.title3)
            Spacer()

            if needsReviewCount > 0 {
                Button {
                    isTriagePresented = true
                } label: {
                    Label("Trier (\(needsReviewCount))", systemImage: "checklist")
                }
            }

            Menu {
                Button("Créer depuis le presse-papiers", systemImage: "doc.on.clipboard") {
                    createFromClipboard()
                }
                .disabled(clipboardText == nil)

                Divider()

                Menu("Exporter") {
                    Button("Toutes les tâches") { exportTasks(course: nil) }
                    if !coursesWithTasks.isEmpty {
                        Divider()
                        ForEach(coursesWithTasks, id: \.id) { course in
                            Button(course.displayName) { exportTasks(course: course) }
                        }
                    }
                }
                .disabled(allTasks.isEmpty)

                Button("Importer un fichier JSON…", systemImage: "square.and.arrow.down") {
                    importTasksFromFile()
                }

                if !rejectedTasks.isEmpty {
                    Divider()
                    Button("Tâches rejetées (\(rejectedTasks.count))", systemImage: "archivebox") {
                        isRejectedTasksPresented = true
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button {
                isCreatingTask = true
            } label: {
                Label("Nouvelle tâche", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    /// Filter chips: "Toutes" + one per course that actually has tasks, plus a "Sans
    /// cours" escape hatch since a task's `course` is optional. Deliberately not a Menu —
    /// when Accueil navigates here with a filter pre-applied, the active state has to be
    /// visible at a glance, otherwise the list silently looks like it lost tasks.
    @ViewBuilder
    private var courseFilterBar: some View {
        if !coursesWithTasks.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    filterChip(label: "Toutes", isActive: courseFilter == nil) { courseFilter = nil }
                    ForEach(coursesWithTasks, id: \.id) { course in
                        filterChip(
                            label: course.displayName,
                            isActive: courseFilter == course.id
                        ) {
                            courseFilter = (courseFilter == course.id) ? nil : course.id
                        }
                    }
                }
            }
        }
    }

    private func filterChip(label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption)
                .foregroundStyle(isActive ? Color.white : Color.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(isActive ? Color.praxisAccent : Color.gray.opacity(0.12))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Distinct courses that actually have at least one task — populates both the filter
    /// chips and the per-course export menu without a separate fetch (Course doesn't need
    /// Hashable/Equatable conformance this way, just identity comparison on the vault-path
    /// `id`). Always computed from `allTasks`, never `visibleTasks` — otherwise applying a
    /// filter would erase every other course from the bar and strand Pierre there.
    private var coursesWithTasks: [Course] {
        var seen = Set<String>()
        var result: [Course] = []
        for task in allTasks where !task.isDone {
            guard let course = task.course, !seen.contains(course.id) else { continue }
            seen.insert(course.id)
            result.append(course)
        }
        // The course being filtered on always keeps its chip, even once its last open task
        // is ticked off. Without this, finishing that task makes the chip vanish and leaves
        // you looking at an empty list filtered on a subject with no button to leave it.
        if let courseFilter, !seen.contains(courseFilter),
           let active = allTasks.compactMap(\.course).first(where: { $0.id == courseFilter }) {
            result.append(active)
        }
        return result.sorted { $0.displayName < $1.displayName }
    }

    /// Phase 4: on-demand file export via NSSavePanel — deliberately not an automatic
    /// vault write. Pre-fills the course's own folder as the save location for
    /// convenience only; Pierre confirms (or changes) it every time.
    /// Parameter deliberately named `course`, not `courseFilter` — the latter would shadow
    /// the view's `@Binding var courseFilter` inside this body. Export always works off
    /// `allTasks`: the export menu picks its own scope explicitly, independent of whatever
    /// the on-screen filter chips happen to be showing.
    private func exportTasks(course: Course?) {
        let tasksToExport = course == nil
            ? allTasks
            : allTasks.filter { $0.course?.id == course?.id }
        guard !tasksToExport.isEmpty else { return }

        let tag = course.map { "imt/\(slug($0.displayName))" }
        let markdown = TaskMarkdownExporter.markdown(
            for: tasksToExport,
            courseDisplayName: course?.displayName,
            tag: tag
        )

        let panel = NSSavePanel()
        panel.nameFieldStringValue = TaskMarkdownExporter.suggestedFilename(courseDisplayName: course?.displayName)
        panel.message = "Choisissez où enregistrer l'export des tâches"
        panel.directoryURL = course.map { VaultSettings.root.appendingPathComponent($0.id) } ?? VaultSettings.root
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? markdown.write(to: url, atomically: true, encoding: .utf8)
    }

    private func slug(_ name: String) -> String {
        name.lowercased()
            .folding(options: .diacriticInsensitive, locale: .current)
            .replacingOccurrences(of: " ", with: "-")
    }

    /// Turns whatever is on the clipboard into a task. Replaces a text field that occupied a
    /// full row permanently for an occasional use: the text is already in the clipboard when
    /// you reach for this, so asking you to paste it into a box first was a step for nothing.
    private var clipboardText: String? {
        let text = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty == false) ? text : nil
    }

    /// Chosen rather than watched: the batch used to be picked up from a folder inside one
    /// particular vault, which stops existing once the root is a setting.
    private func importTasksFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choisissez le fichier de tâches à importer"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        taskStore.importTasks(from: url)
    }

    private func createFromClipboard() {
        guard let text = clipboardText else { return }
        let task = PraxisTask(title: text, type: TaskType(detectedFrom: text), origin: "manuel")
        taskStore.modelContext.insert(task)
        taskStore.save()
    }

    /// Open tasks bucketed by when they are due, sorted soonest first inside each bucket.
    ///
    /// The list used to be cut up by `TaskType` and ordered by creation date, which meant a
    /// rendu due tomorrow sat below one due in March purely because it was typed in later.
    /// Nothing on screen said what pressed. Type is still on every row, it just no longer
    /// decides the shape of the list.
    private var tasksByHorizon: [TaskHorizon: [PraxisTask]] {
        let open = visibleTasks.filter { !$0.isDone }
        return Dictionary(grouping: open, by: \.horizon).mapValues { tasks in
            tasks.sorted { left, right in
                switch (left.effectiveDueDate, right.effectiveDueDate) {
                case let (l?, r?) where l != r: return l < r
                // Undated tasks have nothing to rank them by, so the most recently written
                // down comes first — it is the one still fresh in mind.
                default: return left.createdAt > right.createdAt
                }
            }
        }
    }

    private var taskListByHorizon: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                let grouped = tasksByHorizon
                ForEach(TaskHorizon.allCases) { horizon in
                    if let tasks = grouped[horizon], !tasks.isEmpty {
                        horizonSection(horizon, tasks: tasks)
                    }
                }

                let doneTasks = visibleTasks.filter(\.isDone)
                if !doneTasks.isEmpty {
                    DisclosureGroup("Terminées (\(doneTasks.count))") {
                        ForEach(doneTasks) { task in
                            TaskRowView(
                                task: task,
                                onToggleDone: { toggleDone(task) },
                                onTap: { editingTask = task }
                            )
                        }
                    }
                }

                if visibleTasks.isEmpty {
                    Text(courseFilter == nil
                         ? "Aucune tâche pour l'instant."
                         : "Aucune tâche pour cette matière.")
                        .foregroundStyle(.tertiary)
                        .padding(.top, 20)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func horizonSection(_ horizon: TaskHorizon, tasks: [PraxisTask]) -> some View {
        let isCollapsed = collapsedHorizons.contains(horizon.rawValue)
        VStack(alignment: .leading, spacing: 2) {
            Button {
                if isCollapsed {
                    collapsedHorizons.remove(horizon.rawValue)
                } else {
                    collapsedHorizons.insert(horizon.rawValue)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(horizon.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(horizon == .overdue ? Color.red : .primary)
                    Text("\(tasks.count)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isCollapsed {
                ForEach(tasks) { task in
                    TaskRowView(
                        task: task,
                        onToggleDone: { toggleDone(task) },
                        onTap: { editingTask = task }
                    )
                }
            }
        }
    }

    private func toggleDone(_ task: PraxisTask) {
        task.isDone.toggle()
        task.completedAt = task.isDone ? Date() : nil
        task.updatedAt = Date()
        taskStore.save()
    }
}
