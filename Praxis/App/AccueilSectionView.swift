import SwiftUI
import SwiftData

/// "Accueil" — new dashboard, first thing Pierre sees, answering "où j'en étais, qu'est-ce
/// qui presse" per the design handoff. Everything here is derived from existing @Query
/// data (no new SwiftData model). Course cells navigate to the task list filtered on that
/// course; the Q&A-per-course entry point they also carried is gone with the local model.
struct AccueilSectionView: View {
    @EnvironmentObject private var taskStore: TaskStoreCoordinator
    @EnvironmentObject private var localLLM: LocalLLMCoordinator
    @EnvironmentObject private var focusTimer: FocusTimerCoordinator

    /// Tapping a "Presse" card sends Pierre to the Tâches section (per his explicit ask)
    /// — a direct binding to `ContentView`'s sidebar selection rather than any indirect
    /// navigation mechanism.
    @Binding var selectedSection: AppSection?
    /// Set alongside `selectedSection` when navigating to Tâches, so the list arrives
    /// already filtered on the course Pierre tapped (owned by `ContentView`).
    @Binding var taskCourseFilter: String?

    @Query(filter: #Predicate<PraxisTask> { !$0.isDone && !$0.isRejected }, sort: \PraxisTask.dueDate)
    private var openTasks: [PraxisTask]

    @State private var isTriagePresented = false
    @State private var editingTask: PraxisTask?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bon retour.")
                        .font(.title2)
                        .bold()
                    Text(contextSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !pressingTasks.isEmpty {
                    pressingSection
                }

                if needsReviewCount > 0 {
                    triageRow
                }

                coursesSection
            }
            .padding(28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheet(isPresented: $isTriagePresented) {
            TaskTriageView()
                .environmentObject(taskStore)
                .environmentObject(localLLM)
                .environmentObject(focusTimer)
        }
        .sheet(item: $editingTask) { task in
            TaskFormSheet(existingTask: task, availableCourses: CourseDirectoryScanner.scan())
                .environmentObject(taskStore)
                .environmentObject(localLLM)
                .environmentObject(focusTimer)
        }
    }

    private var pressingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Presse").font(.caption).foregroundStyle(.secondary)
            ForEach(pressingTasks) { task in
                Button {
                    // Sends Pierre to Tâches per his explicit ask, while also opening the
                    // task directly rather than leaving him to find it in the full list.
                    // Clears any course filter left over from a previous course-card tap,
                    // otherwise this task could land behind a filter that hides it.
                    taskCourseFilter = nil
                    selectedSection = .tasks
                    editingTask = task
                } label: {
                    HStack {
                        Text(task.title).font(.callout)
                        Spacer()
                        if let due = task.effectiveDueDate {
                            Text(TaskScheduling.countdownLabel(for: due))
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(.red)
                        }
                    }
                    .padding(10)
                    .background(Color.red.opacity(0.08))
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Color.red).frame(width: 3)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var triageRow: some View {
        Button {
            isTriagePresented = true
        } label: {
            HStack {
                Text("\(needsReviewCount) tâche\(needsReviewCount > 1 ? "s" : "") à trier")
                    .font(.callout)
                Spacer()
                Text("Trier →")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.praxisAccent)
            }
            .padding(10)
            .background(Color.gray.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    private var coursesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Par cours").font(.caption).foregroundStyle(.secondary)
            if courseSummaries.isEmpty {
                Text("Aucune tâche liée à un cours pour l'instant.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(courseSummaries) { course in
                        // Navigates to the task list filtered on this course. The per-course
                        // Q&A button that used to sit here is gone with the local model
                        // (see LocalLLMCoordinator.isAvailable).
                        HStack(spacing: 6) {
                            Button {
                                taskCourseFilter = course.vaultPath
                                selectedSection = .tasks
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(course.displayName)
                                        .font(.callout)
                                        .lineLimit(1)
                                    Text("\(course.openCount) tâche\(course.openCount > 1 ? "s" : "") ouverte\(course.openCount > 1 ? "s" : "")")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Voir les tâches de ce cours")

                        }
                        .padding(10)
                        .background(Color.gray.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                }
            }
        }
    }

    /// What actually presses, regardless of what kind of work it is.
    ///
    /// This used to filter on `$0.type == .rendu`, which was not a product decision but a
    /// consequence of the old model: a rendu was the only type that could carry a date, so
    /// it was the only one that could be ranked. A DS next week never reached this panel.
    /// Now it reads the effective date, so a milestone inside a dossier surfaces here too.
    private var pressingTasks: [PraxisTask] {
        let cutoff = Calendar.current.date(byAdding: .day, value: 5, to: Date()) ?? Date()
        return Array(
            openTasks
                .filter { ($0.effectiveDueDate ?? .distantFuture) <= cutoff }
                .sorted { ($0.effectiveDueDate ?? .distantFuture) < ($1.effectiveDueDate ?? .distantFuture) }
                .prefix(3)
        )
    }

    private var needsReviewCount: Int {
        openTasks.filter(\.needsReview).count
    }

    private var contextSubtitle: String {
        "\(openTasks.count) tâche\(openTasks.count > 1 ? "s" : "") ouverte\(openTasks.count > 1 ? "s" : "")"
    }

    private var courseSummaries: [CourseSummary] {
        var counts: [String: (displayName: String, count: Int)] = [:]
        for task in openTasks {
            guard let course = task.course else { continue }
            counts[course.id, default: (course.displayName, 0)].count += 1
        }
        return counts
            .map { CourseSummary(vaultPath: $0.key, displayName: $0.value.displayName, openCount: $0.value.count) }
            .sorted { $0.displayName < $1.displayName }
    }

}

private struct CourseSummary: Identifiable {
    let vaultPath: String
    let displayName: String
    let openCount: Int
    var id: String { vaultPath }
}

