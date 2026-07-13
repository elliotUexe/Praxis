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
    private static var pendingDir: URL {
        VaultPaths.root.appendingPathComponent("90_Meta/staging/pending-imports")
    }
    private static var processedDir: URL { pendingDir.appendingPathComponent("processed") }
    private static var failedDir: URL { pendingDir.appendingPathComponent("failed") }

    static func scan(taskStore: TaskStoreCoordinator) {
        let fm = FileManager.default
        try? fm.createDirectory(at: pendingDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: processedDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: failedDir, withIntermediateDirectories: true)

        guard let files = try? fm.contentsOfDirectory(at: pendingDir, includingPropertiesForKeys: nil) else { return }
        let jsonFiles = files
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        for file in jsonFiles {
            process(file: file, taskStore: taskStore, fm: fm)
        }
    }

    private static func process(file: URL, taskStore: TaskStoreCoordinator, fm: FileManager) {
        guard let data = try? Data(contentsOf: file) else { return }
        guard let batch = try? JSONDecoder().decode(PendingImportBatch.self, from: data), batch.schemaVersion == 1 else {
            moveToFailed(file: file, fm: fm, reason: "JSON invalide, ou schemaVersion non supportée par cette version de Praxis.")
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
        moveToProcessed(file: file, fm: fm)
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

    /// Never deleted — moved to `processed/` for an audit trail, matching the vault's own
    /// "never delete without confirmation" spirit even though these aren't governed notes.
    private static func moveToProcessed(file: URL, fm: FileManager) {
        let dest = processedDir.appendingPathComponent(file.lastPathComponent)
        try? fm.removeItem(at: dest)
        try? fm.moveItem(at: file, to: dest)
    }

    private static func moveToFailed(file: URL, fm: FileManager, reason: String) {
        let dest = failedDir.appendingPathComponent(file.lastPathComponent)
        try? fm.removeItem(at: dest)
        try? fm.moveItem(at: file, to: dest)
        let sidecar = failedDir.appendingPathComponent(file.deletingPathExtension().lastPathComponent + ".error.txt")
        try? reason.write(to: sidecar, atomically: true, encoding: .utf8)
    }
}
