import Foundation
import SwiftData

/// Named `PraxisTask`, not `Task` — `Task` would shadow `_Concurrency.Task` across the
/// whole module (every `Task { ... }` async call site in Praxis), causing ambiguity errors
/// far from this file.
enum TaskType: String, Codable, CaseIterable {
    case rendu, revisionFond, revisionDS, blocage, anticipation

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
    @Attribute(.unique) var id: String   // vault-relative path, e.g. "01_IMT/2A/INP/Automatique"
    var displayName: String
    var pole: String                     // "INP" | "GEM"
    var year: String                     // "1A" | "2A"

    @Relationship(deleteRule: .cascade, inverse: \PraxisTask.course)
    var tasks: [PraxisTask] = []

    init(id: String, displayName: String, pole: String, year: String) {
        self.id = id
        self.displayName = displayName
        self.pole = pole
        self.year = year
    }
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
    var createdAt: Date
    var updatedAt: Date
    var completedAt: Date?

    // Rendu
    var dueDate: Date?

    // Révision (fond ou DS)
    var estimatedDurationMinutes: Int?
    @Relationship(deleteRule: .cascade, inverse: \RevisionBlock.task)
    var scheduledBlocks: [RevisionBlock] = []

    // Blocage
    var blockedReason: String?
    var waitingOn: String?

    // Anticipation
    var horizonDate: Date?

    @Relationship(deleteRule: .cascade, inverse: \TaskComment.task)
    var comments: [TaskComment] = []

    @Relationship(deleteRule: .cascade, inverse: \Subtask.parentTask)
    var subtasks: [Subtask] = []

    var type: TaskType {
        get { TaskType(rawValue: typeRaw) ?? .anticipation }
        set { typeRaw = newValue.rawValue }
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
/// A dedicated entity rather than a self-referencing `PraxisTask`: none of the type-specific
/// fields (`dueDate`, `blockedReason`, ...) make sense on a subtask, which only ever needs a
/// title, a time estimate, and a done/not-done state.
@Model
final class Subtask {
    @Attribute(.unique) var id: UUID
    var title: String
    var estimatedMinutes: Int
    var isDone: Bool
    var order: Int
    var origin: String
    var parentTask: PraxisTask?

    init(
        title: String,
        estimatedMinutes: Int,
        order: Int,
        origin: String = "manuel",
        parentTask: PraxisTask? = nil
    ) {
        self.id = UUID()
        self.title = title
        self.estimatedMinutes = estimatedMinutes
        self.isDone = false
        self.order = order
        self.origin = origin
        self.parentTask = parentTask
    }
}
