import Foundation
import SwiftData
import AppKit

@MainActor
final class TaskStoreCoordinator: ObservableObject {
    let modelContainer: ModelContainer
    let storeURL: URL
    var modelContext: ModelContext { modelContainer.mainContext }

    @Published var lastError: String?
    @Published private(set) var lastImportScanAt: Date?
    /// Courses whose folder could not be found. Surfaced as a banner rather than a blocking
    /// dialog: a folder that moved is no reason to stop someone reading their task list.
    @Published private(set) var unresolvedCourses: [Course] = []

    init() {
        let schema = Schema([Course.self, PraxisTask.self, RevisionBlock.self, TaskComment.self, Subtask.self, FocusSession.self, TaskAttachment.self])
        // Stored outside the vault, deliberately: this is Praxis's authoritative SwiftData
        // store (SQLite + WAL). Living inside the vault risks obsidian-livesync touching
        // the WAL file mid-write. The vault only ever receives explicit, on-demand exports
        // (Phase 4) or reads from the schedule cache — never this store directly.
        let storeDirectory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Praxis", isDirectory: true)
        try? FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)

        let storeURL = storeDirectory.appendingPathComponent("PraxisTasks.store")
        let config = ModelConfiguration(schema: schema, url: storeURL)
        self.storeURL = storeURL

        do {
            modelContainer = try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Impossible d'initialiser le stockage des tâches Praxis : \(error)")
        }

        migrateHorizonDates()
        migrateCourses()
    }

    /// Moves `horizonDate` into `dueDate`, once, at launch. Until 0.4 an "Anticipation"
    /// kept its date in a second field that nothing else read, so those tasks were invisible
    /// to every date-based view. Runs on every launch but does nothing after the first: it
    /// only touches rows that still have a `horizonDate` set, and clears it as it goes.
    private func migrateHorizonDates() {
        let descriptor = FetchDescriptor<PraxisTask>(
            predicate: #Predicate { $0.horizonDate != nil }
        )
        guard let stragglers = try? modelContext.fetch(descriptor), !stragglers.isEmpty else { return }
        for task in stragglers {
            // An explicit `dueDate` wins: it was always the field the app actually read.
            if task.dueDate == nil {
                task.dueDate = task.horizonDate
            }
            task.horizonDate = nil
        }
        save()
    }

    /// Imports one JSON batch produced by an external skill.
    ///
    /// Replaces a folder watched at launch and on every foreground, which pointed at
    /// `90_Meta/staging/pending-imports` inside one particular vault — a path that stops
    /// existing the moment the root becomes a setting, and that never meant anything to
    /// anyone else. Choosing the file is one gesture more and no guesswork.
    func importTasks(from url: URL) {
        PendingImportScanner.importFile(at: url, taskStore: self)
        lastImportScanAt = Date()
    }

    /// Re-anchors courses onto stable identities, and follows folders that moved. Runs at
    /// every launch: it is idempotent, and it is also what recovers from a root change.
    func migrateCourses() {
        let hasUnmigrated = (try? modelContext.fetch(
            FetchDescriptor<Course>(predicate: #Predicate { $0.stableID == nil })
        ))?.isEmpty == false
        if hasUnmigrated {
            CourseMigration.backupStore(at: storeURL)
        }

        let outcome = CourseMigration.run(context: modelContext, root: VaultSettings.root)
        unresolvedCourses = outcome.unresolved
        save()
    }

    /// Attaches a file to a task, copying it into the course's `03 - TD-TP` folder first if
    /// it lives outside the vault. Returns nil, with `lastError` set, when there is nowhere
    /// to copy to: a file from Downloads dropped on a task with no course has no home.
    @discardableResult
    func attach(fileURL: URL, to task: PraxisTask) -> TaskAttachment? {
        let source = fileURL.standardizedFileURL
        let relative: String

        if let inVault = VaultSettings.relativePath(for: source), !inVault.isEmpty {
            relative = inVault
        } else {
            guard let coursePath = task.course?.resolvedRelativePath else {
                lastError = "Ce fichier n'est pas dans le vault et la tâche n'a pas de matière où le ranger."
                return nil
            }
            let folder = VaultSettings.url(forRelativePath: coursePath).appendingPathComponent("03 - TD-TP")
            let destination = Self.uniqueDestination(for: source.lastPathComponent, in: folder)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: source, to: destination)
            } catch {
                lastError = "Copie impossible dans le dossier de la matière : \(error.localizedDescription)"
                return nil
            }
            guard let copied = VaultSettings.relativePath(for: destination) else { return nil }
            relative = copied
        }

        if let existing = task.attachments.first(where: { $0.relativePath == relative }) {
            return existing
        }
        let attachment = TaskAttachment(relativePath: relative, displayName: (relative as NSString).lastPathComponent, task: task)
        modelContext.insert(attachment)
        task.updatedAt = Date()
        save()
        return attachment
    }

    /// `sujet.pdf`, then `sujet 2.pdf`, `sujet 3.pdf`: a second drop of a same-named file
    /// must never overwrite the first, which may be a different document entirely.
    private static func uniqueDestination(for name: String, in folder: URL) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let numbered = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            candidate = folder.appendingPathComponent(numbered)
            counter += 1
        }
        return candidate
    }

    func detach(_ attachment: TaskAttachment) {
        attachment.task?.updatedAt = Date()
        modelContext.delete(attachment)
        save()
    }

    /// Drops a course's folder link, keeping its tasks. The only way out when a folder was
    /// deleted rather than moved: without it the banner would never clear.
    func detachCourse(_ course: Course) {
        course.stableID = nil
        course.relativePath = nil
        unresolvedCourses.removeAll { $0.id == course.id }
        save()
    }

    /// Points a course at a folder chosen by hand, and marks it.
    func relocateCourse(_ course: Course, to folder: URL) {
        guard let id = CourseMarker.ensure(in: folder) else {
            lastError = "Impossible d'écrire dans ce dossier."
            return
        }
        course.stableID = id
        course.relativePath = VaultSettings.relativePath(for: folder)
        course.displayName = folder.lastPathComponent
        unresolvedCourses.removeAll { $0.id == course.id }
        save()
    }

    /// Finds the `Course` row for a vault-relative path, creating it if absent. The single
    /// identity key shared by manual creation, calendar-resolved recording destinations, and
    /// future import mechanisms — never an invented slug — so they always converge on the
    /// same row for the same real folder.
    /// Resolves the `Course` row for a folder, creating it if needed.
    ///
    /// Identity comes from the folder's marker, not from its path, so a course found again
    /// after being moved or renamed is the same course. Choosing a folder is what marks it:
    /// there is no separate "declare this a subject" step, and no fifty hidden files written
    /// into a vault on first launch for folders that may never be used.
    func findOrCreateCourse(vaultPath: String) -> Course {
        let folder = VaultSettings.url(forRelativePath: vaultPath)
        let markerID = CourseMarker.ensure(in: folder)

        if let markerID,
           let existing = try? modelContext.fetch(
               FetchDescriptor<Course>(predicate: #Predicate { $0.stableID == markerID })
           ).first {
            existing.relativePath = vaultPath
            existing.displayName = VaultSettings.displayName(forRelativePath: vaultPath)
            return existing
        }
        // A row from before markers existed, still keyed by its old path.
        if let legacy = try? modelContext.fetch(
            FetchDescriptor<Course>(predicate: #Predicate { $0.relativePath == vaultPath })
        ).first {
            legacy.stableID = markerID
            return legacy
        }

        let course = Course(
            id: vaultPath,
            displayName: VaultSettings.displayName(forRelativePath: vaultPath),
            stableID: markerID,
            relativePath: vaultPath
        )
        modelContext.insert(course)
        return course
    }

    func save() {
        guard modelContext.hasChanges else { return }
        do {
            try modelContext.save()
        } catch {
            lastError = "Erreur de sauvegarde des tâches : \(error.localizedDescription)"
        }
    }
}
