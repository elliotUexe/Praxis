import Foundation
import SwiftData
import AppKit

@MainActor
final class TaskStoreCoordinator: ObservableObject {
    let modelContainer: ModelContainer
    var modelContext: ModelContext { modelContainer.mainContext }

    @Published var lastError: String?
    @Published private(set) var lastImportScanAt: Date?

    private var foregroundObserver: NSObjectProtocol?

    init() {
        let schema = Schema([Course.self, PraxisTask.self, RevisionBlock.self, TaskComment.self])
        // Stored outside the vault, deliberately: this is Praxis's authoritative SwiftData
        // store (SQLite + WAL). Living inside the vault risks obsidian-livesync touching
        // the WAL file mid-write. The vault only ever receives explicit, on-demand exports
        // (Phase 4) or reads from the schedule cache — never this store directly.
        let storeDirectory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Praxis", isDirectory: true)
        try? FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)

        let config = ModelConfiguration(
            schema: schema,
            url: storeDirectory.appendingPathComponent("PraxisTasks.store")
        )

        do {
            modelContainer = try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Impossible d'initialiser le stockage des tâches Praxis : \(error)")
        }

        scanPendingImports()
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scanPendingImports() }
        }
    }

    deinit {
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
    }

    /// Phase 6: picks up JSON batches dropped by an external Claude Code skill into
    /// `90_Meta/staging/pending-imports/`. Called at launch, on foreground, and available
    /// for a manual "Vérifier les imports" button — never on a live-typing timer, this is
    /// cheap but not free (a directory scan + JSON decode per file).
    func scanPendingImports() {
        PendingImportScanner.scan(taskStore: self)
        lastImportScanAt = Date()
    }

    /// Finds the `Course` row for a vault-relative path, creating it if absent. The single
    /// identity key shared by manual creation, calendar-resolved recording destinations, and
    /// future import mechanisms — never an invented slug — so they always converge on the
    /// same row for the same real folder.
    func findOrCreateCourse(vaultPath: String) -> Course {
        let descriptor = FetchDescriptor<Course>(predicate: #Predicate { $0.id == vaultPath })
        if let existing = try? modelContext.fetch(descriptor).first {
            return existing
        }
        let components = vaultPath.split(separator: "/")
        let year = components.count > 1 ? String(components[1]) : ""
        let pole = components.count > 2 ? String(components[2]) : ""
        let displayName = VaultPaths.courseDisplayName(fromVaultPath: vaultPath)
        let course = Course(id: vaultPath, displayName: displayName, pole: pole, year: year)
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
