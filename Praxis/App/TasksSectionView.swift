import SwiftUI
import SwiftData
import AppKit

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

    @State private var availableCourses: [CourseOption] = []
    @State private var editingTask: PraxisTask?
    @State private var isCreatingTask = false
    @State private var isTriagePresented = false
    @State private var pasteText: String = ""

    private var needsReviewCount: Int { allTasks.filter { $0.needsReview && !$0.isDone }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            pasteImportRow
            Divider()
            taskListByType
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            availableCourses = CourseDirectoryScanner.scan()
        }
        .sheet(item: $editingTask) { task in
            TaskFormSheet(existingTask: task, availableCourses: availableCourses)
                .environmentObject(taskStore)
                .environmentObject(localLLM)
                .environmentObject(focusTimer)
        }
        .sheet(isPresented: $isCreatingTask) {
            TaskFormSheet(existingTask: nil, availableCourses: availableCourses)
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

    private var header: some View {
        HStack {
            Text("Tâches").font(.title3)
            Spacer()
            if needsReviewCount > 0 {
                Button {
                    isTriagePresented = true
                } label: {
                    Label("Trier (\(needsReviewCount))", systemImage: "checklist")
                }
            }
            if !rejectedTasks.isEmpty {
                Button {
                    isRejectedTasksPresented = true
                } label: {
                    Label("Rejetées (\(rejectedTasks.count))", systemImage: "archivebox")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Button {
                taskStore.scanPendingImports()
            } label: {
                Label("Vérifier les imports", systemImage: "arrow.triangle.2.circlepath")
            }
            Menu {
                Button("Toutes les tâches") { exportTasks(courseFilter: nil) }
                    .disabled(allTasks.isEmpty)
                if !coursesWithTasks.isEmpty {
                    Divider()
                    ForEach(coursesWithTasks, id: \.id) { course in
                        Button(course.displayName) { exportTasks(courseFilter: course) }
                    }
                }
            } label: {
                Label("Exporter", systemImage: "square.and.arrow.up")
            }
            .disabled(allTasks.isEmpty)
            .fixedSize()

            Button {
                isCreatingTask = true
            } label: {
                Label("Nouvelle tâche", systemImage: "plus")
            }
        }
    }

    /// Distinct courses that actually have at least one task — populates the per-course
    /// export menu without a separate fetch (Course doesn't need Hashable/Equatable
    /// conformance this way, just identity comparison on the vault-path `id`).
    private var coursesWithTasks: [Course] {
        var seen = Set<String>()
        var result: [Course] = []
        for task in allTasks {
            guard let course = task.course, !seen.contains(course.id) else { continue }
            seen.insert(course.id)
            result.append(course)
        }
        return result.sorted { $0.displayName < $1.displayName }
    }

    /// Phase 4: on-demand file export via NSSavePanel — deliberately not an automatic
    /// vault write. Pre-fills the course's own folder as the save location for
    /// convenience only; Pierre confirms (or changes) it every time.
    private func exportTasks(courseFilter: Course?) {
        let tasksToExport = courseFilter == nil
            ? allTasks
            : allTasks.filter { $0.course?.id == courseFilter?.id }
        guard !tasksToExport.isEmpty else { return }

        let tag = courseFilter.map { "imt/\(slug($0.displayName))" }
        let markdown = TaskMarkdownExporter.markdown(
            for: tasksToExport,
            courseDisplayName: courseFilter?.displayName,
            tag: tag
        )

        let panel = NSSavePanel()
        panel.nameFieldStringValue = TaskMarkdownExporter.suggestedFilename(courseDisplayName: courseFilter?.displayName)
        panel.message = "Choisissez où enregistrer l'export des tâches"
        panel.directoryURL = courseFilter.map { VaultPaths.root.appendingPathComponent($0.id) } ?? VaultPaths.root
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? markdown.write(to: url, atomically: true, encoding: .utf8)
    }

    private func slug(_ name: String) -> String {
        name.lowercased()
            .folding(options: .diacriticInsensitive, locale: .current)
            .replacingOccurrences(of: " ", with: "-")
    }

    /// Direct-creation path for pasted free text (no LLM extraction yet — that's Phase 5).
    /// Useful today for retroactively turning a note, a pasted email, etc. into a task.
    private var pasteImportRow: some View {
        HStack {
            TextField("Coller du texte pour créer une tâche…", text: $pasteText)
                .textFieldStyle(.roundedBorder)
                .onSubmit(createFromPastedText)
            Button("Créer") { createFromPastedText() }
                .disabled(pasteText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func createFromPastedText() {
        let trimmed = pasteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let task = PraxisTask(title: trimmed, type: Self.detectType(from: trimmed), origin: "manuel")
        taskStore.modelContext.insert(task)
        taskStore.save()
        pasteText = ""
    }

    /// Simple keyword heuristic, not an LLM call (pasted text creates a task instantly,
    /// no local-model round-trip) — good enough to avoid every quick paste defaulting to
    /// "Anticipation" when it's obviously a deadline or an exam to revise for.
    private static func detectType(from text: String) -> TaskType {
        let normalized = text.lowercased().folding(options: .diacriticInsensitive, locale: .current)
        let dsKeywords = ["ds ", " ds", "examen", "controle", "partiel"]
        if dsKeywords.contains(where: normalized.contains) {
            return .revisionDS
        }
        let renduKeywords = ["rendre", "rendu", "deadline", "a rendre", "date limite", "avant le"]
        if renduKeywords.contains(where: normalized.contains) {
            return .rendu
        }
        return .anticipation
    }

    private var taskListByType: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(TaskType.allCases, id: \.self) { type in
                    let tasksForType = allTasks.filter { $0.type == type && !$0.isDone }
                    if !tasksForType.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(type.displayName)
                                .font(.headline)
                            ForEach(tasksForType) { task in
                                TaskRowView(
                                    task: task,
                                    onToggleDone: { toggleDone(task) },
                                    onTap: { editingTask = task }
                                )
                                Divider()
                            }
                        }
                    }
                }

                let doneTasks = allTasks.filter(\.isDone)
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

                if allTasks.isEmpty {
                    Text("Aucune tâche pour l'instant.")
                        .foregroundStyle(.tertiary)
                        .padding(.top, 20)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func toggleDone(_ task: PraxisTask) {
        task.isDone.toggle()
        task.completedAt = task.isDone ? Date() : nil
        task.updatedAt = Date()
        taskStore.save()
    }
}
