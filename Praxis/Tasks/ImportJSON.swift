import Foundation

/// Phase 6: generic ingestion schema — deliberately source-agnostic (`sourceType` covers
/// "transcript" today, "mail"/"whatsapp" later with zero Swift changes needed) and supports
/// both creating new tasks and commenting/updating an existing one, per the "centraliser à
/// un seul endroit" requirement: an external source that recognizes an existing task should
/// never just spawn a duplicate.
struct PendingImportBatch: Decodable {
    let schemaVersion: Int
    let sourceType: String   // "transcript" | "mail" | "whatsapp"
    let courseVaultPath: String?
    let creations: [PendingTaskCreation]
    let updates: [PendingTaskUpdate]
}

struct PendingTaskCreation: Decodable {
    let type: TaskType
    let title: String
    let detail: String?
    let sourceTranscriptPath: String?
    let dueDate: String?
    let estimatedDurationMinutes: Int?
    let blockedReason: String?
    let waitingOn: String?
    let horizonDate: String?

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    func apply(to task: PraxisTask) {
        if let dueDate, let date = Self.dateFormatter.date(from: dueDate) {
            task.dueDate = date
        }
        task.estimatedDurationMinutes = estimatedDurationMinutes
        task.blockedReason = blockedReason
        task.waitingOn = waitingOn
        if let horizonDate, let date = Self.dateFormatter.date(from: horizonDate) {
            task.horizonDate = date
        }
    }
}

/// Targets an existing task by `matchTaskId` (preferred — the skill should resolve this
/// itself, e.g. from the most recent Phase 4 export) or, failing that, `matchTitleHint` as
/// a best-effort fallback the scanner fuzzy-matches against. If neither resolves to a real
/// task, the update is skipped — it is never silently applied to a guessed task.
struct PendingTaskUpdate: Decodable {
    let matchTaskId: String?
    let matchTitleHint: String?
    let comment: String
    let fieldChanges: PendingFieldChanges?
}

struct PendingFieldChanges: Decodable {
    let title: String?
    let dueDate: String?
    let estimatedDurationMinutes: Int?
    let blockedReason: String?
    let waitingOn: String?
    let horizonDate: String?

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Only overwrites fields explicitly present in the JSON — a field left out of
    /// `fieldChanges` keeps its current value, it is never reset to nil by omission.
    func apply(to task: PraxisTask) {
        if let title { task.title = title }
        if let dueDate { task.dueDate = Self.dateFormatter.date(from: dueDate) }
        if let estimatedDurationMinutes { task.estimatedDurationMinutes = estimatedDurationMinutes }
        if let blockedReason { task.blockedReason = blockedReason }
        if let waitingOn { task.waitingOn = waitingOn }
        if let horizonDate { task.horizonDate = Self.dateFormatter.date(from: horizonDate) }
    }
}
