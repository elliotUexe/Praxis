import Foundation
import SwiftData

/// Phase 6: the hand-off mechanism between an external Claude Code skill (free — no
/// metered API call) and Praxis's SwiftData store. Only Praxis's own process ever opens a
/// `ModelContext` — a skill writing straight into the SQLite/WAL file could corrupt it
/// against a live app, so the skill instead drops a JSON file here and only this scanner
/// touches SwiftData with it.
///
/// `@MainActor`: always invoked from `TaskStoreCoordinator` (itself main-actor-isolated,
/// same as SwiftData's `ModelContext` requires) — never called from a background context.
@MainActor
enum PendingImportScanner {
    /// Imports one batch, chosen by hand.
    ///
    /// This used to watch `90_Meta/staging/pending-imports` inside one specific vault,
    /// scanned at launch and on every foreground. That path stopped existing the moment the
    /// root became a setting — and it never existed at all for anyone but its author.
    static func importFile(at file: URL, taskStore: TaskStoreCoordinator) {
        pendingFailure = nil
        process(file: file, taskStore: taskStore, fm: FileManager.default)
        if let pendingFailure {
            taskStore.lastError = "Import impossible : \(pendingFailure)"
        }
    }

    private static func process(file: URL, taskStore: TaskStoreCoordinator, fm: FileManager) {
        guard let data = try? Data(contentsOf: file) else { return }
        guard let batch = try? JSONDecoder().decode(PendingImportBatch.self, from: data), batch.schemaVersion == 1 else {
            report(failure: "JSON invalide, ou schemaVersion non supportée par cette version de Praxis.")
            return
        }

        let course = batch.courseVaultPath.map { taskStore.findOrCreateCourse(vaultPath: $0) }
        let existing = allTasks(taskStore: taskStore)

        for creation in batch.creations {
            insertIfNotDuplicate(creation, course: course, sourceType: batch.sourceType, existing: existing, taskStore: taskStore)
        }
        for update in batch.updates {
            applyUpdate(update, sourceType: batch.sourceType, existing: existing, taskStore: taskStore)
        }

        taskStore.save()
        taskStore.lastError = nil
    }

    // MARK: - Creations (with dedup)

    private static func insertIfNotDuplicate(
        _ creation: PendingTaskCreation,
        course: Course?,
        sourceType: String,
        existing: [PraxisTask],
        taskStore: TaskStoreCoordinator
    ) {
        if let sourcePath = creation.sourceTranscriptPath {
            let isDuplicate = existing.contains {
                $0.sourceTranscriptPath == sourcePath && similar($0.title, creation.title)
            }
            guard !isDuplicate else { return }
        }

        let task = PraxisTask(
            title: creation.title,
            type: creation.type,
            course: course,
            detail: creation.detail,
            origin: "skill_externe:\(sourceType)"
        )
        task.sourceTranscriptPath = creation.sourceTranscriptPath
        task.needsReview = true
        creation.apply(to: task)
        taskStore.modelContext.insert(task)
    }

    // MARK: - Updates (comment + optional field changes on an existing task)

    private static func applyUpdate(
        _ update: PendingTaskUpdate,
        sourceType: String,
        existing: [PraxisTask],
        taskStore: TaskStoreCoordinator
    ) {
        var target: PraxisTask?
        if let idString = update.matchTaskId, let uuid = UUID(uuidString: idString) {
            target = existing.first { $0.id == uuid }
        }
        if target == nil, let hint = update.matchTitleHint {
            target = existing.first { similar($0.title, hint) }
        }
        // No confident match — skip rather than guess-write onto the wrong task.
        guard let target else { return }

        let comment = TaskComment(text: update.comment, source: "skill_externe:\(sourceType)", task: target)
        taskStore.modelContext.insert(comment)
        target.comments.append(comment)

        if let changes = update.fieldChanges {
            changes.apply(to: target)
        }
        target.updatedAt = Date()
    }

    // MARK: - Helpers

    private static func allTasks(taskStore: TaskStoreCoordinator) -> [PraxisTask] {
        (try? taskStore.modelContext.fetch(FetchDescriptor<PraxisTask>())) ?? []
    }

    private static func similar(_ a: String, _ b: String) -> Bool {
        let na = a.lowercased().trimmingCharacters(in: .whitespaces)
        let nb = b.lowercased().trimmingCharacters(in: .whitespaces)
        return na == nb || na.hasPrefix(nb) || nb.hasPrefix(na)
    }

    /// The file is never moved or deleted now that it is chosen rather than watched: it
    /// belongs to whoever picked it, and the failure is worth showing on screen instead of
    /// being filed into a `failed/` folder nobody opens.
    private static func report(failure reason: String) {
        pendingFailure = reason
    }

    /// Set by `report(failure:)` during a `process` call and read straight after by
    /// `importFile(at:taskStore:)`, which is the only caller.
    private static var pendingFailure: String?
}
