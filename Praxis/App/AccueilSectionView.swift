import SwiftUI
import SwiftData

/// "Accueil" — new dashboard, first thing Pierre sees, answering "où j'en étais, qu'est-ce
/// qui presse" per the design handoff. Everything here is derived from existing @Query
/// data (no new SwiftData model). The Q&A-per-course entry point (Chantier C) lives here,
/// on each course cell, rather than as its own sidebar section — the course is already
/// known from the tapped cell, so no cascade course picker is needed.
struct AccueilSectionView: View {
    @EnvironmentObject private var taskStore: TaskStoreCoordinator
    @EnvironmentObject private var localLLM: LocalLLMCoordinator
    @EnvironmentObject private var focusTimer: FocusTimerCoordinator

    /// Tapping a "Presse" card sends Pierre to the Tâches section (per his explicit ask)
    /// — a direct binding to `ContentView`'s sidebar selection rather than any indirect
    /// navigation mechanism.
    @Binding var selectedSection: AppSection?

    @Query(filter: #Predicate<PraxisTask> { !$0.isDone && !$0.isRejected }, sort: \PraxisTask.dueDate)
    private var openTasks: [PraxisTask]

    @State private var isTriagePresented = false
    @State private var courseForQuestion: CourseSummary?
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
        .sheet(item: $courseForQuestion) { course in
            CourseQuestionView(courseVaultPath: course.vaultPath, displayName: course.displayName)
                .environmentObject(localLLM)
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
                    selectedSection = .tasks
                    editingTask = task
                } label: {
                    HStack {
                        Text(task.title).font(.callout)
                        Spacer()
                        if let due = task.dueDate {
                            Text(dueLabel(due))
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
                        Button {
                            courseForQuestion = course
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
                            .padding(10)
                            .background(Color.gray.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                        }
                        .buttonStyle(.plain)
                        .help("Poser une question sur ce cours")
                    }
                }
            }
        }
    }

    private var pressingTasks: [PraxisTask] {
        let cutoff = Calendar.current.date(byAdding: .day, value: 5, to: Date()) ?? Date()
        return Array(openTasks.filter { $0.type == .rendu && ($0.dueDate ?? .distantFuture) <= cutoff }.prefix(3))
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

    private func dueLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: Date()),
            to: calendar.startOfDay(for: date)
        ).day ?? 0
        if days < 0 { return "En retard" }
        if days == 0 { return "Aujourd'hui" }
        return "J-\(days)"
    }
}

private struct CourseSummary: Identifiable {
    let vaultPath: String
    let displayName: String
    let openCount: Int
    var id: String { vaultPath }
}

/// Chantier C: Q&A against a course's saved files, no live recording required. The course
/// is already known (the dashboard cell that was tapped), so this skips rebuilding the
/// Année→Pôle→Cours cascade selector — just a question field and a Markdown answer.
private struct CourseQuestionView: View {
    @EnvironmentObject private var localLLM: LocalLLMCoordinator
    @Environment(\.dismiss) private var dismiss
    let courseVaultPath: String
    let displayName: String

    @State private var question = ""
    @State private var answer = ""
    @State private var isAsking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Question — \(displayName)").font(.title3)
                Spacer()
                Button("Fermer") { dismiss() }
            }

            HStack {
                TextField("Poser une question sur ce cours…", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(ask)
                Button(isAsking ? "…" : "Envoyer") { ask() }
                    .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || isAsking || localLLM.isUserDisabled)
            }

            if localLLM.isUserDisabled {
                Text("IA locale désactivée (dans Réglages).")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            ScrollView {
                Text(answer.isEmpty ? "La réponse apparaîtra ici." : answer)
                    .font(.callout)
                    .foregroundStyle(answer.isEmpty ? .tertiary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(Color.gray.opacity(0.05))
            .cornerRadius(8)
            .frame(minHeight: 200)
        }
        .padding()
        .frame(width: 460, height: 380)
    }

    private func ask() {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            isAsking = true
            defer { isAsking = false }
            answer = await localLLM.askCourseQuestion(courseVaultPath: courseVaultPath, question: trimmed)
                ?? "Erreur lors de la génération de la réponse."
        }
    }
}
