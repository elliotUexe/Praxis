import SwiftUI
import AppKit

/// Repairs every course whose folder Praxis can no longer find, in one place.
///
/// Three ways out, because there are three real situations. The folder moved inside the
/// vault and Praxis can find its marker again — that one resolves itself. It moved
/// somewhere Praxis cannot see, and has to be pointed at. Or it was deleted outright, in
/// which case neither of the first two will ever succeed and the banner would stay up
/// forever: detaching keeps the tasks and drops the folder link.
///
/// Nothing here deletes a task, and nothing creates a second course row for a folder that
/// already has one — which is exactly what used to happen quietly.
struct UnresolvedCoursesView: View {
    @EnvironmentObject private var taskStore: TaskStoreCoordinator
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Matières introuvables").font(.title3)
            Text("Le dossier de ces matières a été déplacé ou supprimé. Leurs tâches sont intactes.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(taskStore.unresolvedCourses, id: \.id) { course in
                        row(for: course)
                        Divider()
                    }
                }
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button(taskStore.unresolvedCourses.isEmpty ? "Terminé" : "Plus tard") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480, height: 380)
    }

    private func row(for course: Course) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(course.displayName).font(.callout)
            Text(course.resolvedRelativePath)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
            Text("\(course.tasks.count) tâche\(course.tasks.count > 1 ? "s" : "")")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button("Rechercher") { research(course) }
                    .controlSize(.small)
                Button("Indiquer le dossier…") { relocate(course) }
                    .controlSize(.small)
                Spacer()
                Button("Détacher", role: .destructive) { taskStore.detachCourse(course) }
                    .controlSize(.small)
                    .help("Garde les tâches et oublie le dossier. À utiliser si le dossier a été supprimé.")
            }
        }
    }

    /// Sweeps the vault for the course's marker. Silent when it works, which is the common
    /// case for a folder dragged elsewhere inside the vault.
    private func research(_ course: Course) {
        guard let stableID = course.stableID else {
            taskStore.lastError = "Cette matière n'a pas d'identifiant à rechercher : indiquez son dossier."
            return
        }
        if CourseMigration.relocate(course, stableID: stableID, root: VaultSettings.root) {
            taskStore.save()
            taskStore.migrateCourses()
        } else {
            taskStore.lastError = "Dossier introuvable, ou plusieurs dossiers portent le même identifiant."
        }
    }

    private func relocate(_ course: Course) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choisir"
        panel.message = "Où se trouve « \(course.displayName) » ?"
        panel.directoryURL = VaultSettings.root
        guard panel.runModal() == .OK, let url = panel.url else { return }
        taskStore.relocateCourse(course, to: url)
    }
}
