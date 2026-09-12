import Foundation
import SwiftData

/// Named `PraxisTask`, not `Task` — `Task` would shadow `_Concurrency.Task` across the
/// whole module (every `Task { ... }` async call site in Praxis), causing ambiguity errors
/// far from this file.
enum TaskType: String, Codable, CaseIterable {
    case rendu, revisionFond, revisionDS, blocage, anticipation

    /// Guesses a type from free text. A keyword heuristic, not a model call: quick capture
    /// has to be instant, and it only has to beat "everything defaults to Anticipation".
    /// Shared by the clipboard action in the task list and by the capture field in the
    /// recording view, which used to be one private copy each away from drifting apart.
    init(detectedFrom text: String) {
        let normalized = text.lowercased().folding(options: .diacriticInsensitive, locale: .current)
        if ["ds ", " ds", "examen", "controle", "partiel"].contains(where: normalized.contains) {
            self = .revisionDS
        } else if ["rendre", "rendu", "deadline", "a rendre", "date limite", "avant le"].contains(where: normalized.contains) {
            self = .rendu
        } else {
            self = .anticipation
        }
    }

    var displayName: String {
        switch self {
        case .rendu: return "Rendu"
        case .revisionFond: return "Révision de fond"
        case .revisionDS: return "Révision pour DS"
        case .blocage: return "Point de blocage"
        case .anticipation: return "Anticipation"
        }
    }
}

@Model
final class Course {
    /// Frozen at whatever it was when the row was created — a path relative to the vault
    /// root of the day. Deliberately never rewritten: it is the unique key, and an older
    /// build of Praxis reads it as its course path. Rewriting it would leave a rolled-back
    /// version pointing at folders it cannot find.
    @Attribute(.unique) var id: String
    var displayName: String
    /// Kept for the same reason as `id`, and no longer authoritative: with the tree shape
    /// configurable, the levels above a course are read from its path rather than stored.
    var pole: String
    var year: String

    /// The identity that survives the folder being moved or renamed, matching the id in the
    /// folder's own `CourseMarker`. Nil on rows created before 0.4.2, until the migration
    /// resolves them.
    var stableID: String?
    /// Current location, relative to the configured root. Mutable: this is what a relocation
    /// updates, leaving `stableID` untouched.
    var relativePath: String?

    @Relationship(deleteRule: .cascade, inverse: \PraxisTask.course)
    var tasks: [PraxisTask] = []

    init(
        id: String,
        displayName: String,
        pole: String = "",
        year: String = "",
        stableID: String? = nil,
        relativePath: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.pole = pole
        self.year = year
        self.stableID = stableID
        self.relativePath = relativePath
    }

    /// Where this course lives now, falling back to the legacy path for a row the migration
    /// has not reached.
    var resolvedRelativePath: String { relativePath ?? id }
}

@Model
final class PraxisTask {
    @Attribute(.unique) var id: UUID
    var title: String
    var detail: String?
    var typeRaw: String
    var course: Course?
    var sourceTranscriptPath: String?
    var origin: String                   // "manuel" | "llm_local" | "skill_externe"
    var isDone: Bool
    var needsReview: Bool                // auto-extracted, not yet reviewed — a visual filter, never an edit lock
    /// Set by "Rejeter" in the triage queue (`TaskTriageView`) — archives the task out of
    /// every default list/query without deleting it. Only surfaced again via the
    /// "Tâches rejetées" modal, which can restore it (clears this flag) or delete it for
    /// good. Declared with an inline default so SwiftData lightweight-migrates existing
    /// rows to `false` automatically.
    var isRejected: Bool = false
    var createdAt: Date
    var updatedAt: Date
    var completedAt: Date?

    /// The date of the task, whatever its type. It used to belong to `.rendu` alone, with
    /// `.anticipation` carrying a second `horizonDate` and the three other types carrying
    /// none at all — which is why a DS could not be dated, and why changing a task's type
    /// silently erased its date. One field, for every type; the type now only decides how
    /// the date is *rendered*, not whether it may exist.
    var dueDate: Date?

    // Révision (fond ou DS)
    var estimatedDurationMinutes: Int?
    @Relationship(deleteRule: .cascade, inverse: \RevisionBlock.task)
    var scheduledBlocks: [RevisionBlock] = []

    // Blocage
    var blockedReason: String?
    var waitingOn: String?

    /// Superseded by `dueDate`. Kept declared so the stored column survives long enough for
    /// `TaskStoreCoordinator.migrateHorizonDates()` to move its values across; nothing
    /// writes it any more. Removable once every store has been through a 0.4 launch.
    var horizonDate: Date?

    @Relationship(deleteRule: .cascade, inverse: \TaskComment.task)
    var comments: [TaskComment] = []

    @Relationship(deleteRule: .cascade, inverse: \Subtask.parentTask)
    var subtasks: [Subtask] = []

    @Relationship(deleteRule: .cascade, inverse: \TaskAttachment.task)
    var attachments: [TaskAttachment] = []

    var type: TaskType {
        get { TaskType(rawValue: typeRaw) ?? .anticipation }
        set { typeRaw = newValue.rawValue }
    }

    /// Dates of the milestones still to be done. A finished subtask stops steering the
    /// task, which is what lets a dossier fall back to its final deadline once the draft
    /// has been sent.
    var openSubtaskDates: [Date] {
        subtasks.filter { !$0.isDone }.compactMap(\.dueDate)
    }

    /// What the task is ranked and filed by. See `TaskScheduling.effectiveDate`.
    var effectiveDueDate: Date? {
        TaskScheduling.effectiveDate(taskDate: dueDate, openSubtaskDates: openSubtaskDates)
    }

    var horizon: TaskHorizon {
        TaskScheduling.horizon(for: effectiveDueDate)
    }

    /// True when the effective date comes from a subtask rather than from the task itself,
    /// so a row can name the milestone that is actually pulling it forward.
    var isDrivenBySubtask: Bool {
        guard let effective = effectiveDueDate else { return false }
        return dueDate.map { effective < $0 } ?? true
    }

    var nextMilestone: Subtask? {
        subtasks
            .filter { !$0.isDone && $0.dueDate != nil }
            .min { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
    }

    var hasSubtaskPastDeadline: Bool {
        TaskScheduling.hasSubtaskPastDeadline(taskDate: dueDate, openSubtaskDates: openSubtaskDates)
    }

    init(
        title: String,
        type: TaskType,
        course: Course? = nil,
        detail: String? = nil,
        origin: String = "manuel"
    ) {
        self.id = UUID()
        self.title = title
        self.detail = detail
        self.typeRaw = type.rawValue
        self.course = course
        self.origin = origin
        self.isDone = false
        self.needsReview = origin != "manuel"
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

/// Empty for now — Phase 7 (post-MVP) fills these in via a revision-block proposal system.
@Model
final class RevisionBlock {
    @Attribute(.unique) var id: UUID
    var start: Date
    var end: Date
    var googleCalendarEventId: String?
    var task: PraxisTask?

    init(start: Date, end: Date, task: PraxisTask? = nil) {
        self.id = UUID()
        self.start = start
        self.end = end
        self.task = task
    }
}

/// Timestamped comment/update thread — the "centraliser à un seul endroit" mechanism from
/// Phase 6: an external source that finds an existing task appends a comment instead of
/// duplicating it or silently overwriting a field.
@Model
final class TaskComment {
    @Attribute(.unique) var id: UUID
    var text: String
    var source: String   // "manuel" | "llm_local" | "skill_externe:mail" | "skill_externe:whatsapp" ...
    var createdAt: Date
    var task: PraxisTask?

    init(text: String, source: String, task: PraxisTask? = nil) {
        self.id = UUID()
        self.text = text
        self.source = source
        self.createdAt = Date()
        self.task = task
    }
}

/// A timed chunk of a macro task — either typed in by hand or accepted from an LLM
/// proposal (`origin`, same "manuel" | "llm_local" vocabulary as `PraxisTask.origin`).
/// A dedicated entity rather than a self-referencing `PraxisTask`: the type-specific fields
/// (`blockedReason`, `waitingOn`, ...) make no sense on a subtask, which needs a title, a
/// time estimate, a done/not-done state — and, since 0.4, an optional milestone date.
@Model
final class Subtask {
    @Attribute(.unique) var id: UUID
    var title: String
    var estimatedMinutes: Int
    /// A milestone date, optional: most subtasks are just steps, some are commitments —
    /// the draft you send halfway through a dossier. When set, it takes over the parent's
    /// place in the list until it is ticked off. Inline default so SwiftData
    /// lightweight-migrates existing rows.
    var dueDate: Date? = nil
    var isDone: Bool
    var order: Int
    var origin: String
    var parentTask: PraxisTask?

    init(
        title: String,
        estimatedMinutes: Int,
        order: Int,
        origin: String = "manuel",
        dueDate: Date? = nil,
        parentTask: PraxisTask? = nil
    ) {
        self.id = UUID()
        self.title = title
        self.estimatedMinutes = estimatedMinutes
        self.dueDate = dueDate
        self.isDone = false
        self.order = order
        self.origin = origin
        self.parentTask = parentTask
    }
}

/// One concentration-timer run (15/25 min, Pomodoro-style), optionally tied to a task or a
/// specific subtask — logged even when abandoned (`wasCompleted = false`) rather than
/// discarded, so the record reflects what actually happened.
@Model
final class FocusSession {
    @Attribute(.unique) var id: UUID
    var startedAt: Date
    var plannedDurationMinutes: Int
    var completedAt: Date?
    var wasCompleted: Bool
    var linkedTask: PraxisTask?
    var linkedSubtask: Subtask?

    init(
        plannedDurationMinutes: Int,
        linkedTask: PraxisTask? = nil,
        linkedSubtask: Subtask? = nil
    ) {
        self.id = UUID()
        self.startedAt = Date()
        self.plannedDurationMinutes = plannedDurationMinutes
        self.wasCompleted = false
        self.linkedTask = linkedTask
        self.linkedSubtask = linkedSubtask
    }
}

/// A shortcut to a file in the vault, attached to a task.
///
/// Only ever a reference, never a copy held by Praxis: the vault is where documents live,
/// and a task pointing at a TD subject or a professor's PDF should open the one file that
/// is already there. A file dropped from outside the vault is copied into the course's
/// `03 - TD-TP` folder first, then referenced like any other — so the invariant holds
/// that every attachment resolves to a vault path.
///
/// Stored relative to the configured root, for the same reason course paths are: moving
/// the vault changes one setting, not every attachment.
@Model
final class TaskAttachment {
    @Attribute(.unique) var id: UUID
    var relativePath: String
    var displayName: String
    var addedAt: Date
    var task: PraxisTask?

    init(relativePath: String, displayName: String, task: PraxisTask? = nil) {
        self.id = UUID()
        self.relativePath = relativePath
        self.displayName = displayName
        self.addedAt = Date()
        self.task = task
    }

    var url: URL { VaultSettings.url(forRelativePath: relativePath) }
    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }
}
